//
//  PanClient.swift
//  YunX · 夸克 / UC 同构客户端
//
//  两家网盘的接口结构几乎一致（同一套 sharepage/token → detail → file/download），
//  差异全部收敛在 PanConfig 里：域名、UA、pr/fr、token 请求体字段名、列表接口路径与列表字段位置。
//

import Foundation

// MARK: - 配置

struct PanConfig {
    var apiBase: String
    var webOrigin: String
    var accountInfoURL: String
    var loginURL: String
    var userAgent: String
    var cloudUA: String
    var guestUA: String?
    var guestSecChUa: String?
    var referer: String
    var pr: String
    var fr: String
    /// token 请求体里那个平台的专属布尔字段名
    var tokenFlagKey: String
    /// 分享列表接口路径
    var shareListPath: String
    /// 分享列表里 stoken 放 query（UC）还是不需要（夸克放 query 也行）
    var shareListUsesQueryStoken: Bool
    /// 列表数组在响应里的路径
    var shareListDataPath: String
    /// 下载端点 query
    var downloadQuery: String
}

enum PanConfigs {
    static let quark = PanConfig(
        apiBase: "https://drive-pc.quark.cn",
        webOrigin: "https://pan.quark.cn",
        accountInfoURL: "https://pan.quark.cn/account/info",
        loginURL: "https://pan.quark.cn/?fr=pc&platform=pc",
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch",
        cloudUA: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch",
        guestUA: nil,
        guestSecChUa: nil,
        referer: "https://pan.quark.cn/",
        pr: "ucpro",
        fr: "pc",
        tokenFlagKey: "support_visit_limit_private_share",
        shareListPath: "/1/clouddrive/share/sharepage/detail",
        shareListUsesQueryStoken: true,
        shareListDataPath: "data.list",
        downloadQuery: "?pr=ucpro&fr=pc&sys=win32&ve=3.23.2"
    )

    static let uc = PanConfig(
        apiBase: "https://pc-api.uc.cn",
        webOrigin: "https://drive.uc.cn",
        accountInfoURL: "https://drive.uc.cn/account/info",
        loginURL: "https://drive.uc.cn/",
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        cloudUA: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.6.1 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch",
        guestUA: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch",
        guestSecChUa: "\"Not=A?Brand\";v=\"99\", \"Chromium\";v=\"100\", \"Google Chrome\";v=\"100\"",
        referer: "https://drive.uc.cn/",
        pr: "UCBrowser",
        fr: "pc",
        tokenFlagKey: "share_for_transfer",
        shareListPath: "/1/clouddrive/transfer_share/detail",
        shareListUsesQueryStoken: true,
        shareListDataPath: "data.list",
        downloadQuery: "?entry=ft&fr=pc&pr=UCBrowser"
    )

    static func config(for platform: SharePlatform) -> PanConfig? {
        switch platform {
        case .quark: return .quark
        case .uc:    return .uc
        default:     return nil
        }
    }
}

// MARK: - 模型

struct ShareSession: Equatable {
    let platform: SharePlatform
    let shareId: String
    let stoken: String
    var title: String
}

struct ShareFileItem: Identifiable, Hashable {
    let fid: String
    let name: String
    let size: Int64
    let isDir: Bool
    let parentFid: String
    let fidToken: String
    let modifyTime: String

    var id: String { fid }
}

struct PanDownloadLink {
    let fid: String
    let filename: String
    let url: String
    let size: Int64
    /// 游客态直链携带的 __pugs（登录态为空）
    var guestCookie: String = ""
    /// 转存后需清理的临时目录 fid
    var cleanupDirFid: String? = nil
}

// MARK: - 工具

