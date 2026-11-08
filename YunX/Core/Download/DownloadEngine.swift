//
//  DownloadEngine.swift
//  YunX · Range 分片并发下载引擎
//
//  严格对齐桌面版 ChunkDownloader / HttpRangePolicy 的判定链：
//  · 两段式探测：先 Range: bytes=0-0（必须 206 且 Content-Range 精确为 0-0/total），失败再不带 Range 看 Content-Length；
//  · Content-Type 含 text/html 一律判失败（这是防盗链/过期广告页，写盘就是垃圾数据）；
//  · 分片请求收到 200 → RANGE_IGNORED，绝不为单片下载整文件，整任务回退单流；
//  · 目标文件先 truncate 到总长度，各分片 seek 写入 —— 无合并、不占双份磁盘；
//  · 每个分片已完成字节写入 manifest，重启后按 start+done 续传。
//

import Foundation

// MARK: - 规格

struct DownloadSpec {
    var url: String
    var headers: [String: String]
    var filename: String
    /// 解析阶段已知大小（仅探测失败时兜底；探测值优先）
    var expectedSize: Int64 = 0
}

struct RangeProbe {
    var totalBytes: Int64
    var supportsRange: Bool
    var etag: String?
}

// MARK: - 分片计划

struct ChunkPlan: Codable, Equatable {
    var start: Int64
    var end: Int64        // inclusive
    var done: Int64

    var length: Int64 { end - start + 1 }
    var isFinished: Bool { done >= length }
}

struct DownloadManifest: Codable {
    var version: Int = 2
    var url: String
    var totalBytes: Int64
    var filename: String
    var headers: [String: String]
    var chunks: [ChunkPlan]
    var etag: String?

    var doneBytes: Int64 { chunks.reduce(0) { $0 + min($1.done, $1.length) } }
}

// MARK: - 分片状态箱

/// 各分片并发更新同一份 manifest，用引用类型 + 锁承载，
/// 避免 inout 在 TaskGroup 里跨并发域传递（Swift 不允许）。
final class ManifestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var manifest: DownloadManifest

    init(_ manifest: DownloadManifest) {
        self.manifest = manifest
    }

    func snapshot() -> DownloadManifest {
        lock.lock(); defer { lock.unlock() }
        return manifest
    }

    func chunk(at index: Int) -> ChunkPlan {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < manifest.chunks.count else {
            return ChunkPlan(start: 0, end: -1, done: 0)
        }
        return manifest.chunks[index]
    }

    @discardableResult
    func addDone(index: Int, bytes: Int64) -> DownloadManifest {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < manifest.chunks.count else { return manifest }
        manifest.chunks[index].done += bytes
        return manifest
    }
}

// MARK: - 调优

struct DownloadTuning {
    /// 用户在设置里选的线程数
    var threads: Int = 16
    /// 全局限速（0 = 不限）
    var speedLimit: Int64 = 0
    /// 单片重试次数
    var maxRetries: Int = 3

    static let `default` = DownloadTuning()

    /// 实际 worker 数：迅雷类 CDN 单文件并发 > 8 会被降级成 200 整文件
    func workers(platform: SharePlatform?) -> Int {
        let asked = max(1, min(threads, 64))
        if platform == .xunlei { return min(asked, 8) }
        return min(asked, 32)
    }

    /// 分片数（对齐桌面：按大小分档，再按线程数补盈余）
    static func chunkCount(total: Int64, threads: Int) -> Int {
        guard total > 0 else { return 1 }
        let bySize: Int
        switch total {
        case ..<(5 << 20):      bySize = 1
        case ..<(50 << 20):     bySize = 8
        case ..<(500 << 20):    bySize = 32
        default:                bySize = 64
        }
        let want = max(bySize, threads * 8)
        let bySlot = Int(max(1, total / (256 * 1024)))
        return max(1, min(want, bySlot, 512))
    }

