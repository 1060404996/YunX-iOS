//
//  GuangYaProvider.swift
//  YunX · 光鸭云盘（分享解析；匿名请求也必须带设备头）
//
//  协议唯一真源：desktop 端 Kotlin
//    data/network/GuangYaApi.kt、data/network/GuangYaConstants.kt、
//    data/repository/GuangYaResolveRepository.kt
//
//  分享链路（accessToken 只放 body，不放 Authorization 头）：
//    1) POST /userres/v1/get_share_summary        → 标题
//    2) POST /userres/v1/get_share_access_token   → data.accessToken（业务码 209 = 提取码错误）
//    3) POST /userres/v1/get_share_page_files_list→ 游标翻页列目录（pageSize 100）
//    4) POST /userres/v1/get_share_download_url   → data.signedURL（业务码 207 = 需登录转存）
//
//  账号态（容量 / 昵称）走 account.guangyapan.com，带一整套 X-Device-* 头，
//  令牌从 CookieStore 里保存的会话串中提取（提取规则见 accountToken(from:)）。
//

import Foundation

final class GuangYaProvider: PanProvider {

    let platform: SharePlatform = .guangya

    // MARK: - 常量（对齐 GuangYaConstants）

    private static let apiBase = "https://api.guangyapan.com"
    private static let accountBase = "https://account.guangyapan.com"
    private static let webSite = "https://www.guangyapan.com"
    private static let clientId = "aMe-8VSlkrbQXpUR"
    private static let pageSize = 100
    private static let deviceIdKey = "yunx.guangya.deviceId"

    /// 业务 API 的 did 设备头：匿名也必带，且只生成一次（持久化到 UserDefaults）
    private let deviceId: String

    init() {
        self.deviceId = GuangYaProvider.loadDeviceId()
    }

    /// wdi10.<32hex 设备 id><32hex 随机>，尾部随机段每次账号请求重新生成
    private var deviceSign: String {
        "wdi10." + deviceId + YXCrypto.randomHex(16)
    }