enum PanUtil {
    /// RFC3986 编码（stoken 里的 = / + 必须编码）
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Cookie 串里取某个键
    static func cookieValue(_ name: String, in cookie: String) -> String? {
        for part in cookie.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix(name + "=") {
                return String(kv.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    /// 幂等：把 Set-Cookie 里的指定键合并进原 Cookie
    static func mergeSetCookie(_ setCookies: [String], into cookie: String, keys: [String]) -> String {
        var map: [(String, String)] = []
        for part in cookie.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            guard let eq = kv.firstIndex(of: "=") else { continue }
            map.append((String(kv[kv.startIndex..<eq]), String(kv[kv.index(after: eq)...])))
        }
        for sc in setCookies {
            let head = sc.split(separator: ";").first.map(String.init) ?? sc
            guard let eq = head.firstIndex(of: "=") else { continue }
            let name = String(head[head.startIndex..<eq])
            let value = String(head[head.index(after: eq)...])
            guard keys.contains(name) else { continue }
            if let idx = map.firstIndex(where: { $0.0 == name }) {
                map[idx].1 = value
            } else {
                map.append((name, value))
            }
        }
        return map.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    /// 从 Set-Cookie 里抽出 __pugs=xxx
    static func pugs(from setCookies: [String]) -> String? {
        for sc in setCookies {
            let head = sc.split(separator: ";").first.map(String.init) ?? sc
            if head.hasPrefix("__pugs=") { return head }
        }
        return nil
    }

    static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie, !cookie.isEmpty else { return false }
        return cookie.contains("__pus=") && cookie.contains("__puus=")
    }
}

// MARK: - 客户端

final class PanClient {
    let platform: SharePlatform
    let config: PanConfig
    private let http: HTTPClient
    private let cookieStore: CookieStore

    /// 游客态 __pugs（约 3 小时，进程内缓存）
    private var guestPugs: String?

    init(platform: SharePlatform) {
        guard let cfg = PanConfigs.config(for: platform) else {
            fatalError("unsupported platform \(platform)")
        }
        self.platform = platform
        self.config = cfg
        self.http = HTTPClient()
        self.cookieStore = .shared
    }

    // MARK: URL 构造

    private func url(_ path: String, query: [(String, String, Bool)] = []) -> URL? {
        var comps = URLComponents(string: config.apiBase + path)
        if !query.isEmpty {
            comps?.percentEncodedQuery = query.map { item in
                let (k, v, encode) = item
                return encode ? "\(k)=\(PanUtil.encode(v))" : "\(k)=\(v)"
            }.joined(separator: "&")
        }
        return comps?.url
    }

    private func baseHeaders(cookie: String, useCloudUA: Bool = false, guest: Bool = false) -> [String: String] {
        var h: [String: String] = [:]
        let ua: String
        if guest, let guestUA = config.guestUA {
            ua = guestUA
            if let secCh = config.guestSecChUa { h["Sec-Ch-Ua"] = secCh }
        } else {
            ua = useCloudUA ? config.cloudUA : config.userAgent
        }
        h["User-Agent"] = ua
        h["Referer"] = config.referer
        if !cookie.isEmpty {
            h["Cookie"] = cookie
        }
        return h
    }

    // MARK: 信封

    @discardableResult
    private func checkEnvelope(_ json: [String: Any], allowCodeZero: Bool = false) throws -> [String: Any] {
        let status = json.yxInt("status") ?? -1
        if status == 200 {
            return json.yxDict("data")
        }
        if allowCodeZero,
           (json.yxInt("code") ?? -1) == 0,
           json["data"] != nil {
            let data = json["data"]
            if let dict = data as? [String: Any] { return dict }
            // download 端点 data 是数组，这里放行给调用方自己解析
            return ["__array__": data as Any]
        }
        let msg = json.yxString("message") ?? "请求失败（status=\(status)）"
        throw YXError.business(msg)
    }

    // MARK: 账号

    func fetchNickname(cookie: String) async -> String? {
        guard PanUtil.isValidCookie(cookie) else { return nil }
        var req = HTTPRequest(url: config.accountInfoURL)
        req.headers = ["User-Agent": config.userAgent, "Cookie": cookie]
        req.injectCookies = false
        guard let res = try? await http.send(req), res.status == 200 else { return nil }
        guard let json = try? res.json(), (json["success"] as? Bool) == true else { return nil }
        let nick = json.yxString("data.nickname") ?? ""
        return nick.isEmpty ? nil : nick
    }

    // MARK: 分享

    func shareToken(shareId: String, pwd: String?, cookie: String) async throws -> (stoken: String, title: String) {
        guard let u = url("/1/clouddrive/share/sharepage/token",
                          query: [("pr", config.pr, false), ("fr", config.fr, false)]) else {
            throw YXError.invalidURL("token")
        }
        let body: [String: Any] = [
            "pwd_id": shareId,
            "passcode": pwd ?? "",
            config.tokenFlagKey: true
        ]
        var req = HTTPRequest(url: u.absoluteString, method: "POST")
        req.headers = baseHeaders(cookie: cookie)
        req.headers["Content-Type"] = "application/json"
        req.body = try? JSONSerialization.data(withJSONObject: body)
        req.injectCookies = false

        let json = try await http.json(req)
        let data = try checkEnvelope(json)
        guard let stoken = data.yxString("stoken"), !stoken.isEmpty else {
            throw YXError.business("未获取到分享 token（可能需要提取码）")
        }
        return (stoken, data.yxString("title") ?? "分享文件")
    }

    func shareFiles(session: ShareSession, dirFid: String, page: Int = 1, size: Int = 50) async throws -> [ShareFileItem] {
        let cookie = cookieStore.cookie(for: platform) ?? ""
        var q: [(String, String, Bool)] = [
            ("pr", config.pr, false),
            ("fr", config.fr, false),
            ("pwd_id", session.shareId, true),
            ("stoken", session.stoken, true),
            ("pdir_fid", dirFid, false),
            ("_page", String(page), false),
            ("_size", String(size), false),
            ("_fetch_total", "1", false)
        ]
        if platform == .quark {
            q.append(contentsOf: [
                ("ver", "2", false),
                ("force", "0", false),
                ("_fetch_banner", "0", false),
                ("_fetch_share", "0", false),
                ("fetch_relate_conversation", "0", false),
                ("_sort", "file_type:asc,file_name:asc", false)
            ])
        } else {
            q.append(contentsOf: [
                ("entry", "ft", false),
                ("fetch_file_list", "1", false),
                ("passcode", "", false),
                ("_fetch_task", "1", false),
                ("_fetch_share", "1", false),
                ("_sort", "", false)
            ])
        }
        guard let u = url(config.shareListPath, query: q) else {
            throw YXError.invalidURL(config.shareListPath)
        }
        var req = HTTPRequest(url: u.absoluteString)
        var headers = baseHeaders(cookie: cookie)
        headers["Origin"] = platform == .uc ? "https://fast.uc.cn" : config.webOrigin
        if platform == .uc { headers["Referer"] = "https://fast.uc.cn/" }
        req.headers = headers
        req.injectCookies = false

        let json = try await http.json(req)
        _ = try checkEnvelope(json)
        // 两家都可能把列表放在 data.list 或 data.detail_info.list
        var rows = json.yxArray("data.detail_info.list")
        if rows.isEmpty { rows = json.yxArray("data.list") }

        return rows.map { row in
            ShareFileItem(
                fid: row.yxString("fid") ?? "",
                name: row.yxString("file_name") ?? row.yxString("fname") ?? "未命名",
                size: row.yxInt64("size") ?? row.yxInt64("fsize") ?? 0,
                isDir: row.yxBool("dir") ?? ((row.yxInt("isdir") ?? 0) == 1),
                parentFid: row.yxString("pdir_fid") ?? dirFid,
                fidToken: row.yxString("share_fid_token") ?? row.yxString("fid_token") ?? "",
                modifyTime: row.yxString("updated_at") ?? ""
            )
        }
    }

    /// 分页拉全（按 fid 去重；整页无新增即停）
    func shareFilesAll(session: ShareSession, dirFid: String, maxPages: Int = 20) async throws -> [ShareFileItem] {
        var all: [ShareFileItem] = []
        var seen = Set<String>()
        var page = 1
        while page <= maxPages {
            let batch = try await shareFiles(session: session, dirFid: dirFid, page: page, size: 50)
            if batch.isEmpty { break }
            var added = 0
            for item in batch where !seen.contains(item.fid) {
                seen.insert(item.fid)
                all.append(item)
                added += 1
            }
            if added == 0 { break }
            if batch.count < 50 { break }
            page += 1
        }
        return all
    }

    // MARK: 取链

    /// 登录态免转存
    func downloadLinkWithoutSave(session: ShareSession, file: ShareFileItem, cookie: String) async throws -> PanDownloadLink {
        let body: [String: Any] = [
            "fids": [file.fid],
            "fids_token": [file.fidToken],
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "speedup_session": "",
            "token": ""
        ]
        return try await requestDownload(body: body, cookie: cookie, guest: false)
    }

    /// 游客态（未登录）
    func guestDownloadLink(session: ShareSession, file: ShareFileItem) async throws -> PanDownloadLink {
        let body: [String: Any] = [
            "fids": [file.fid],
            "fids_token": [file.fidToken],
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "speedup_session": "",
            "token": ""
        ]
        return try await requestDownload(body: body, cookie: guestPugs ?? "", guest: true)
    }

    /// 个人盘 fid 取链
    func cloudDownloadLink(fid: String, cookie: String) async throws -> PanDownloadLink {
        try await requestDownload(body: ["fids": [fid]], cookie: cookie, guest: false)
    }

    private func requestDownload(body: [String: Any], cookie: String, guest: Bool) async throws -> PanDownloadLink {
        guard let u = URL(string: config.apiBase + "/1/clouddrive/file/download" + config.downloadQuery) else {
            throw YXError.invalidURL("download")
        }
        var req = HTTPRequest(url: u.absoluteString, method: "POST")
        var headers = baseHeaders(cookie: cookie, guest: guest)
        headers["Content-Type"] = "application/json"
        if platform == .uc, !guest {
            headers["Origin"] = config.webOrigin
        }
        req.headers = headers
        req.body = try? JSONSerialization.data(withJSONObject: body)
        req.injectCookies = false

        let res = try await http.send(req)

        // 游客 / 登录都必须抓本次响应的 __pugs
        let setCookies = Self.setCookies(from: res.response)
        if let pugs = PanUtil.pugs(from: setCookies) {
            guestPugs = pugs
        }

        let json = try res.json()
        let status = json.yxInt("status") ?? -1
        let code = json.yxInt("code") ?? -1
        let okEnvelope = status == 200 || code == 0
        if !okEnvelope {
            let msg = json.yxString("message") ?? "取链失败"
            throw YXError.business(Self.friendlyMessage(code: code, raw: msg))
        }

        // data 是数组
        guard let arr = json["data"] as? [[String: Any]], let first = arr.first else {
            throw YXError.business("未返回下载链接")
        }
        guard let link = first.yxString("download_url"), !link.isEmpty else {
            throw YXError.business("下载链接为空")
        }
        return PanDownloadLink(
            fid: first.yxString("fid") ?? "",
            filename: first.yxString("file_name") ?? first.yxString("filename") ?? "",
            url: link,
            size: first.yxInt64("size") ?? 0,
            guestCookie: guest ? (guestPugs ?? "") : ""
        )
    }

    static func friendlyMessage(code: Int, raw: String) -> String {
        switch code {
        case 31001: return "登录态已失效，请重新登录"
        case 23018: return "超出游客下载大小限制，请先登录"
        case 14001: return "分享已失效或提取码错误"
        case 41020: return "文件令牌已过期，请重新解析"
        case 21001: return "文件不存在（可能已被删除）"
        default:    return raw
        }
    }

    static func setCookies(from response: HTTPURLResponse) -> [String] {
        // allHeaderFields 会把重复的 Set-Cookie 合并成 ", " 分隔的单值
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie") else { return [] }
        // 简单切分：按 ", " 拆，再把形如 xxx= 开头的段合并回来
        var out: [String] = []
        for chunk in raw.components(separatedBy: ", ") {
            if chunk.contains("="), !chunk.lowercased().hasPrefix("expires") {
                if out.isEmpty {
                    out.append(chunk)
                } else if chunk.range(of: "^[A-Za-z0-9_\\-]+=", options: .regularExpression) != nil {
                    out.append(chunk)
                } else {
                    out[out.count - 1] += ", " + chunk
                }
            }
        }
        return out.map { sc in
            sc.components(separatedBy: ";").first ?? sc
        }
    }

    // MARK: 转存

    func createFolder(name: String, parentFid: String, cookie: String) async throws -> String {
        guard let u = url("/1/clouddrive/file", query: [("pr", config.pr, false), ("fr", config.fr, false)]) else {
            throw YXError.invalidURL("file")
        }
        let body: [String: Any] = [
            "pdir_fid": parentFid,
            "file_name": name,
            "dir_path": "",
            "dir_init_lock": false
        ]
        var req = HTTPRequest(url: u.absoluteString, method: "POST")
        req.headers = baseHeaders(cookie: cookie)
        req.headers["Content-Type"] = "application/json"
        req.body = try? JSONSerialization.data(withJSONObject: body)
        req.injectCookies = false
        let json = try await http.json(req)
        let data = try checkEnvelope(json)
        guard let fid = data.yxString("fid"), !fid.isEmpty else {
            throw YXError.business("创建目录失败")
        }
        return fid
    }

    func cloudFiles(parentFid: String, cookie: String, page: Int = 1, size: Int = 50) async throws -> [ShareFileItem] {
        guard let u = url("/1/clouddrive/file", query: [
            ("pr", config.pr, false), ("fr", config.fr, false),
            ("pdir_fid", parentFid, false),
            ("page", String(page), false),
            ("size", String(size), false)
        ]) else { throw YXError.invalidURL("file") }
        var req = HTTPRequest(url: u.absoluteString)
        req.headers = baseHeaders(cookie: cookie, useCloudUA: true)
        req.injectCookies = false
        let json = try await http.json(req)
        _ = try checkEnvelope(json)
        return json.yxArray("data.list").map { row in
            ShareFileItem(
                fid: row.yxString("fid") ?? "",
                name: row.yxString("file_name") ?? row.yxString("fname") ?? "未命名",
                size: row.yxInt64("size") ?? 0,
                isDir: row.yxBool("dir") ?? ((row.yxInt("isdir") ?? 0) == 1),
                parentFid: row.yxString("pdir_fid") ?? parentFid,
                fidToken: row.yxString("fid_token") ?? "",
                modifyTime: row.yxString("modify_time") ?? ""
            )
        }
    }

    func saveShareFile(session: ShareSession, file: ShareFileItem, toDirFid: String, cookie: String) async throws -> String {
        guard let u = url("/1/clouddrive/share/sharepage/save",
                          query: [("pr", config.pr, false), ("fr", config.fr, false)]) else {
            throw YXError.invalidURL("save")
        }
        let body: [String: Any] = [
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "pdir_fid": file.parentFid,
            "to_pdir_fid": toDirFid,
            "fid_list": [file.fid],
            "fid_token_list": [file.fidToken],
            "scene": "link"
        ]
        var req = HTTPRequest(url: u.absoluteString, method: "POST")
        req.headers = baseHeaders(cookie: cookie)
        req.headers["Content-Type"] = "application/json"
        req.body = try? JSONSerialization.data(withJSONObject: body)
        req.injectCookies = false
        let json = try await http.json(req)
        let data = try checkEnvelope(json)
        guard let taskId = data.yxString("task_id"), !taskId.isEmpty else {
            throw YXError.business("转存任务创建失败")
        }
        return taskId
    }

    func pollTask(taskId: String, cookie: String, maxTries: Int = 10) async throws -> String {
        for _ in 0..<maxTries {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let u = url("/1/clouddrive/task", query: [
                ("pr", config.pr, false), ("fr", config.fr, false),
                ("task_id", taskId, true),
                ("retry_index", "0", false)
            ]) else { throw YXError.invalidURL("task") }
            var req = HTTPRequest(url: u.absoluteString)
            req.headers = baseHeaders(cookie: cookie)
            req.injectCookies = false
            guard let res = try? await http.send(req),
                  let json = try? res.json(),
                  (json.yxInt("status") ?? -1) == 200,
                  json["data"] != nil else { continue }

            let finishedAt = json.yxInt64("data.finished_at") ?? 0
            let st = json.yxInt("data.status") ?? -1
            let tst = json.yxInt("data.task_status") ?? -1
            let done = finishedAt > 0 || st == 2 || tst == 2
            if done {
                if let fid = json.yxString("data.save_as.save_as_top_fids.0"), !fid.isEmpty {
                    return fid
                }
                if let raw = json.yxPath("data.save_as.save_as_top_fids") as? [String],
                   let fid = raw.first, !fid.isEmpty {
                    return fid
                }
            }
        }
        throw YXError.business("转存超时，请稍后重试")
    }

    func ensureTempDir(cookie: String) async throws -> String {
        let root = try await cloudFiles(parentFid: "0", cookie: cookie)
        if let existing = root.first(where: { $0.isDir && $0.name == "YunX临时转存" }) {
            return existing.fid
        }
        return try await createFolder(name: "YunX临时转存", parentFid: "0", cookie: cookie)
    }

    func deleteFile(fid: String, cookie: String) async {
        guard let u = url("/1/clouddrive/file/delete",
                          query: [("pr", config.pr, false), ("fr", config.fr, false)]) else { return }
        let body: [String: Any] = ["action_type": 2, "filelist": [fid], "exclude_fids": []]
        var req = HTTPRequest(url: u.absoluteString, method: "POST")
        req.headers = baseHeaders(cookie: cookie)
        req.headers["Content-Type"] = "application/json"
        req.body = try? JSONSerialization.data(withJSONObject: body)
        req.injectCookies = false
        _ = try? await http.send(req)
    }

    func quota(cookie: String) async -> (used: Int64, total: Int64)? {
        guard let u = url("/1/clouddrive/member", query: [
            ("pr", config.pr, false), ("fr", config.fr, false),
            ("fetch_subscribe", "true", false), ("_ch", "home", false)
        ]) else { return nil }
        var req = HTTPRequest(url: u.absoluteString)
        req.headers = baseHeaders(cookie: cookie, useCloudUA: true)
        req.injectCookies = false
        guard let res = try? await http.send(req),
              let json = try? res.json(),
              (json.yxInt("status") ?? -1) == 200 else { return nil }
        let used = json.yxInt64("data.use_capacity") ?? 0
        let total = json.yxInt64("data.total_capacity") ?? 0
        return total > 0 ? (used, total) : nil
    }

    /// 会话刷新：剥掉 __puus 请求 config，从 Set-Cookie 取回
    func refreshSession(cookie: String) async -> String? {
        let stripped = cookie
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("__puus=") }
            .joined(separator: "; ")
        guard let u = url("/1/clouddrive/config",
                          query: [("pr", config.pr, false), ("fr", config.fr, false)]) else { return nil }
        var req = HTTPRequest(url: u.absoluteString)
        req.headers = baseHeaders(cookie: stripped)
        req.injectCookies = false
        guard let res = try? await http.send(req) else { return nil }
        let merged = PanUtil.mergeSetCookie(Self.setCookies(from: res.response),
                                           into: cookie,
                                           keys: ["__puus", "__pus"])
        return merged == cookie ? nil : merged
    }
}
