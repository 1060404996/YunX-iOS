//
//  DownloadManager.swift
//  YunX · 下载任务管理（列表 / 状态机 / 断点续传 / 速度统计）
//

import Foundation
import SwiftUI

// MARK: - 模型

enum DownloadState: String, Codable {
    case waiting
    case running
    case paused
    case completed
    case failed

    var label: String {
        switch self {
        case .waiting:   return "等待中"
        case .running:   return "下载中"
        case .paused:    return "已暂停"
        case .completed: return "已完成"
        case .failed:    return "失败"
        }
    }

    var tint: Color {
        switch self {
        case .waiting:   return YXColor.secondaryLabel
        case .running:   return YXColor.brand
        case .paused:    return YXColor.warning
        case .completed: return YXColor.success
        case .failed:    return YXColor.danger
        }
    }

    var symbol: String {
        switch self {
        case .waiting:   return "clock"
        case .running:   return "arrow.down.circle.fill"
        case .paused:    return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        }
    }
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var filename: String
    var platform: SharePlatform
    var url: String
    var headers: [String: String]
    var totalBytes: Int64
    var downloadedBytes: Int64 = 0
    var state: DownloadState = .waiting
    var errorMessage: String?
    var createdAt: Date = Date()
    var localPath: String?
    var cleanupDirFid: String?
    var isGuest: Bool = false
    var avgSpeed: Double = 0

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }
}

// MARK: - 取消标志

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - 路径

enum YXPaths {
    /// 容器目录在签名/entitlement 异常时可能取不到。YXPaths 在 App 启动
    /// （DownloadManager.shared → load()）就会被调用，此处绝不能用 [0] 强取，
    /// 否则会在首屏渲染前 Index out of range，表现就是「装上但点开闪退」。
    private static var fallbackDirectory: URL {
        FileManager.default.temporaryDirectory
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fallbackDirectory
    }

    static var downloads: URL {
        let url = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 分片临时目录（不放进 Documents，避免被 iCloud 备份与用户误删）
    static var parts: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first ?? fallbackDirectory
        let url = base.appendingPathComponent("YunX/parts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        return url
    }

    static var tasksFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first ?? fallbackDirectory
        let dir = base.appendingPathComponent("YunX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    /// 去掉路径穿越与非法字符
    static func safeName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "_")
        name = name.replacingOccurrences(of: "\\", with: "_")
        let illegal = CharacterSet(charactersIn: ":*?\"<>|")
        name = name.components(separatedBy: illegal).joined(separator: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "未命名文件" }
        if name.count > 120 { name = String(name.prefix(120)) }
        return name
    }

    /// 同名冲突：绝不覆盖
    static func uniqueDestination(filename: String) -> URL {
        let dir = downloads
        let safe = safeName(filename)
        let ns = safe as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var candidate = dir.appendingPathComponent(safe)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)_\(index)" : "\(base)_\(index).\(ext)"
            candidate = dir.appendingPathComponent(name)
            index += 1
            if index > 200 { break }
        }
        return candidate
    }
}

// MARK: - 管理器

