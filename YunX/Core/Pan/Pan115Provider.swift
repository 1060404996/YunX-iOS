//
//  Pan115Provider.swift
//  YunX · 115 网盘（分享链路）
//
//  取链路径与桌面版 Pan115ResolveRepository 完全一致：`share/snap` 列目录 → `share/downurl` 取直链。
//  桌面版只在「网页端被 50029 拒发直链 **且** 已登录」时，才退回「转存 + proapi 加密直链」；
//  这条兜底要先转存到用户自己的网盘、下载完成后删除临时目录，属于个人盘写操作链路，
//  不在本文件范围内（因此也没有搬运 Pan115Crypto 的 RSA / KEY_TABLE）。
//
//  三个容易踩的点（与桌面版逐条对齐）：
//  1. 直链的 `user_id` 必须是**分享者** UID，只能从 `share/snap` 的 `data.userinfo.user_id` 拿，
//     所以 createSession 先探一次根目录，把「提取码 + 分享者 UID」塞进 session 带走；
//  2. 分享列表用 `fc == 0` 判目录，目录自身 ID 在 `cid`（文件夹项没有 `fid`）、文件 ID 在 `fid`；
//  3. 取链接口必须用**客户端 UA**（`Mozilla/5.0 115Browser/<版本>`），版本号动态拉，
//     浏览器 UA 会被判「版本过低」（50029）直接拒发；响应头的 path 绑定 32 hex CDN Cookie 下载必带。
//

import Foundation

final class Pan115Provider: PanProvider {
    let platform: SharePlatform = .pan115

    // MARK: - 常量

    private enum Const {
        static let apiBase = "https://webapi.115.com"
        static let shareHost = "https://115cdn.com"
        static let referer = "https://115.com/"
        static let downloadReferer = "https://115.com/"

        /// 业务接口（列表/用户/容量）用的桌面 Chrome UA
        static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"

        /// 客户端版本接口（免登录）与兜底版本号；版本过低会被 50029 拒发直链
        static let appVersionURL = "https://appversion.115.com/1/web/1.0/api/chrome"
        static let clientUAVersionFallback = "36.0.1"

        static let rootCid = "0"
        static let pageLimit = 100
        static let maxPages = 200

        static let acceptJSON = "application/json, text/plain, */*"
        static let xRequestedWith = "XMLHttpRequest"

        /// 登录 Cookie 需要保留的字段（alist 实测最小可用集为 UID/CID/SEID/KID）
        static let cookieKeepKeys: Set<String> = [
            "UID", "CID", "SEID", "KID", "PHPSESSID", "GST", "USERSESSIONID"
        ]

        static let errnoLoginTimeout = 990001
        static let errnoNeedCode = 4100012
        static let errnoWrongCode = 4100008
        static let errnoShareGone = 4100026
        static let errnoEmptyFolder = 4100016
        static let errnoBusy = 990009
        static let errnoNeedConfirm = 800007
        static let errnoWebSizeLimit = 50028
        static let errnoClientTooOld = 50029
    }

    /// ShareSession.extra 的键（同时兼容桌面版「提取码|分享者UID」的 stoken 编码）
    private enum SessionKey {
        static let receiveCode = "receiveCode"
        static let userId = "userId"
    }

    /// 客户端 UA 版本号进程内缓存（115 版本更新频繁，拉不到时用兜底值，不阻塞取链）
    private let versionLock = NSLock()
    private var cachedClientVersion: String?

