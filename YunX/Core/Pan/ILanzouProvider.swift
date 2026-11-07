//
//  ILanzouProvider.swift
//  YunX · 蓝奏云优享版（分享解析；匿名可用）
//
//  协议唯一真源：desktop 端 Kotlin
//    data/network/ILanzouApi.kt、data/network/ILanzouConstants.kt、
//    data/repository/ILanzouResolveRepository.kt
//
//  分享链路：
//    1) GET  apix.ilanzou.com/unproved/share/list   → 目录（根目录不传 folderId；offset 是页码，limit 固定 60）
//    2) GET  apix.ilanzou.com/unproved/file/redirect → 302 Location（禁止自动跟随才能读到 Location）
//
//  关键约束：
//   - 全部参数走 URL query，顺序固定；标准 query 编码后把 %3A 还原成字面冒号；
//   - timestamp / downloadId / auth 都是 AES-ECB-PKCS5(hex) 小写十六进制；
//   - 必须补全套 sec-ch-ua / sec-fetch-* 头，否则站点 WAF 直接返回空 list（风控，不是协议错误）；
//   - 文件大小单位是 KiB，×1024 才是字节。
//

import Foundation

final class ILanzouProvider: PanProvider {

    let platform: SharePlatform = .ilanzou

    // MARK: - 常量（对齐 ILanzouConstants）

    private static let apiBase = "https://apis.ilanzou.com"
    private static let shareBase = "https://apix.ilanzou.com"
    private static let webSite = "https://www.ilanzou.com"
    private static let devType = "6"
    private static let devVersion = "125"
    private static let webDevModel = "chrome"
    private static let shareDevModel = "Chrome"
    private static let pageSize = 60
    private static let aesKey = "lanZouY-disk-app"
    private static let uuidKey = "yunx.ilanzou.uuid"

    /// 访问验证（409 + text/html）标记：捕获后重试一次
    private struct AccessChallenge: Error {}