    func plan(totalBytes: Int64) -> [ChunkPlan] {
        guard totalBytes > 0 else { return [] }
        let count = Self.chunkCount(total: totalBytes, threads: threads)
        let chunkSize = (totalBytes + Int64(count) - 1) / Int64(count)
        var chunks: [ChunkPlan] = []
        var start: Int64 = 0
        while start < totalBytes {
            let end = min(start + chunkSize - 1, totalBytes - 1)
            chunks.append(ChunkPlan(start: start, end: end, done: 0))
            start = end + 1
        }
        return chunks
    }
}

// MARK: - 限速（全局令牌桶）

actor SpeedLimiter {
    private var limit: Int64
    private var tokens: Double
    private var lastRefill = Date()

    init(limit: Int64) {
        self.limit = limit
        self.tokens = Double(max(0, limit))
    }

    func update(limit newLimit: Int64) {
        limit = newLimit
        tokens = Double(max(0, newLimit))
        lastRefill = Date()
    }

    func consume(_ bytes: Int64) async {
        guard limit > 0, bytes > 0 else { return }
        while true {
            let now = Date()
            let elapsed = now.timeIntervalSince(lastRefill)
            if elapsed > 0 {
                tokens = min(Double(limit), tokens + elapsed * Double(limit))
                lastRefill = now
            }
            if Double(bytes) <= tokens {
                tokens -= Double(bytes)
                return
            }
            let need = (Double(bytes) - tokens) / Double(limit)
            let ms = UInt64(max(1, min(200, Int(need * 1000))))
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
        }
    }
}

// MARK: - 分片返回状态

enum ChunkOutcome {
    case ok
    case rangeIgnored
}

enum RangePolicyError: LocalizedError {
    case rangeIgnored
    case htmlResponse
    case contentRangeMismatch(String)

    var errorDescription: String? {
        switch self {
        case .rangeIgnored:                 return "服务器忽略了 Range 请求"
        case .htmlResponse:                 return "直链返回了网页（防盗链或已过期）"
        case .contentRangeMismatch(let v):  return "Content-Range 不匹配：\(v)"
        }
    }
}

// MARK: - 写盘串行化

/// FileHandle 的 seek+write 不是线程安全的，所有写盘走这一个串行队列。
final class ChunkWriter {
    private let queue = DispatchQueue(label: "com.yunx.download.write")
    private var handles: [String: FileHandle] = [:]
    private let lock = NSLock()

    func open(_ key: String, at url: URL, size: Int64) throws {
        try queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            let current = (try? handle.seekToEnd()) ?? 0
            if current != UInt64(size) {
                try handle.truncate(atOffset: UInt64(size))
            }
            lock.lock(); handles[key] = handle; lock.unlock()
        }
    }

    func write(_ key: String, offset: Int64, data: Data) throws {
        try queue.sync {
            lock.lock(); let handle = handles[key]; lock.unlock()
            guard let handle else { throw YXError.business("写入句柄已关闭") }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        }
    }

    func close(_ key: String) {
        queue.sync {
            lock.lock(); let handle = handles.removeValue(forKey: key); lock.unlock()
            guard let handle else { return }
            try? handle.synchronize()
            try? handle.close()
        }
    }

    func closeAll() {
        queue.sync {
            lock.lock()
            let all = handles
            handles.removeAll()
            lock.unlock()
            for (_, h) in all {
                try? h.synchronize()
                try? h.close()
            }
        }
    }
}

// MARK: - 流式传输协调器

final class StreamTransfer: NSObject, URLSessionDataDelegate {
    struct Job {
        let url: URLRequest
        let sink: (Data) -> Void
        var onProgress: (Int64) -> Void
        var received: Int64 = 0
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var continuations: [Int: CheckedContinuation<Int64, Error>] = [:]
    private var failure: [Int: Error] = [:]
    /// 必须先 super.init() 才能把 self 作为 delegate 传进去，所以这里用隐式解包
    private var session: URLSession!

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 7200
        // 默认 6 会把手里的并发全压死
        cfg.httpMaximumConnectionsPerHost = 64
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 8
        queue.qualityOfService = .userInitiated
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
    }