    // MARK: - 会话

    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        let code = shareId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw YXError.business("分享链接缺少分享编号") }
        let receiveCode = (pwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // 先探分享根目录：既校验提取码（4100012 / 4100008 由 checkState 转成中文提示），
        // 又拿到分享者 UID（取直链必需）与分享标题
        let page = try await fetchPage(shareCode: code,
                                       receiveCode: receiveCode,
                                       cid: Const.rootCid,
                                       offset: 0,
                                       limit: Const.pageLimit)
        guard page.hasData else { throw YXError.business("分享链接不存在或已被删除") }

        var extra: [String: String] = [:]
        extra[SessionKey.receiveCode] = receiveCode
        extra[SessionKey.userId] = page.userId

        return ShareSession(platform: .pan115,
                            shareId: code,
                            // 与桌面版保持同一形态：<提取码>|<分享者UID>
                            stoken: receiveCode + "|" + page.userId,
                            title: page.title.isEmpty ? code : page.title,
                            extra: extra)
    }

    // MARK: - 列表

    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem] {
        let credentials = Self.credentials(of: session)
        // 分享里的目录 ID 就是 cid，根目录固定 "0"
        let cid = dirFid.isEmpty ? Const.rootCid : dirFid

        var all: [ShareFileItem] = []
        var seen = Set<String>()
        var offset = 0
        var pageIndex = 0

        while pageIndex < Const.maxPages {
            let page = try await fetchPage(shareCode: session.shareId,
                                           receiveCode: credentials.receiveCode,
                                           cid: cid,
                                           offset: offset,
                                           limit: Const.pageLimit)
            if page.items.isEmpty { break }

            var added = 0
            for item in page.items {
                let key = (item.isDir ? "d:" : "f:") + item.fid
                if seen.insert(key).inserted {
                    all.append(item)
                    added += 1
                }
            }
            offset += page.rawCount
            // 115 的 offset 是索引分页：没新增 / 不足一页 / 已取满 count 都说明到底了
            if added == 0 { break }
            if page.rawCount < Const.pageLimit { break }
            if page.total > 0 && all.count >= page.total { break }
            pageIndex += 1
        }
        return all
    }

    private struct SharePage {
        var items: [ShareFileItem]
        var total: Int
        var userId: String
        var title: String
        var hasData: Bool
        /// 服务端原样返回的行数（含被丢弃的脏行）：115 的 offset 是索引分页，必须按它前进
        var rawCount: Int
    }

    /// `GET /share/snap`（cid = 分享内目录 id，根为 "0"）
    private func fetchPage(shareCode: String,
                           receiveCode: String,
                           cid: String,
                           offset: Int,
                           limit: Int) async throws -> SharePage {
        let url = Const.apiBase + "/share/snap?" + YXURLUtil.query([
            ("share_code", shareCode),
            ("receive_code", receiveCode),
            ("offset", String(offset)),
            ("limit", String(limit)),
            ("asc", "0"),
            ("cid", cid.isEmpty ? Const.rootCid : cid),
            ("format", "json")
        ])
        let result = try await requestJSON(url: url,
                                           cookie: Self.loginCookie(),
                                           referer: Self.shareReferer(shareCode: shareCode,
                                                                      receiveCode: receiveCode),
                                           ua: Const.webUA)
        try checkState(result.json, fallback: "获取分享列表失败")

        let data = result.json.yxDict("data")
        guard !data.isEmpty else {
            return SharePage(items: [], total: 0, userId: "", title: "", hasData: false, rawCount: 0)
        }

        let rows = data.yxArray("list")
        var items: [ShareFileItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            if let item = Self.makeItem(row: row, parentFid: cid) {
                items.append(item)
            }
        }

        return SharePage(items: items,
                         total: data.yxInt("count") ?? 0,
                         userId: data.yxString("userinfo.user_id") ?? "",
                         title: data.yxString("shareinfo.share_title") ?? "",
                         hasData: true,
                         rawCount: rows.count)
    }

    /// 分享列表行 → ShareFileItem（`fc == 0` 为目录；目录 id 取 cid、文件 id 取 fid）
    private static func makeItem(row: [String: Any], parentFid: String) -> ShareFileItem? {
        let rawFid = row.yxString("fid") ?? ""
        let fc = row.yxInt("fc")
        // 与桌面版一致：fc 缺席时按「有没有 fid」判目录
        let isDir = (fc ?? (rawFid.isEmpty ? 0 : 1)) == 0
        let cid = row.yxString("cid") ?? ""
        let id = isDir ? cid : rawFid
        guard !id.isEmpty else { return nil }

        let pid = row.yxString("pid") ?? ""
        // 文件夹的 pid 是上级目录；文件的 cid 才是上级目录
        let parent = isDir
            ? (pid.isEmpty ? parentFid : pid)
            : (cid.isEmpty ? parentFid : cid)

        return ShareFileItem(fid: id,
                             name: displayName(row.yxString("n")),
                             size: isDir ? 0 : (row.yxInt64("s") ?? 0),
                             isDir: isDir,
                             parentFid: parent,
                             // pickcode（文件才有；目录通常为空）
                             fidToken: row.yxString("pc") ?? "",
                             modifyTime: row.yxString("t") ?? "")
    }

    private static func displayName(_ raw: String?) -> String {
        let value = raw ?? ""
        return value.isEmpty ? "未命名" : value
    }

    // MARK: - 取链

    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        guard !file.isDir else { throw YXError.business("文件夹无法直接下载，请选择其中的文件") }

        let credentials = Self.credentials(of: session)
        guard !credentials.userId.isEmpty else {
            throw YXError.business("缺少分享者标识，请重新解析分享链接")
        }

        // 取链接口必须用客户端 UA（浏览器 UA 会被判 50029）
        let clientUA = await clientUserAgent()

        var pairs: [(String, String)] = [
            ("dl", "1"),
            ("user_id", credentials.userId),
            ("share_code", session.shareId),
            ("file_id", file.fid)
        ]
        if !credentials.receiveCode.isEmpty {
            pairs.append(("receive_code", credentials.receiveCode))
        }
        let url = Const.apiBase + "/share/downurl?" + YXURLUtil.query(pairs)

        let loginCookie = Self.loginCookie()
        let result = try await requestJSON(url: url,
                                           cookie: loginCookie,
                                           referer: Self.shareReferer(shareCode: session.shareId,
                                                                      receiveCode: credentials.receiveCode),
                                           ua: clientUA)
        try checkState(result.json, fallback: "获取下载链接失败")

        let data = result.json.yxDict("data")
        // 网页 JS 取的是 file_url_302 || file_url || url.url，三种形态都兜住
        let direct = Self.firstNonEmpty([data.yxString("file_url_302"),
                                         data.yxString("file_url"),
                                         data.yxString("url.url")])
        guard !direct.isEmpty else { throw YXError.business("未返回下载地址，请稍后重试") }

        // 响应头的 path 绑定 Cookie（900 秒有效）下载必须带，缺它 CDN 回 403 no cookie value
        let cdnCookie = Self.downloadCookie(from: result.setCookies) ?? ""
        var headers: [String: String] = [
            "User-Agent": clientUA,
            "Referer": Const.downloadReferer,
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
        let merged = Self.mergeCookies([loginCookie, cdnCookie])
        if !merged.isEmpty { headers["Cookie"] = merged }

        // 文件名以列表为准（downurl 的 fn 偶发为空）
        let remoteName = data.yxString("fn") ?? ""
        let remoteSize = Int64(data.yxString("fs") ?? "") ?? 0

        return ResolvedDownload(url: direct,
                                filename: remoteName.isEmpty ? file.name : remoteName,
                                size: remoteSize > 0 ? remoteSize : file.size,
                                headers: headers,
                                platform: .pan115,
                                isGuest: loginCookie.isEmpty)
    }

    // MARK: - 容量 / 昵称

    func quota() async -> (used: Int64, total: Int64)? {
        let cookie = Self.loginCookie()
        guard !cookie.isEmpty else { return nil }

        guard let result = try? await requestJSON(url: Const.apiBase + "/files/index_info?count_space_nums=1",
                                                  cookie: cookie,
                                                  referer: Const.referer,
                                                  ua: Const.webUA) else { return nil }
        do {
            try checkState(result.json, fallback: "获取空间信息失败")
        } catch {
            return nil
        }

        // 桌面版读的是 space_info.all_total.size / space_info.all_use.size（单位字节）
        let total = result.json.yxInt64("data.space_info.all_total.size") ?? 0
        let used = result.json.yxInt64("data.space_info.all_use.size")
            ?? result.json.yxInt64("data.space_info.all_used.size")
            ?? 0
        guard total > 0 else { return nil }
        return (used: used < 0 ? 0 : used, total: total)
    }

    func nickname(cookie: String) async -> String? {
        let filtered = Self.filterLoginCookies(cookie)
        guard !filtered.isEmpty else { return nil }

        guard let result = try? await requestJSON(url: Const.apiBase + "/user/info?ct=json",
                                                  cookie: filtered,
                                                  referer: Const.referer,
                                                  ua: Const.webUA) else { return nil }
        do {
            try checkState(result.json, fallback: "获取用户信息失败")
        } catch {
            return nil
        }

        // 桌面版直接取 data（通常是脱敏手机号）；结构化响应里再读 uname / user_name
        let flat = (result.json.yxString("data") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !flat.isEmpty { return flat }

        let data = result.json.yxDict("data")
        let uname = (data.yxString("uname") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !uname.isEmpty { return uname }

        let userName = (data.yxString("user_name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return userName.isEmpty ? nil : userName
    }

    // MARK: - 请求

    /// 发一次 GET 并返回 JSON + 响应头里下发的 Cookie（115 的 CDN Cookie 只出现在响应头）
    private func requestJSON(url: String,
                             cookie: String,
                             referer: String,
                             ua: String) async throws -> (json: [String: Any], setCookies: [String]) {
        var request = HTTPRequest(url: url, method: "GET")
        request.headers = Self.requestHeaders(cookie: cookie, referer: referer, ua: ua)
        request.injectCookies = false
        let response = try await HTTPClient.shared.send(request)
        let setCookies = Self.rawSetCookies(from: response.response)

        guard (200...399).contains(response.status) else {
            let detail = response.text
            throw YXError.badStatus(response.status, detail.isEmpty ? nil : String(detail.prefix(160)))
        }
        if !response.data.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: response.data),
                  let json = object as? [String: Any] else {
                throw YXError.decoding("115 响应不是 JSON 对象")
            }
            return (json, setCookies)
        }
        return ([:], setCookies)
    }

    private static func requestHeaders(cookie: String, referer: String, ua: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": ua,
            "Accept": Const.acceptJSON,
            "X-Requested-With": Const.xRequestedWith,
            "Referer": referer
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    /// 成功判定只认 `state == true`（不是 errno）
    private func checkState(_ json: [String: Any], fallback: String) throws {
        if json.yxBool("state") == true { return }

        let errno = json.yxInt("errno") ?? json.yxInt("errNo") ?? 0
        let raw = Self.firstNonEmpty([json.yxString("error"), json.yxString("msg")])
        let message: String
        switch errno {
        case Const.errnoLoginTimeout:
            message = "登录已过期，请重新登录115网盘"
        case Const.errnoNeedCode:
            message = "该分享需要访问码，请填写访问码后重试"
        case Const.errnoWrongCode:
            message = "访问码错误，请检查后重试"
        case Const.errnoShareGone:
            message = "分享链接不存在或已被删除"
        case Const.errnoEmptyFolder:
            message = "不允许分享空文件夹"
        case Const.errnoBusy:
            message = "上一次操作还没完成，请稍后重试"
        case Const.errnoNeedConfirm:
            message = "操作需要二次确认，请稍后重试"
        case Const.errnoWebSizeLimit:
            message = "115 拒绝向网页端下发该文件的直链（文件过大），请改用115电脑端/手机客户端下载"
        case Const.errnoClientTooOld:
            message = "115 判定当前标识版本过低、拒绝下发直链，请改用115电脑端/手机客户端下载"
        default:
            message = raw.isEmpty ? fallback : raw
        }
        let suffix = (errno != 0 && !message.contains(String(errno))) ? "（errno=\(errno)）" : ""
        throw YXError.business(message + suffix)
    }

    // MARK: - 客户端版本 / UA

    private func clientUserAgent() async -> String {
        let version = await clientVersionValue()
        return "Mozilla/5.0 115Browser/" + version
    }

    private func clientVersionValue() async -> String {
        if let cached = cachedVersion() { return cached }

        var resolved = Const.clientUAVersionFallback
        if let result = try? await requestJSON(url: Const.appVersionURL,
                                               cookie: "",
                                               referer: Const.referer,
                                               ua: Const.webUA),
           let raw = result.json.yxString("data.win.version_code") {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isValidVersion(value) { resolved = value }
        }
        storeVersion(resolved)
        return resolved
    }

    private func cachedVersion() -> String? {
        versionLock.lock()
        defer { versionLock.unlock() }
        return cachedClientVersion
    }

    private func storeVersion(_ value: String) {
        versionLock.lock()
        if cachedClientVersion == nil { cachedClientVersion = value }
        versionLock.unlock()
    }

    /// 形如 36.0.1 / 36.0.10；过滤接口异常时的空值或垃圾串
    private static func isValidVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 16 else { return false }
        guard let first = value.first, first.isNumber else { return false }
        return value.allSatisfy { $0.isNumber || $0 == "." }
    }

    // MARK: - Cookie

    /// 登录 Cookie（只保留会话字段，噪音如 acw_tc 一律丢弃）
    private static func loginCookie() -> String {
        filterLoginCookies(PanTool.cookie(.pan115))
    }

    private static func filterLoginCookies(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var ordered: [(String, String)] = []
        for part in trimmed.components(separatedBy: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            let name = String(pair[pair.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            guard Const.cookieKeepKeys.contains(name) else { continue }
            if ordered.contains(where: { $0.0 == name }) { continue }
            ordered.append((name, String(pair[pair.index(after: eq)...])))
        }
        // 一个会话字段都没有（例如用户粘的是别的格式）：原样使用，别把 Cookie 变成空串
        if ordered.isEmpty { return trimmed }
        return ordered.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private static func mergeCookies(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
    }

    /// 分享页 Referer：有提取码时形如 `https://115cdn.com/s/<code>?password=<receiveCode>&`
    private static func shareReferer(shareCode: String, receiveCode: String) -> String {
        if receiveCode.isEmpty {
            return Const.shareHost + "/s/" + shareCode
        }
        return Const.shareHost + "/s/" + shareCode + "?password=" + receiveCode + "&"
    }

    // MARK: - Set-Cookie 解析

    /// HTTPResponse 会把重复的 Set-Cookie 合并成一个串，这里恢复成多条原始串（保留属性，用于判 path）
    private static func rawSetCookies(from response: HTTPURLResponse) -> [String] {
        var out: [String] = []
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie" else { continue }
            if let list = value as? [String] {
                out.append(contentsOf: list)
            } else if let single = value as? String {
                out.append(contentsOf: splitCombinedSetCookie(single))
            }
        }
        return out
    }

    private static func splitCombinedSetCookie(_ value: String) -> [String] {
        var out: [String] = []
        for chunk in value.components(separatedBy: ", ") {
            if chunk.isEmpty { continue }
            if out.isEmpty || startsWithCookiePair(chunk) {
                out.append(chunk)
            } else {
                // 被 Expires 里的逗号切断的尾部，粘回上一条
                out[out.count - 1] += ", " + chunk
            }
        }
        return out
    }

    private static func startsWithCookiePair(_ chunk: String) -> Bool {
        let head = chunk.components(separatedBy: ";").first ?? chunk
        guard let eq = head.firstIndex(of: "=") else { return false }
        let name = String(head[head.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 128 else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    /// 取 URL 响应里那条 path 绑定的 32 hex Cookie（path 存在且不为 "/" 优先，否则用第一条 name=value）
    private static func downloadCookie(from setCookies: [String]) -> String? {
        var fallback: String?
        for raw in setCookies {
            let segments = raw.components(separatedBy: ";")
            guard let first = segments.first else { continue }
            let pair = first.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }

            let name = String(pair[pair.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let lowered = name.lowercased()
            if lowered == "expires" || lowered == "path" || lowered == "domain" { continue }

            if fallback == nil { fallback = pair }

            var boundPath = ""
            for attribute in segments.dropFirst() {
                let item = attribute.trimmingCharacters(in: .whitespaces)
                if item.lowercased().hasPrefix("path=") {
                    boundPath = String(item.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            // 直链 CDN 只认 path 绑定的那条，其余（如 WAF 的 acw_tc）不是它
            if !boundPath.isEmpty && boundPath != "/" { return pair }
        }
        return fallback
    }

    // MARK: - 杂项

    /// 提取码与分享者 UID：优先 extra，兼容桌面版「提取码|UID」的 stoken 编码
    private static func credentials(of session: ShareSession) -> (receiveCode: String, userId: String) {
        let extraCode = session.value(SessionKey.receiveCode)
        let extraUser = session.value(SessionKey.userId)
        if !extraCode.isEmpty || !extraUser.isEmpty {
            return (extraCode, extraUser)
        }
        let parts = session.stoken.components(separatedBy: "|")
        if parts.count >= 2 {
            return (parts[0], parts[1])
        }
        if session.stoken.isEmpty { return ("", "") }
        return (session.stoken, "")
    }

    private static func firstNonEmpty(_ values: [String?]) -> String {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return ""
    }
}