    // MARK: - 会话

    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        let id = shareId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw YXError.business("蓝奏优享分享 id 为空") }

        // 该平台没有「分享兑换 token」这一步，stoken 直接复用 shareId；
        // 这里真打一次根目录列表做校验（分享失效 / 风控拦截会立刻暴露）。
        let device = try await deviceUuid()
        _ = try await shareListPage(shareId: id, folderId: nil, page: 1, uuid: device)

        var extra: [String: String] = [:]
        if let pwd, !pwd.trimmingCharacters(in: .whitespaces).isEmpty { extra["pwd"] = pwd }
        return ShareSession(platform: .ilanzou,
                            shareId: id,
                            stoken: id,
                            title: "蓝奏云优享版分享",
                            extra: extra)
    }

    // MARK: - 列表

    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem] {
        let device = try await deviceUuid()
        let folderId = ILanzouProvider.folderId(dirFid)
        let parentFid = folderId ?? "0"

        var all: [ShareFileItem] = []
        var seen = Set<String>()
        var page = 1

        while page <= 1000 {
            let json = try await shareListPage(shareId: session.shareId,
                                              folderId: folderId,
                                              page: page,
                                              uuid: device)
            let rows = (json["list"] as? [[String: Any]]) ?? []
            if rows.isEmpty { break }

            var added = 0
            for row in rows {
                guard let item = ILanzouProvider.parseItem(row, parentFid: parentFid) else { continue }
                if seen.insert(item.fid).inserted {
                    all.append(item)
                    added += 1
                }
            }
            if added == 0 { break }

            let totalPage = json.yxInt("totalPage") ?? 0
            if totalPage > 0 && page >= totalPage { break }
            if totalPage <= 0 && rows.count < ILanzouProvider.pageSize { break }
            page += 1
        }
        return all
    }

    private func shareListPage(shareId: String,
                               folderId: String?,
                               page: Int,
                               uuid: String) async throws -> [String: Any] {
        let timestamp = try aesHex(String(ILanzouProvider.nowMillis()))
        var parts: [(String, String)] = []
        parts.append(("uuid", uuid))
        parts.append(("devType", ILanzouProvider.devType))
        parts.append(("devCode", uuid))
        parts.append(("devModel", ILanzouProvider.shareDevModel))
        parts.append(("devVersion", ILanzouProvider.devVersion))
        parts.append(("appVersion", ""))
        parts.append(("timestamp", timestamp))
        parts.append(("extra", "2"))
        parts.append(("shareId", shareId))
        if let folderId, !folderId.isEmpty { parts.append(("folderId", folderId)) }
        parts.append(("offset", String(page)))
        parts.append(("limit", String(ILanzouProvider.pageSize)))

        let url = ILanzouProvider.shareBase + "/unproved/share/list?" + encodeQuery(parts)
        return try await executeShare(url)
    }

    // MARK: - 取链

    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        guard !file.isDir else { throw YXError.business("文件夹无法直接下载") }

        let fileId = ILanzouProvider.rawFileId(file.fid)
        guard !fileId.isEmpty else { throw YXError.business("蓝奏优享文件 id 无效") }

        let device = try await deviceUuid()
        // downloadId = AES('<fileId>|<userId>')：未登录 / 拿不到账号时 userId 传空串
        let userId = await accountUserId()
        let ts = ILanzouProvider.nowMillis()
        let downloadId = try aesHex(fileId + "|" + userId)
        let auth = try aesHex(fileId + "|" + String(ts))
        let timestamp = try aesHex(String(ts))

        var parts: [(String, String)] = []
        parts.append(("downloadId", downloadId))
        parts.append(("enable", "1"))
        parts.append(("devType", ILanzouProvider.devType))
        parts.append(("uuid", device))
        parts.append(("timestamp", timestamp))
        parts.append(("auth", auth))
        parts.append(("shareId", session.shareId))

        let url = ILanzouProvider.shareBase + "/unproved/file/redirect?" + encodeQuery(parts)
        let probe = try await redirectProbe(url)

        let finalURL: String
        if (300...399).contains(probe.status), let location = probe.location, !location.isEmpty {
            finalURL = ILanzouProvider.absolute(location, base: ILanzouProvider.shareBase)
        } else {
            guard let json = probe.json else {
                throw YXError.business("蓝奏优享未返回下载地址")
            }
            let link = ILanzouProvider.firstNonBlank(json.yxString("url") ?? "",
                                                     json.yxString("data.url") ?? "")
            guard !link.isEmpty else {
                throw YXError.business(ILanzouProvider.firstNonBlank(json.yxString("msg") ?? "",
                                                                    "蓝奏优享未返回下载地址，请检查文件权限"))
            }
            finalURL = link
        }

        return ResolvedDownload(
            url: finalURL,
            filename: file.name,
            size: file.size,
            headers: [
                "User-Agent": YXUA.chromeDesktop,
                "Referer": ILanzouProvider.webSite + "/",
                "Origin": ILanzouProvider.webSite,
                "Accept": "*/*",
                "Accept-Encoding": "identity"
            ],
            platform: .ilanzou,
            isGuest: userId.isEmpty
        )
    }

    // MARK: - 账号态

    func quota() async -> (used: Int64, total: Int64)? {
        let token = ILanzouProvider.appToken(from: PanTool.cookie(.ilanzou))
        guard !token.isEmpty else { return nil }
        guard let map = await accountMap(appToken: token) else { return nil }

        // 服务端单位是 KiB
        let used = (map.yxInt64("usedSize") ?? 0) * 1024
        let totalKiB = (map.yxInt64("totalSize") ?? 0)
            + (map.yxInt64("vipSize") ?? 0)
            + (map.yxInt64("rewardSize") ?? 0)
        let total = totalKiB * 1024
        guard total > 0 else { return nil }
        return (used: used, total: total)
    }

    func nickname(cookie: String) async -> String? {
        let token = ILanzouProvider.appToken(from: cookie)
        guard !token.isEmpty else { return nil }
        guard let map = await accountMap(appToken: token) else { return nil }

        var userId = (map.yxString("userId") ?? "").trimmingCharacters(in: .whitespaces)
        if userId.isEmpty {
            let numeric = map.yxInt("userId") ?? 0
            userId = numeric != 0 ? String(numeric) : ""
        }
        guard !userId.isEmpty else { return nil }

        return ILanzouProvider.firstNonBlank(map.yxString("nickName") ?? "",
                                             map.yxString("nickname") ?? "",
                                             map.yxString("account") ?? "",
                                             "蓝奏优享用户")
    }

    /// 账号信息：/proved/user/account/map（需要 appToken + uuid）
    private func accountMap(appToken: String) async -> [String: Any]? {
        guard let device = try? await deviceUuid() else { return nil }
        guard let url = try? buildUrl(path: ILanzouProvider.apiBase + "/proved/user/account/map",
                                     uuid: device,
                                     appToken: appToken,
                                     extra: true,
                                     params: []) else { return nil }
        guard let json = try? await execute(url) else { return nil }
        return json["map"] as? [String: Any]
    }

    /// 已登录时取 userId（downloadId 需要），拿不到就回退空串按游客处理
    private func accountUserId() async -> String {
        let token = ILanzouProvider.appToken(from: PanTool.cookie(.ilanzou))
        guard !token.isEmpty else { return "" }
        guard let map = await accountMap(appToken: token) else { return "" }
        let raw = (map.yxString("userId") ?? "").trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty { return raw }
        let numeric = map.yxInt("userId") ?? 0
        return numeric != 0 ? String(numeric) : ""
    }

    // MARK: - 设备标识

    /// 文档 §2.1：uuid 匿名解析也要用，取到后缓存（下次启动直接复用）
    private func deviceUuid() async throws -> String {
        let defaults = UserDefaults.standard
        if let cached = defaults.string(forKey: ILanzouProvider.uuidKey),
           ILanzouProvider.isValidUuid(cached) {
            return cached
        }
        let url = try buildUrl(path: ILanzouProvider.apiBase + "/unproved/getUuid",
                              uuid: "",
                              appToken: nil,
                              extra: true,
                              params: [])
        let json = try await execute(url)
        let value = (json.yxString("uuid") ?? "").trimmingCharacters(in: .whitespaces)
        guard ILanzouProvider.isValidUuid(value) else {
            throw YXError.business("蓝奏优享未返回有效设备标识")
        }
        defaults.set(value, forKey: ILanzouProvider.uuidKey)
        return value
    }

    // MARK: - URL 组装

    /// 个人盘 URL：公共头参数 + 业务参数（可按需带 appToken / extra=2）
    private func buildUrl(path: String,
                          uuid: String,
                          appToken: String?,
                          extra: Bool,
                          params: [(String, String)]) throws -> String {
        var parts: [(String, String)] = []
        parts.append(("uuid", uuid))
        parts.append(("devType", ILanzouProvider.devType))
        parts.append(("devCode", uuid))
        parts.append(("devModel", ILanzouProvider.webDevModel))
        parts.append(("devVersion", ILanzouProvider.devVersion))
        parts.append(("appVersion", ""))
        parts.append(("timestamp", try aesHex(String(ILanzouProvider.nowMillis()))))
        if let appToken, !appToken.isEmpty { parts.append(("appToken", appToken)) }
        if extra { parts.append(("extra", "2")) }
        parts.append(contentsOf: params)
        return path + "?" + encodeQuery(parts)
    }

    private func encodeQuery(_ parts: [(String, String)]) -> String {
        parts.map { "\($0.0)=\(encodeToken($0.1))" }.joined(separator: "&")
    }

    /// 标准 query 编码后把 %3A 还原成字面冒号（appToken 等参数要求）
    private func encodeToken(_ value: String) -> String {
        YXURLUtil.encode(value).replacingOccurrences(of: "%3A", with: ":")
    }

    /// AES/ECB/PKCS5 → 小写 hex（timestamp / downloadId / auth）
    private func aesHex(_ plain: String) throws -> String {
        let key = Data(ILanzouProvider.aesKey.utf8)
        guard let encrypted = YXCrypto.aesECB(key: key, data: Data(plain.utf8), encrypt: true),
              !encrypted.isEmpty else {
            throw YXError.business("蓝奏优享签名参数计算失败")
        }
        return YXCrypto.hex(encrypted)
    }

    // MARK: - 请求

    /// 公共头：缺了 sec-ch-ua / sec-fetch-* 会被站点风控拦成空列表
    private var commonHeaders: [String: String] {
        [
            "User-Agent": YXUA.chromeDesktop,
            "Origin": ILanzouProvider.webSite,
            "Referer": ILanzouProvider.webSite + "/",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "sec-ch-ua": "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"",
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": "\"Windows\"",
            "sec-fetch-dest": "empty",
            "sec-fetch-mode": "cors",
            "sec-fetch-site": "same-site"
        ]
    }

    private struct Response {
        var status: Int
        var contentType: String
        var json: [String: Any]?
        var text: String
    }

    private func send(_ url: String) async throws -> Response {
        var req = HTTPRequest(url: url)
        req.headers = commonHeaders
        req.injectCookies = false
        let res = try await HTTPClient.shared.send(req)
        let contentType = (res.response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let json = (try? JSONSerialization.jsonObject(with: res.data)) as? [String: Any]
        return Response(status: res.status, contentType: contentType, json: json, text: res.text)
    }

    /// 执行并校验业务码；409 + text/html 访问验证自动重试一次
    private func execute(_ url: String) async throws -> [String: Any] {
        do {
            return try await executeOnce(url)
        } catch is AccessChallenge {
            do {
                return try await executeOnce(url)
            } catch is AccessChallenge {
                throw YXError.business("蓝奏优享的访问验证未通过，请稍后重试")
            }
        }
    }

    private func executeOnce(_ url: String) async throws -> [String: Any] {
        let res = try await send(url)
        if res.status == 401 || res.status == 403 {
            throw YXError.business("蓝奏优享登录已过期，请重新登录")
        }
        if res.status == 409 && res.contentType.contains("text/html") {
            throw AccessChallenge()
        }
        guard (200...299).contains(res.status) else {
            throw YXError.business("蓝奏优享请求失败（\(res.status)），请检查登录信息或稍后重试")
        }
        guard let json = res.json else {
            if res.contentType.contains("text/html") { throw AccessChallenge() }
            throw YXError.business("蓝奏优享请求失败（\(res.status)），请检查登录信息或稍后重试")
        }
        let code = json.yxInt("code") ?? -1
        guard code == 200 else {
            if code == -1 || code == -2 {
                throw YXError.business("蓝奏优享登录已过期，请重新登录")
            }
            let msg = (json.yxString("msg") ?? "").trimmingCharacters(in: .whitespaces)
            throw YXError.business(msg.isEmpty ? "蓝奏优享请求失败（\(code)），请检查登录信息或稍后重试" : msg)
        }
        return json
    }

    /// 分享接口：失败不当作登录失效，直接用服务端 msg
    private func executeShare(_ url: String) async throws -> [String: Any] {
        do {
            return try await shareOnce(url)
        } catch is AccessChallenge {
            do {
                return try await shareOnce(url)
            } catch is AccessChallenge {
                throw YXError.business("蓝奏优享的访问验证未通过，请稍后重试")
            }
        }
    }

    private func shareOnce(_ url: String) async throws -> [String: Any] {
        let res = try await send(url)
        if res.status == 409 && res.contentType.contains("text/html") {
            throw AccessChallenge()
        }
        guard let json = res.json else {
            throw YXError.business("蓝奏优享分享请求失败（\(res.status)）")
        }
        let code = json.yxInt("code") ?? -1
        guard code == 200 else {
            let msg = (json.yxString("msg") ?? "").trimmingCharacters(in: .whitespaces)
            throw YXError.business(msg.isEmpty ? "蓝奏优享分享请求失败（\(code)）" : msg)
        }
        return json
    }

    // MARK: - 302 探测（禁止自动跟随，才能读到 Location）

    private struct ProbeResult {
        var status: Int
        var location: String?
        var json: [String: Any]?
    }

    /// 取链接口是 302 跳真实文件地址：自动跟随后会把整个文件体拉进内存，
    /// 所以这里用一个只用于探测的一次性 URLSession，在 willPerformHTTPRedirection 里回 nil 拦下跳转。
    private func redirectProbe(_ url: String) async throws -> ProbeResult {
        guard let target = URL(string: url) else { throw YXError.invalidURL(url) }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        for (key, value) in commonHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let probe = NoRedirectSession()
        let (data, response) = try await probe.send(request)

        guard let http = response as? HTTPURLResponse else {
            throw YXError.network("非 HTTP 响应")
        }
        let location = probe.redirectLocation ?? http.value(forHTTPHeaderField: "Location")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ProbeResult(status: http.statusCode, location: location, json: json)
    }

    private final class NoRedirectSession: NSObject, URLSessionTaskDelegate {
        private let lock = NSLock()
        private var capturedLocation: String?

        private lazy var transport: URLSession = {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: config, delegate: self, delegateQueue: nil)
        }()

        var redirectLocation: String? {
            lock.lock()
            defer { lock.unlock() }
            return capturedLocation
        }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            defer { transport.finishTasksAndInvalidate() }
            do {
                return try await transport.data(for: request)
            } catch let error as YXError {
                throw error
            } catch {
                throw YXError.network(error.localizedDescription)
            }
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            lock.lock()
            if capturedLocation == nil {
                capturedLocation = response.value(forHTTPHeaderField: "Location") ?? request.url?.absoluteString
            }
            lock.unlock()
            completionHandler(nil)
        }
    }

    // MARK: - 行解析

    private static func parseItem(_ row: [String: Any], parentFid: String) -> ShareFileItem? {
        let fileType = row.yxInt("fileType") ?? 0
        let time = firstNonBlank(row.yxString("updTime") ?? "", row.yxString("addTime") ?? "")

        if fileType == 2 {
            let folderId = firstNonBlank(row.yxString("folderId") ?? "",
                                         String(row.yxInt("folderId") ?? 0))
            if folderId.isEmpty || folderId == "0" { return nil }
            return ShareFileItem(fid: "d:" + folderId,
                                 name: firstNonBlank(row.yxString("folderName") ?? "", "文件夹"),
                                 size: 0,
                                 isDir: true,
                                 parentFid: parentFid,
                                 fidToken: "",
                                 modifyTime: time)
        }

        let fileId = firstNonBlank(row.yxString("fileId") ?? "",
                                   String(row.yxInt("fileId") ?? 0))
        if fileId.isEmpty || fileId == "0" { return nil }
        // 文件大小单位是 KiB
        let sizeKiB = row.yxInt64("fileSize") ?? 0
        return ShareFileItem(fid: "f:" + fileId,
                             name: firstNonBlank(row.yxString("fileName") ?? "", "未命名文件"),
                             size: sizeKiB * 1024,
                             isDir: false,
                             parentFid: parentFid,
                             fidToken: "",
                             modifyTime: time)
    }

    // MARK: - 工具

    private static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// 目录 id 归一化：空 / "0" / "d:" 前缀 → 分享接口需要的数字 id（根目录返回 nil）
    private static func folderId(_ dirFid: String) -> String? {
        let raw = dirFid.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == "0" { return nil }
        if raw.hasPrefix("d:") {
            let stripped = String(raw.dropFirst(2))
            return stripped.isEmpty ? nil : stripped
        }
        return raw
    }

    /// 文件 id：剥掉 "f:" 前缀
    private static func rawFileId(_ fid: String) -> String {
        let raw = fid.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.hasPrefix("f:") ? String(raw.dropFirst(2)) : raw
    }

    private static func isValidUuid(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil
    }

    private static func isValidToken(_ value: String) -> Bool {
        guard value.count >= 16 else { return false }
        return value.range(of: "^[A-Za-z0-9._~+/=:!%&?\\-]+$", options: .regularExpression) != nil
    }

    /// Cookie 串 → appToken。
    /// iOS 侧登录态是「整串 Cookie（k=v; k=v）」或手动粘贴的 appToken，两种形态都要认。
    private static func appToken(from cookie: String) -> String {
        let raw = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        if !raw.contains("=") {
            let value = raw.lowercased().hasPrefix("bearer ") ? String(raw.dropFirst(7)) : raw
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return isValidToken(trimmed) ? trimmed : ""
        }

        var best = ""
        for part in raw.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = pair[pair.startIndex..<eq].lowercased()
            var value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("bearer ") { value = String(value.dropFirst(7)) }
            guard isValidToken(value) else { continue }
            if key.contains("token") && !key.contains("refresh") && value.count > best.count {
                best = value
            }
        }
        return best
    }

    /// Location 可能是相对路径，按 API 基址解析成绝对地址
    private static func absolute(_ location: String, base: String) -> String {
        if location.contains("://") { return location }
        if location.hasPrefix("//") { return "https:" + location }
        guard let baseURL = URL(string: base) else { return location }
        return URL(string: location, relativeTo: baseURL)?.absoluteURL.absoluteString ?? location
    }

    private static func firstNonBlank(_ values: String...) -> String {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