    /// 发起一次传输，返回写入的字节数
    func transfer(_ request: URLRequest,
                  sink: @escaping (Data) -> Void,
                  onProgress: @escaping (Int64) -> Void) async throws -> Int64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, Error>) in
            let task = session.dataTask(with: request)
            let job = Job(url: request, sink: sink, onProgress: onProgress)
            lock.lock()
            jobs[task.taskIdentifier] = job
            continuations[task.taskIdentifier] = cont
            lock.unlock()
            task.resume()
        }
    }

    func cancelAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }

        lock.lock()
        let job = jobs[dataTask.taskIdentifier]
        lock.unlock()
        guard job != nil else {
            completionHandler(.cancel)
            return
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/html") {
            fail(taskId: dataTask.taskIdentifier, error: RangePolicyError.htmlResponse)
            completionHandler(.cancel)
            return
        }

        if let range = job?.url.value(forHTTPHeaderField: "Range") {
            // 期望分片
            if http.statusCode == 200 {
                fail(taskId: dataTask.taskIdentifier, error: RangePolicyError.rangeIgnored)
                completionHandler(.cancel)
                return
            }
            guard http.statusCode == 206 else {
                fail(taskId: dataTask.taskIdentifier,
                     error: YXError.badStatus(http.statusCode, "分片请求失败（HTTP \(http.statusCode)）"))
                completionHandler(.cancel)
                return
            }
            guard Self.contentRangeMatches(http.value(forHTTPHeaderField: "Content-Range"), requested: range) else {
                fail(taskId: dataTask.taskIdentifier,
                     error: RangePolicyError.contentRangeMismatch(http.value(forHTTPHeaderField: "Content-Range") ?? "nil"))
                completionHandler(.cancel)
                return
            }
        } else {
            guard http.statusCode == 200 || http.statusCode == 206 else {
                fail(taskId: dataTask.taskIdentifier,
                     error: YXError.badStatus(http.statusCode, "下载失败（HTTP \(http.statusCode)）"))
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var job = jobs[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        lock.unlock()

        job.received += Int64(data.count)
        job.sink(data)
        job.onProgress(job.received)

        lock.lock()
        jobs[dataTask.taskIdentifier] = job
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        // didReceive response 里的策略性失败（Range 被忽略 / 防盗链 HTML /
        // 状态码异常 / Content-Range 不匹配）都以 completionHandler(.cancel) 收尾，
        // URLSession 此时只会回调 URLError.cancelled。必须先把真实错误取出来，
        // 否则一切失败都会伪装成「用户取消」，200 回退与重试策略全部失效。
        if let stored = takeFailure(taskId: taskId) {
            finish(taskId: taskId, result: .failure(stored))
            return
        }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(taskId: taskId, result: .failure(YXError.cancelled))
            } else {
                finish(taskId: taskId, result: .failure(YXError.network(error.localizedDescription)))
            }
            return
        }
        lock.lock()
        let received = jobs[taskId]?.received ?? 0
        lock.unlock()
        finish(taskId: taskId, result: .success(received))
    }

    // MARK: 内部

    private func fail(taskId: Int, error: Error) {
        lock.lock()
        failure[taskId] = error
        lock.unlock()
    }

    private func takeFailure(taskId: Int) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure.removeValue(forKey: taskId)
    }

    private func finish(taskId: Int, result: Result<Int64, Error>) {
        lock.lock()
        let cont = continuations.removeValue(forKey: taskId)
        jobs.removeValue(forKey: taskId)
        failure.removeValue(forKey: taskId)
        lock.unlock()
        guard let cont else { return }
        switch result {
        case .success(let n): cont.resume(returning: n)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    /// Content-Range: bytes 0-1048575/12345678，要求 start/end 与请求精确一致
    static func contentRangeMatches(_ value: String?, requested: String) -> Bool {
        guard let value else { return false }
        guard let range = parseContentRange(value) else { return false }
        // requested: bytes=<from>-<to>
        let parts = requested.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
        guard parts.count == 2,
              let from = Int64(parts[0]),
              let to = Int64(parts[1]) else { return false }
        return range.start == from && range.end == to
    }

    static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64?)? {
        // bytes 0-1048575/12345678
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let spaceIdx = trimmed.firstIndex(of: " ") else { return nil }
        let unit = trimmed[trimmed.startIndex..<spaceIdx].lowercased()
        guard unit == "bytes" else { return nil }
        let rest = trimmed[trimmed.index(after: spaceIdx)...]
        let segs = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rangePart = segs.first else { return nil }
        let bounds = rangePart.split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]) else { return nil }
        var total: Int64? = nil
        if segs.count == 2 {
            let t = segs[1].trimmingCharacters(in: .whitespaces)
            if t != "*" { total = Int64(t) }
        }
        return (start, end, total)
    }
}