/// 任务列表对 UI 是 ObservableObject；所有 @Published 变更都经主线程提交，
/// 但不把类型本身标成 @MainActor —— 否则 `DownloadManager.shared` 在 App 属性初始化器里不可达。
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var totalSpeed: Double = 0

    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var flags: [UUID: CancelFlag] = [:]
    private var lastSample: [UUID: (bytes: Int64, at: Date)] = [:]
    private var speedWindow: [UUID: Double] = [:]

    private let engine = DownloadEngine(tuning: .default)

    private init() {
        load()
        markInterruptedAsPaused()
    }

    // MARK: 设置

    private var threads: Int {
        let v = UserDefaults.standard.integer(forKey: "download_threads")
        return v <= 0 ? 16 : v
    }

    private var speedLimit: Int64 {
        // 设置里存的是 KB/s
        let kb = UserDefaults.standard.integer(forKey: "download_speed_limit")
        return kb <= 0 ? 0 : Int64(kb) * 1024
    }

    // MARK: 入队

    @discardableResult
    func enqueue(_ resolved: ResolvedDownload) -> UUID {
        let destination = YXPaths.uniqueDestination(filename: resolved.filename)
        let item = DownloadItem(filename: destination.lastPathComponent,
                                platform: resolved.platform,
                                url: resolved.url,
                                headers: resolved.headers,
                                totalBytes: resolved.size,
                                state: .waiting,
                                localPath: destination.path,
                                cleanupDirFid: resolved.cleanupDirFid,
                                isGuest: resolved.isGuest)
        items.insert(item, at: 0)
        save()
        start(item.id)
        return item.id
    }

    // MARK: 启动

    func start(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[id] == nil else { return }

        let item = items[index]
        items[index].state = .running
        items[index].errorMessage = nil
        save()

        let flag = CancelFlag()
        flags[id] = flag
        lastSample[id] = (item.downloadedBytes, Date())

        guard let destination = item.localPath.map({ URL(fileURLWithPath: $0) }) else {
            fail(id, message: "保存路径无效")
            return
        }
        let manifestURL = YXPaths.parts
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("manifest.json")
        let existing = Self.loadManifest(manifestURL)

        let spec = DownloadSpec(url: item.url,
                                headers: item.headers,
                                filename: item.filename,
                                expectedSize: item.totalBytes)

        jobs[id] = Task { [weak self] in
            guard let self else { return }
            await self.engine.setSpeedLimit(self.speedLimit)
            do {
                let manifest = try await self.engine.download(
                    spec: spec,
                    destination: destination,
                    manifestURL: manifestURL,
                    existingManifest: existing,
                    platform: item.platform,
                    progress: { done, total in
                        Task { @MainActor [weak self] in
                            self?.applyProgress(id: id, done: done, total: total)
                        }
                    },
                    isCancelled: { flag.get() }
                )
                await MainActor.run {
                    self.complete(id, manifest: manifest, flag: flag)
                }
            } catch {
                await MainActor.run {
                    if flag.get() {
                        self.markPaused(id)
                    } else {
                        self.fail(id, message: error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: 控制

    func pause(_ id: UUID) {
        flags[id]?.set()
        jobs[id]?.cancel()
        jobs[id] = nil
        flags[id] = nil
        markPaused(id)
    }

    func resume(_ id: UUID) {
        start(id)
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].downloadedBytes = 0
        items[index].errorMessage = nil
        // 清空分片以便从头再来
        let dir = YXPaths.parts.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        start(id)
    }

    func remove(_ id: UUID, deleteFile: Bool = true) {
        flags[id]?.set()
        jobs[id]?.cancel()
        jobs[id] = nil
        flags[id] = nil
        lastSample[id] = nil
        speedWindow[id] = nil

        if let item = items.first(where: { $0.id == id }), deleteFile {
            if let path = item.localPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            let dir = YXPaths.parts.appendingPathComponent(id.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        }
        items.removeAll { $0.id == id }
        save()
        recomputeSpeed()
    }

    func clearCompleted() {
        for item in items where item.state == .completed {
            remove(item.id, deleteFile: false)
        }
    }

    // MARK: 进度

    private func applyProgress(id: UUID, done: Int64, total: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].downloadedBytes = done
        if total > 0 { items[index].totalBytes = total }

        // 速度：滑动平均
        if let last = lastSample[id] {
            let dt = Date().timeIntervalSince(last.at)
            if dt >= 0.4 {
                let delta = Double(done - last.bytes)
                let instant = max(0, delta / dt)
                let prev = speedWindow[id] ?? instant
                let smoothed = prev * 0.6 + instant * 0.4
                speedWindow[id] = smoothed
                items[index].avgSpeed = smoothed
                lastSample[id] = (done, Date())
                recomputeSpeed()
            }
        } else {
            lastSample[id] = (done, Date())
        }
    }

    private func recomputeSpeed() {
        var sum: Double = 0
        for item in items where item.state == .running {
            sum += speedWindow[item.id] ?? 0
        }
        totalSpeed = sum
    }

    // MARK: 终态

    private func complete(_ id: UUID, manifest: DownloadManifest, flag: CancelFlag) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !flag.get() else { markPaused(id); return }

        items[index].state = .completed
        items[index].downloadedBytes = manifest.totalBytes
        items[index].totalBytes = manifest.totalBytes
        items[index].errorMessage = nil

        let item = items[index]
        jobs[id] = nil
        flags[id] = nil
        speedWindow[id] = 0
        recomputeSpeed()
        save()

        // 清掉分片目录
        let dir = YXPaths.parts.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)

        // 云端临时转存目录清理
        Task {
            await ResolveService.cleanup(platform: item.platform, dirFid: item.cleanupDirFid)
        }
    }

    private func fail(_ id: UUID, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .failed
        items[index].errorMessage = message
        jobs[id] = nil
        flags[id] = nil
        speedWindow[id] = 0
        recomputeSpeed()
        save()
    }

    private func markPaused(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].state != .completed {
            items[index].state = .paused
        }
        speedWindow[id] = 0
        recomputeSpeed()
        save()
    }

    /// 上次进程未跑完的任务统一改「已暂停」
    private func markInterruptedAsPaused() {
        var changed = false
        for index in items.indices where items[index].state == .running || items[index].state == .waiting {
            items[index].state = .paused
            changed = true
        }
        if changed { save() }
    }

    // MARK: 持久化

    private static func loadManifest(_ url: URL) -> DownloadManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DownloadManifest.self, from: data)
    }

    private func load() {
        guard let data = try? Data(contentsOf: YXPaths.tasksFile) else { return }
        if let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: YXPaths.tasksFile, options: .atomic)
    }
}