    // MARK: - 会话

    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        let id = shareId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw YXError.business("光鸭分享 id 为空") }
        let code = (pwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) 摘要取标题（失败不阻断，标题只是展示用）
        let title = await shareTitle(shareId: id)

        // 2) 提取码换分享访问令牌：业务码 209 在这里抛出可读错误
        let tokenJSON = try await businessCall("/userres/v1/get_share_access_token",
                                              body: ["shareId": id, "code": code])
        try GuangYaProvider.checkBusiness(tokenJSON, fallback: "获取分享访问令牌失败")
        guard let tokenData = dataOf(tokenJSON) else {
            throw YXError.business("光鸭分享链接无效")
        }
        let accessToken = GuangYaProvider.firstNonBlank(tokenData.yxString("accessToken") ?? "",
                                                        tokenData.yxString("access_token") ?? "")
        guard !accessToken.isEmpty else {
            throw YXError.business("光鸭分享链接无效")
        }

        var session = ShareSession(platform: .guangya,
                                   shareId: id,
                                   stoken: accessToken,
                                   title: title.isEmpty ? "光鸭分享" : title,
                                   extra: ["pwd": code])

        // 3) 真正打一次列目录做校验：分享失效 / 令牌无效在这里立刻暴露
        _ = try await fetchPage(session: session, parentId: "", cursor: nil)
        return session
    }

    private func shareTitle(shareId: String) async -> String {
        guard let json = try? await businessCall("/userres/v1/get_share_summary",
                                                body: ["shareId": shareId]) else { return "" }
        guard GuangYaProvider.isSuccess(json) else { return "" }
        let node = dataOf(json) ?? json
        return GuangYaProvider.firstNonBlank(node.yxString("title") ?? "",
                                             node.yxString("shareName") ?? "")
    }

    // MARK: - 列表

    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem] {
        var all: [ShareFileItem] = []
        var seen = Set<String>()
        var cursor: String? = nil
        var page = 0
        let parentId = GuangYaProvider.shareParentId(dirFid)

        while page < 1000 {
            let result = try await fetchPage(session: session, parentId: parentId, cursor: cursor)
            for item in result.items where !seen.contains(item.fid) {
                seen.insert(item.fid)
                all.append(item)
            }
            guard let next = result.nextCursor, !next.isEmpty, next != cursor else { break }
            cursor = next
            page += 1
        }
        return all
    }

    private struct PageResult {
        var items: [ShareFileItem]
        var nextCursor: String?
    }

    private func fetchPage(session: ShareSession,
                           parentId: String,
                           cursor: String?) async throws -> PageResult {
        var body: [String: Any] = [
            "parentId": parentId,
            "pageSize": GuangYaProvider.pageSize,
            "orderBy": 0,
            "sortType": 0,
            "accessToken": session.stoken
        ]
        if let cursor, !cursor.isEmpty { body["cursor"] = cursor }

        let json = try await businessCall("/userres/v1/get_share_page_files_list", body: body)
        try GuangYaProvider.checkBusiness(json, fallback: "获取分享文件列表失败")

        guard let data = dataOf(json) else {
            return PageResult(items: [], nextCursor: nil)
        }
        let rows = GuangYaProvider.listRows(data)
        let items = rows.compactMap { GuangYaProvider.parseItem($0, parentFid: parentId) }

        let rawCursor = (data.yxString("cursor") ?? "").trimmingCharacters(in: .whitespaces)
        let hasMore = data.yxBool("hasMore")
        let next: String?
        if let hasMore {
            next = hasMore && !rawCursor.isEmpty ? rawCursor : nil
        } else {
            // hasMore 缺省时以 cursor 是否存在为准（避免服务端只回 cursor 时被截断成单页）
            next = rawCursor.isEmpty ? nil : rawCursor
        }
        return PageResult(items: items, nextCursor: next)
    }

    // MARK: - 取链

    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        guard !file.isDir else { throw YXError.business("文件夹无法直接下载") }

        let json = try await businessCall("/userres/v1/get_share_download_url",
                                          body: ["fileId": file.fid, "accessToken": session.stoken])
        // 207 = 分享者未开启免登录下载（需登录转存），checkBusiness 会给出可读文案
        try GuangYaProvider.checkBusiness(json, fallback: "获取下载地址失败")

        guard let data = dataOf(json) else {
            throw YXError.business("光鸭未返回有效下载地址，请确认下载权限")
        }
        let url = GuangYaProvider.firstNonBlank(data.yxString("signedURL") ?? "",
                                                data.yxString("signedUrl") ?? "",
                                                data.yxString("downloadUrl") ?? "",
                                                data.yxString("download_url") ?? "",
                                                data.yxString("url") ?? "",
                                                data.yxString("cdnUrl") ?? "")
        guard !url.isEmpty else {
            throw YXError.business("光鸭未返回有效下载地址，请确认下载权限")
        }
        let dataSize = Int64(GuangYaProvider.firstNonBlank(data.yxString("size") ?? "")) ?? 0

        return ResolvedDownload(
            url: url,
            filename: file.name,
            size: dataSize > 0 ? dataSize : file.size,
            headers: [
                "User-Agent": YXUA.chromeDesktop,
                "Referer": GuangYaProvider.webSite + "/",
                "Origin": GuangYaProvider.webSite,
                "Accept": "*/*",
                "Accept-Encoding": "identity"
            ],
            platform: .guangya,
            isGuest: PanTool.cookie(.guangya).isEmpty
        )
    }

    // MARK: - 账号态

    func quota() async -> (used: Int64, total: Int64)? {
        let token = GuangYaProvider.accountToken(from: PanTool.cookie(.guangya))
        guard !token.isEmpty else { return nil }
        guard let json = try? await businessCall("/assets/v1/get_assets", body: [:], token: token) else {
            return nil
        }
        guard GuangYaProvider.isSuccess(json), let data = dataOf(json) else { return nil }
        let total = Int64(GuangYaProvider.firstNonBlank(data.yxString("totalSpaceSize") ?? "",
                                                        data.yxString("total_space_size") ?? "")) ?? 0
        guard total > 0 else { return nil }
        let used = Int64(GuangYaProvider.firstNonBlank(data.yxString("usedSpaceSize") ?? "",
                                                       data.yxString("used_space_size") ?? "")) ?? 0
        return (used: used, total: total)
    }

    func nickname(cookie: String) async -> String? {
        let token = GuangYaProvider.accountToken(from: cookie)
        guard !token.isEmpty else { return nil }

        var req = HTTPRequest(url: GuangYaProvider.accountBase + "/v1/user/me", method: "GET")
        req.headers = accountHeaders(token: token)
        req.injectCookies = false
        guard let res = try? await HTTPClient.shared.send(req) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: res.data)) as? [String: Any] else {
            return nil
        }
        guard GuangYaProvider.isSuccess(json) else { return nil }
        let nick = GuangYaProvider.firstNonBlank(json.yxString("nickname") ?? "",
                                                 json.yxString("nick_name") ?? "",
                                                 json.yxString("name") ?? "",
                                                 json.yxString("username") ?? "")
        return nick.isEmpty ? nil : nick
    }

    // MARK: - 请求

    /// 业务 API：body 里放 accessToken；Authorization 仅用于账号态接口
    private func businessCall(_ path: String,
                              body: [String: Any],
                              token: String? = nil) async throws -> [String: Any] {
        var req = HTTPRequest(url: GuangYaProvider.apiBase + path, method: "POST")
        req.headers = businessHeaders(token: token)
        req.body = PanTool.jsonBody(body)
        req.injectCookies = false

        let res = try await HTTPClient.shared.send(req)
        guard let json = (try? JSONSerialization.jsonObject(with: res.data)) as? [String: Any] else {
            if res.text.isEmpty {
                throw YXError.badStatus(res.status, "光鸭服务无响应（HTTP \(res.status)）")
            }
            throw YXError.badStatus(res.status, "光鸭返回了非 JSON 响应（HTTP \(res.status)）")
        }
        return json
    }

    /// 业务头：Accept / Content-Type / UA / Origin / Referer / dt / traceparent / did（匿名也必带）
    private func businessHeaders(token: String?) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "User-Agent": YXUA.chromeDesktop,
            "Origin": GuangYaProvider.webSite,
            "Referer": GuangYaProvider.webSite + "/",
            "dt": "4",
            "traceparent": GuangYaProvider.newTraceparent(),
            "did": deviceId
        ]
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    /// 账号头：X-Device-Id / X-Device-Sign 需 URL 编码（deviceSign 是 hex + 点，编码后不变）
    private func accountHeaders(token: String?) -> [String: String] {
        var headers: [String: String] = [
            "X-Client-Id": GuangYaProvider.clientId,
            "X-Client-Version": "0.0.1",
            "X-Device-Id": YXURLUtil.encode(deviceId),
            "X-Device-Model": "chrome%2F131.0.0.0",
            "X-Device-Name": "PC-Chrome",
            "X-Device-Sign": YXURLUtil.encode(deviceSign),
            "X-Os-Version": "Win32",
            "X-Platform-Version": "1",
            "X-Protocol-Version": "301",
            "X-Sdk-Version": "9.1.3",
            "Accept": "application/json, text/plain, */*",
            "User-Agent": YXUA.chromeDesktop
        ]
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    /// traceparent 每请求重新生成：00-<32hex>-<16hex>-01
    private static func newTraceparent() -> String {
        "00-" + YXCrypto.randomHex(16) + "-" + YXCrypto.randomHex(8) + "-01"
    }

    // MARK: - 响应处理

    /// 成功判定：success != false && error 为空 && (code 为空 || code == "0")
    private static func isSuccess(_ json: [String: Any]) -> Bool {
        if let success = json.yxBool("success"), success == false { return false }
        let error = (json.yxString("error") ?? "").trimmingCharacters(in: .whitespaces)
        if !error.isEmpty { return false }
        let code = (json.yxString("code") ?? "").trimmingCharacters(in: .whitespaces)
        return code.isEmpty || code == "0"
    }

    private static func message(for code: String) -> String? {
        switch code {
        case "209":                 return "光鸭分享提取码错误或缺失"
        case "200", "201", "202":   return "光鸭分享已取消、过期或不可访问"
        case "205", "206", "504":   return "光鸭分享下载受限，请在官网确认该分享的下载权限"
        case "207":                 return "该光鸭分享需登录并转存后下载，请先登录光鸭云盘"
        case "157":                 return "光鸭网盘空间不足"
        default:                    return nil
        }
    }

    private static func checkBusiness(_ json: [String: Any], fallback: String) throws {
        if isSuccess(json) { return }
        let code = (json.yxString("code") ?? "").trimmingCharacters(in: .whitespaces)
        let serverMsg = firstNonBlank(json.yxString("msg") ?? "",
                                      json.yxString("message") ?? "",
                                      json.yxString("error_description") ?? "",
                                      json.yxString("error") ?? "")
        if let mapped = message(for: code) { throw YXError.business(mapped) }
        if !serverMsg.isEmpty { throw YXError.business(serverMsg) }
        throw YXError.business("\(fallback)（code=\(code)）")
    }

    private func dataOf(_ json: [String: Any]) -> [String: Any]? {
        json["data"] as? [String: Any]
    }

    /// 列表数组名不固定，按源码顺序兜底
    private static func listRows(_ data: [String: Any]) -> [[String: Any]] {
        for key in ["list", "items", "files", "records", "content"] {
            if let rows = data[key] as? [[String: Any]] { return rows }
        }
        return []
    }

    // MARK: - 行解析

    private static func parseItem(_ row: [String: Any], parentFid: String) -> ShareFileItem? {
        let fid = firstNonBlank(row.yxString("fileId") ?? "",
                                row.yxString("file_id") ?? "",
                                row.yxString("id") ?? "",
                                row.yxString("resId") ?? "",
                                row.yxString("resourceId") ?? "")
        guard !fid.isEmpty else { return nil }

        let name = firstNonBlank(row.yxString("fileName") ?? "",
                                 row.yxString("name") ?? "",
                                 row.yxString("filename") ?? "",
                                 row.yxString("dirName") ?? "",
                                 row.yxString("title") ?? "")
        let size = Int64(firstNonBlank(row.yxString("fileSize") ?? "",
                                       row.yxString("size") ?? "",
                                       row.yxString("file_size") ?? "")) ?? 0

        let isDir = resolveIsDir(row, name: name)
        let parent = firstNonBlank(row.yxString("parentId") ?? "",
                                   row.yxString("parentFileId") ?? "",
                                   row.yxString("parent_id") ?? "")
        let time = firstNonBlank(row.yxString("updatedAt") ?? "",
                                 row.yxString("updateAt") ?? "",
                                 row.yxString("updated_at") ?? "",
                                 row.yxString("updateTime") ?? "",
                                 row.yxString("mtime") ?? "",
                                 row.yxString("utime") ?? "",
                                 row.yxString("createdAt") ?? "",
                                 row.yxString("createTime") ?? "",
                                 row.yxString("ctime") ?? "")

        return ShareFileItem(fid: fid,
                             name: name.isEmpty ? "未命名" : name,
                             size: size,
                             isDir: isDir,
                             parentFid: parent.isEmpty ? parentFid : parent,
                             fidToken: "",
                             modifyTime: time)
    }

    /// resType 优先（"2"=目录 / "1"=文件），否则看各类布尔与命名兜底
    private static func resolveIsDir(_ row: [String: Any], name: String) -> Bool {
        let resType = (row.yxString("resType") ?? "").trimmingCharacters(in: .whitespaces)
        if resType == "2" { return true }
        if resType == "1" { return false }

        let flag = (row.yxBool("isDir") ?? false)
            || (row.yxBool("isdir") ?? false)
            || (row.yxBool("dir") ?? false)
            || (row.yxBool("isFolder") ?? false)
            || (row.yxBool("folder") ?? false)
        if flag { return true }

        let dirName = (row.yxString("dirName") ?? "").trimmingCharacters(in: .whitespaces)
        if !dirName.isEmpty { return true }

        let dirWords: Set<String> = ["folder", "dir", "directory", "0"]
        if dirWords.contains((row.yxString("type") ?? "").lowercased()) { return true }
        if dirWords.contains((row.yxString("fileType") ?? "").lowercased()) { return true }

        let dirType = (row.yxString("dirType") ?? "").trimmingCharacters(in: .whitespaces)
        return !name.contains(".") && dirType == "1"
    }

    // MARK: - 工具

    /// 分享根目录 id 是空串（ROOT_PARENT_ID），UI 侧传 "0"
    private static func shareParentId(_ dirFid: String) -> String {
        let raw = dirFid.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw == "0" ? "" : raw
    }

    private static func loadDeviceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIdKey), isValidDeviceId(existing) {
            return existing
        }
        // randomHex(16) = 32 个 hex 字符
        let fresh = YXCrypto.randomHex(16)
        defaults.set(fresh, forKey: deviceIdKey)
        return fresh
    }

    private static func isValidDeviceId(_ value: String) -> Bool {
        value.count == 32 && value.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
    }

    /// 从 Cookie 会话串里提取账号 access token。
    /// 支持三种粘贴形态：直接贴 token、贴 "k=v; k=v" 的 Cookie 头、贴 "Bearer xxx"。
    private static func accountToken(from cookie: String) -> String {
        let raw = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        if !raw.contains("=") {
            let value = raw.lowercased().hasPrefix("bearer ") ? String(raw.dropFirst(7)) : raw
            return value.trimmingCharacters(in: .whitespaces)
        }

        var named = ""
        var fallback = ""
        for part in raw.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = pair[pair.startIndex..<eq].lowercased()
            var value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("bearer ") { value = String(value.dropFirst(7)) }
            guard value.count >= 16 else { continue }
            if key.contains("token") || key.contains("auth") {
                if value.count > named.count { named = value }
            } else if value.count > fallback.count, value.filter({ $0 == "." }).count == 2 {
                // JWT 形态（三段点分）兜底
                fallback = value
            }
        }
        return named.isEmpty ? fallback : named
    }

    private static func firstNonBlank(_ values: String...) -> String {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