// MARK: - 引擎

final class DownloadEngine {

    private let tuning: DownloadTuning
    private let limiter: SpeedLimiter
    private let writer = ChunkWriter()
    private let probeSession: URLSession

    init(tuning: DownloadTuning = .default) {
        self.tuning = tuning
        self.limiter = SpeedLimiter(limit: tuning.speedLimit)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        probeSession = URLSession(configuration: cfg)
    }

    func setSpeedLimit(_ bytesPerSecond: Int64) async {
        await limiter.update(limit: bytesPerSecond)
    }

    // MARK: 两段式探测

    func probe(_ spec: DownloadSpec) async throws -> RangeProbe {
        guard let url = URL(string: spec.url) else { throw YXError.invalidURL(spec.url) }

        // 第 1 段：Range: bytes=0-0
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 25
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (k, v) in spec.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let raw = try? await probeSession.data(for: req),
           let http = raw.1 as? HTTPURLResponse {
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if !ct.contains("text/html"),
               http.statusCode == 206,
               let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let parsed = StreamTransfer.parseContentRange(cr),
               parsed.start == 0, parsed.end == 0,
               let total = parsed.total, total > 0 {
                return RangeProbe(totalBytes: total, supportsRange: true,
                                  etag: http.value(forHTTPHeaderField: "ETag"))
            }
            if http.statusCode == 403 || http.statusCode == 412 || http.statusCode == 401 {
                throw YXError.business("直链已过期或无权访问（HTTP \(http.statusCode)），请重新解析")
            }
        }

        // 第 2 段：不带 Range
        var plain = URLRequest(url: url)
        plain.httpMethod = "GET"
        plain.timeoutInterval = 25
        for (k, v) in spec.headers {
            plain.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await probeSession.data(for: plain)
        guard let http = resp as? HTTPURLResponse else {
            throw YXError.network("无 HTTP 响应")
        }
        let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if ct.contains("text/html") {
            throw RangePolicyError.htmlResponse
        }
        if http.statusCode == 403 || http.statusCode == 412 || http.statusCode == 401 {
            throw YXError.business("直链已过期或无权访问（HTTP \(http.statusCode)），请重新解析")
        }
        guard (200...299).contains(http.statusCode) else {
            throw YXError.badStatus(http.statusCode, "探测失败（HTTP \(http.statusCode)）")
        }
        let len = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) } ?? Int64(data.count)
        let total = spec.expectedSize > 0 ? spec.expectedSize : len
        return RangeProbe(totalBytes: total, supportsRange: false,
                          etag: http.value(forHTTPHeaderField: "ETag"))
    }

    // MARK: 主流程

    func download(spec: DownloadSpec,
                  destination: URL,
                  manifestURL: URL,
                  existingManifest: DownloadManifest?,
                  platform: SharePlatform? = nil,
                  progress: @escaping @Sendable (Int64, Int64) -> Void,
                  isCancelled: @escaping @Sendable () -> Bool) async throws -> DownloadManifest {

        let probe = try await self.probe(spec)

        // 不支持 Range → 单流
        guard probe.supportsRange, probe.totalBytes > 0 else {
            return try await singleStream(spec: spec,
                                          destination: destination,
                                          manifestURL: manifestURL,
                                          total: probe.totalBytes,
                                          progress: progress,
                                          isCancelled: isCancelled)
        }

        var manifest: DownloadManifest
        if let old = existingManifest,
           old.totalBytes == probe.totalBytes,
           !old.chunks.isEmpty,
           old.filename == spec.filename {
            manifest = old
            manifest.url = spec.url
            manifest.headers = spec.headers
        } else {
            manifest = DownloadManifest(url: spec.url,
                                        totalBytes: probe.totalBytes,
                                        filename: spec.filename,
                                        headers: spec.headers,
                                        chunks: tuning.plan(totalBytes: probe.totalBytes),
                                        etag: probe.etag)
        }

        let total = manifest.totalBytes
        let writerKey = destination.path
        try writer.open(writerKey, at: destination, size: total)
        try persist(manifest, to: manifestURL)

        let box = ManifestBox(manifest)
        let workers = tuning.workers(platform: platform)
        let reporter = ProgressReporter(initial: manifest.doneBytes, total: total, onUpdate: progress)
        progress(manifest.doneBytes, total)

        // 分片索引队列（按字节顺序发，物理相邻利于连接复用）
        var pending = manifest.chunks.indices.filter { !manifest.chunks[$0].isFinished }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var running = 0
                var launchIndex = 0

                func launch(_ index: Int) {
                    let staggerSeed = launchIndex
                    group.addTask { [self] in
                        // 错峰建连，避免 TCP/TLS 突发
                        let stagger = UInt64(min(staggerSeed, 8)) * 25_000_000
                        if stagger > 0 { try? await Task.sleep(nanoseconds: stagger) }
                        try await runChunk(index: index,
                                           spec: spec,
                                           box: box,
                                           manifestURL: manifestURL,
                                           writerKey: writerKey,
                                           reporter: reporter,
                                           isCancelled: isCancelled)
                    }
                }

                while running < min(workers, max(1, pending.count)), !pending.isEmpty {
                    let next = pending.removeFirst()
                    launch(next)
                    launchIndex += 1
                    running += 1
                }

                while try await group.next() != nil {
                    running -= 1
                    if !pending.isEmpty {
                        let next = pending.removeFirst()
                        launch(next)
                        launchIndex += 1
                        running += 1
                    }
                }
            }
        } catch let policy as RangePolicyError {
            writer.close(writerKey)
            if case .rangeIgnored = policy {
                // 服务器忽略 Range：分片结果全部作废，整任务回退单流。
                // 文件末尾的注释写了这条规则，但此前 runChunk 只是把错误
                // 一路 rethrow，任务直接失败，从未真正回退。
                // TaskGroup 抛错离开作用域时会等待所有子任务结束，
                // 因此此刻不会再有分片并发写盘。
                try? FileManager.default.removeItem(at: manifestURL)
                return try await singleStream(spec: spec,
                                              destination: destination,
                                              manifestURL: manifestURL,
                                              total: probe.totalBytes,
                                              progress: progress,
                                              isCancelled: isCancelled)
            }
            try? persist(box.snapshot(), to: manifestURL)
            throw policy
        } catch {
            writer.close(writerKey)
            try? persist(box.snapshot(), to: manifestURL)
            throw error
        }

        writer.close(writerKey)
        let finalManifest = box.snapshot()
        try persist(finalManifest, to: manifestURL)
        progress(total, total)
        return finalManifest
    }

    // MARK: 单片

    private func runChunk(index: Int,
                          spec: DownloadSpec,
                          box: ManifestBox,
                          manifestURL: URL,
                          writerKey: String,
                          reporter: ProgressReporter,
                          isCancelled: @escaping @Sendable () -> Bool) async throws {
        var attempt = 0
        while true {
            if isCancelled() { throw YXError.cancelled }
            let plan = box.chunk(at: index)
            if plan.isFinished { return }

            let from = plan.start + plan.done
            let to = plan.end
            if from > to { return }

            do {
                guard let url = URL(string: spec.url) else { throw YXError.invalidURL(spec.url) }
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.timeoutInterval = 60
                req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
                for (k, v) in spec.headers {
                    req.setValue(v, forHTTPHeaderField: k)
                }

                var offset = from
                let transfer = StreamTransfer()
                let writeError = WriteErrorBox()
                let received = try await transfer.transfer(req) { data in
                    if writeError.take() == nil {
                        do {
                            try self.writer.write(writerKey, offset: offset, data: data)
                        } catch {
                            writeError.record(error)
                        }
                    }
                    offset += Int64(data.count)
                } onProgress: { _ in }
                // 写盘失败（磁盘满 / 句柄已关闭 / seek 失败）绝不能算成功分片，
                // 否则会产出「进度 100%」的空洞文件。
                if let error = writeError.take() { throw error }

                await limiter.consume(received)

                let snapshot = box.addDone(index: index, bytes: received)
                reporter.bump(received)
                try? persist(snapshot, to: manifestURL)

                if box.chunk(at: index).isFinished { return }
                // 未满则继续拉剩余部分
                attempt = 0
                if received == 0 { throw YXError.network("分片返回 0 字节") }
            } catch let e as RangePolicyError {
                if case .rangeIgnored = e {
                    // 不在片内退避：立即交给上层回退单流
                    throw e
                }
                attempt += 1
                if attempt > tuning.maxRetries { throw e }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
            } catch is CancellationError {
                throw YXError.cancelled
            } catch {
                attempt += 1
                if attempt > tuning.maxRetries { throw error }
                let backoff = UInt64(min(500 * attempt, 3000)) * 1_000_000
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
    }

    // MARK: 单流

    private func singleStream(spec: DownloadSpec,
                              destination: URL,
                              manifestURL: URL,
                              total: Int64,
                              progress: @escaping @Sendable (Int64, Int64) -> Void,
                              isCancelled: @escaping @Sendable () -> Bool) async throws -> DownloadManifest {
        guard let url = URL(string: spec.url) else { throw YXError.invalidURL(spec.url) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 60
        for (k, v) in spec.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let reporter = ProgressReporter(initial: 0, total: total, onUpdate: progress)
        var offset: Int64 = 0
        let writerKey = destination.path
        try writer.open(writerKey, at: destination, size: 0)
        let transfer = StreamTransfer()

        let writeError = WriteErrorBox()
        let written = try await transfer.transfer(req) { data in
            if writeError.take() == nil {
                do {
                    try self.writer.write(writerKey, offset: offset, data: data)
                } catch {
                    writeError.record(error)
                }
            }
            offset += Int64(data.count)
            reporter.bump(Int64(data.count))
        } onProgress: { _ in }
        if let error = writeError.take() {
            writer.close(writerKey)
            throw error
        }

        writer.close(writerKey)
        _ = await limiter.consume(written)
        _ = isCancelled

        let manifest = DownloadManifest(url: spec.url,
                                        totalBytes: written,
                                        filename: spec.filename,
                                        headers: spec.headers,
                                        chunks: [ChunkPlan(start: 0, end: max(0, written - 1), done: written)],
                                        etag: nil)
        try persist(manifest, to: manifestURL)
        progress(written, written)
        return manifest
    }

    // MARK: 工具

    private func persist(_ manifest: DownloadManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// delegate 的 sink 闭包不能 throw，写盘失败先记在这里，
/// transfer 结束后由调用方统一抛出，避免「写失败但仍标记分片完成」。
private final class WriteErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?

    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if value == nil { value = error }
    }

    func take() -> Error? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - 进度节流

final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var downloaded: Int64
    private let total: Int64
    private var lastEmit = Date.distantPast
    private let onUpdate: @Sendable (Int64, Int64) -> Void

    init(initial: Int64, total: Int64, onUpdate: @escaping @Sendable (Int64, Int64) -> Void) {
        self.downloaded = initial
        self.total = total
        self.onUpdate = onUpdate
    }

    func bump(_ bytes: Int64) {
        lock.lock()
        if bytes > 0 { downloaded += bytes }
        let now = Date()
        let shouldEmit = now.timeIntervalSince(lastEmit) > 0.2
        if shouldEmit { lastEmit = now }
        let snapshot = downloaded
        lock.unlock()
        if shouldEmit { onUpdate(snapshot, total) }
    }
}
