//
//  BaiduProvider.swift
//  YunX · 百度网盘（分享浏览 + 直链）
//
//  鉴权纯 Cookie：最小集 BDUSS；子目录 / 转存必须再拼接 BDCLND=<randsk>
//  （randsk 来自 share/verify，surl 已是去掉首位 "1" 的分享号，两者都塞进 session.extra）。
//
//  目录标识直接用分享内的绝对 path（根为 "/"），因为 xpan/share 按 path 走；
//  文件 fid 用 fs_id（转存需要），自己的绝对 path 放进 fidToken（取链需要）。
//
//  取链两条路：
//    ① 分享路径直接 locatedownload（公共分享 / 已验提取码）；
//    ② ① 失败且已登录 → 对齐桌面版链路：转存到临时目录 → locatedownload(转存后 path)
//       → 立即删除转存（appall 直链自带签名，删除后仍然有效）。
//

import Foundation

final class BaiduProvider: PanProvider {
    let platform: SharePlatform = .baidu

    // MARK: 常量（对齐 Kotlin BaiduConstants / BaiduApi）

    private let appID = "250528"
    private let panHost = "https://pan.baidu.com"
    private let webUA = YXUA.chrome124
    private let netdiskUA = YXUA.baiduNetdisk
    /// 桌面版临时转存目录名（BaiduConstants.TEMP_DIR_NAME）
    private let tempDirName = "YunX临时转存"

    // MARK: bdstoken 缓存（登录态内长期有效；errno=-6 时清缓存重取）

    private static var bdstokenCache: String?
    private static let bdstokenLock = NSLock()

    private static func cachedBdstoken() -> String? {
        bdstokenLock.lock()
        defer { bdstokenLock.unlock() }
        return bdstokenCache
    }

    private static func storeBdstoken(_ value: String?) {
        bdstokenLock.lock()
        defer { bdstokenLock.unlock() }
        bdstokenCache = value
    }

    // MARK: 会话

    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        let surl = shareId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surl.isEmpty else { throw YXError.business("百度分享链接缺少 surl") }

        let ck = storedCookie()
        let cleanPwd = (pwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // 公共分享（无提取码）跳过 verify：sekey 置空即可列目录
        var randsk = ""
        if !cleanPwd.isEmpty {
            randsk = try await verifyShare(surl: surl, pwd: cleanPwd, cookie: ck)
        }

        var extra: [String: String] = ["randsk": randsk]
        if !cleanPwd.isEmpty { extra["pwd"] = cleanPwd }

        // 立刻拉一页根目录：提取码错误 / 分享失效第一时间暴露，同时缓存 share_id、uk（转存兜底需要）
        let probe = try await listPage(surl: surl, randsk: randsk, dir: "/", page: 1, cookie: ck)
        if !probe.title.isEmpty { extra["title"] = probe.title }
        if !probe.shareId.isEmpty { extra["share_id"] = probe.shareId }
        if !probe.uk.isEmpty { extra["uk"] = probe.uk }

        return ShareSession(platform: .baidu,
                            shareId: surl,
                            stoken: randsk,
                            title: probe.title.isEmpty ? "百度网盘分享" : probe.title,
                            extra: extra)
    }

    // MARK: 列表

    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem] {
        let randsk = randskOf(session)
        // 浏览页统一用 "0" 表示根目录；百度的 dir 参数根目录必须是 "/"
        let dir = (dirFid.isEmpty || dirFid == "0") ? "/" : dirFid
        let ck = storedCookie()

        var all: [ShareFileItem] = []
        var seen = Set<String>()
        var page = 1
        while page <= 100 {
            let result = try await listPage(surl: session.shareId, randsk: randsk, dir: dir, page: page, cookie: ck)
            if result.items.isEmpty { break }
            var added = 0
            for item in result.items where !seen.contains(item.fid) {
                seen.insert(item.fid)
                all.append(item)
                added += 1
            }
            if added == 0 { break }
            // 满 100 条才可能有下一页（对齐桌面版 listShare 的分页条件）
            if result.items.count < 100 { break }
            page += 1
        }
        return all
    }

    private struct ListPage {
        var title: String
        var shareId: String
        var uk: String
        var items: [ShareFileItem]
    }

    /// GET /rest/2.0/xpan/share?method=list
    /// - 顶层 root=1，子目录必须 root=0（root=1 时服务端忽略 dir）
    /// - 子目录（root=0）必须带 BDCLND，否则 errno=2
    private func listPage(surl: String,
                          randsk: String,
                          dir: String,
                          page: Int,
                          cookie: String) async throws -> ListPage {
        let isRoot = dir.isEmpty || dir == "/"
        let safeDir = dir.isEmpty ? "/" : dir
        var url = panHost + "/rest/2.0/xpan/share?method=list"
            + "&shorturl=" + YXURLUtil.encode(surl)
            + "&page=" + String(page)
            + "&num=100&root=" + (isRoot ? "1" : "0")
            + "&dir=" + YXURLUtil.encode(safeDir)
        if !randsk.isEmpty {
            // randsk 本身就是 URL 编码形态（verify 原样返回），与桌面版一致不再二次编码
            url += "&sekey=" + randsk
        }

        let json = try await callJSON(url: url, headers: [
            "Cookie": authCookie(cookie, randsk: randsk),
            "User-Agent": webUA,
            "Referer": panHost + "/s/" + surl
        ])

        let errno = json.yxInt("errno") ?? 0
        if errno != 0 {
            if randsk.isEmpty {
                // 无 sekey 却失败：多是加密分享；errno=-6 另有「未登录」含义，单独提示
                let hint = errno == -6
                    ? "该分享需要提取码，或需要登录百度网盘"
                    : "该分享需要提取码"
                throw YXError.business("\(hint)（errno=\(errno)）")
            }
            if errno == -12 { throw YXError.business("提取码错误（errno=-12）") }
            if errno == 403 { throw YXError.business("分享已失效（errno=403）") }
            try checkErrno(json, fallback: "获取分享文件列表失败")
        }

        // 桌面版读顶层 list / title / share_id / uk；个别网关会把同样内容包在 data 里，两者都认
        var rows = json.yxArray("list")
        if rows.isEmpty { rows = json.yxArray("data.list") }

        let items: [ShareFileItem] = rows.compactMap { row in
            let path = row.yxString("path") ?? ""
            let isDir = (row.yxInt("isdir") ?? 0) == 1 || (row.yxString("isdir") ?? "") == "1"
            // 目录用 path 当 fid（导航传参），文件用 fs_id（转存传参）
            let fid = isDir ? path : (row.yxString("fs_id") ?? "")
            guard !fid.isEmpty else { return nil }
            return ShareFileItem(fid: fid,
                                 name: row.yxString("server_filename") ?? "未命名",
                                 size: row.yxInt64("size") ?? 0,
                                 isDir: isDir,
                                 parentFid: safeDir,
                                 fidToken: path,
                                 modifyTime: row.yxString("server_mtime") ?? "")
        }

        let title = json.yxString("title") ?? json.yxString("data.title") ?? ""
        let shareId = json.yxString("share_id") ?? json.yxString("data.share_id") ?? ""
        let uk = json.yxString("uk") ?? json.yxString("data.uk") ?? ""
        return ListPage(title: title, shareId: shareId, uk: uk, items: items)
    }

    // MARK: 取链

    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        guard !file.isDir else { throw YXError.business("文件夹不支持直接下载") }

        let ck = storedCookie()
        let randsk = randskOf(session)
        let auth = authCookie(ck, randsk: randsk)
        let path = file.fidToken.isEmpty ? file.fid : file.fidToken
        let loggedIn = isLoggedIn(ck)

        var link: String?
        var reasons: [String] = []
        let fsId = file.fid
        let fsIdIsNumeric = !fsId.isEmpty && fsId.allSatisfy({ $0.isNumber })

        // ① 桌面端主路径：转存到临时目录 → 按转存后路径 locatedownload → 立即清理
        if loggedIn {
            do {
                link = try await transferThenLocate(session: session,
                                                    file: file,
                                                    cookie: ck,
                                                    randsk: randsk)
            } catch {
                reasons.append("转存取链失败：\(error.localizedDescription)")
            }
        }

        // ② 免转存兜底：分享页签名 + sharedownload（bdstoken 不可用时这条路仍可能通）
        if link == nil, fsIdIsNumeric {
            do {
                link = try await shareDownload(surl: session.shareId, fsIds: [fsId], cookie: ck)
            } catch {
                reasons.append("免转存取链失败：\(error.localizedDescription)")
            }
        }

        // ③ 分享内路径直取（公开分享可能允许）
        if link == nil, !path.isEmpty {
            do {
                link = try await locateDownload(path: path, cookie: auth)
            } catch {
                reasons.append("直取失败：\(error.localizedDescription)")
            }
        }

        if link == nil, !loggedIn {
            reasons.append("该分享需要登录百度网盘后才能下载")
        }
        guard let finalLink = link else {
            throw YXError.business("百度取链失败\n" + reasons.joined(separator: "\n"))
        }

        var headers: [String: String] = [
            "User-Agent": webUA,          // 下载用网页 UA，不用 netdisk UA
            "Referer": panHost + "/",
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
        if !auth.isEmpty { headers["Cookie"] = auth }

        return ResolvedDownload(url: finalLink,
                                filename: file.name,
                                size: file.size,
                                headers: headers,
                                platform: .baidu,
                                isGuest: !loggedIn)
    }

    /// 转存到临时目录 → 按转存后的路径 locatedownload → 立即清理转存
    private func transferThenLocate(session: ShareSession,
                                    file: ShareFileItem,
                                    cookie: String,
                                    randsk: String) async throws -> String {
        let token = try await fetchBdstoken(cookie: cookie)

        var shareId = session.value("share_id")
        var uk = session.value("uk")
        if shareId.isEmpty || uk.isEmpty {
            // 会话里没缓存（例如外部构造的 session）：补列一次根目录取 share_id / uk
            let page = try await listPage(surl: session.shareId, randsk: randsk, dir: "/", page: 1, cookie: cookie)
            if shareId.isEmpty { shareId = page.shareId }
            if uk.isEmpty { uk = page.uk }
        }
        guard !shareId.isEmpty, !uk.isEmpty else {
            throw YXError.business("转存失败：未取到分享标识（share_id / uk）")
        }

        let toDir = await ensureTempDir(cookie: cookie, bdstoken: token)
        let newPath = try await transfer(shareId: shareId,
                                         uk: uk,
                                         sekey: randsk,
                                         fsId: file.fid,
                                         fileName: file.name,
                                         toDir: toDir,
                                         cookie: cookie,
                                         bdstoken: token)

        let link = try await locateDownload(path: newPath, cookie: authCookie(cookie, randsk: randsk))

        // appall 直链自带 sign / expires，删除转存后仍有效：立刻清理，网盘不留残留
        await deleteSilently(path: newPath, cookie: cookie, bdstoken: token)
        let tempPath = "/" + tempDirName
        if newPath.hasPrefix(tempPath + "/") {
            await deleteSilently(path: tempPath, cookie: cookie, bdstoken: token)
        }
        return link
    }

    /// POST /share/verify?surl=<surl> → randsk（直接当 sekey 用）
    private func verifyShare(surl: String, pwd: String, cookie: String) async throws -> String {
        let body = ("pwd=" + YXURLUtil.encode(pwd) + "&vcode_str=&vcode=").data(using: .utf8)
        let url = panHost + "/share/verify?surl=" + YXURLUtil.encode(surl)
        let json = try await callJSON(url: url,
                                      method: "POST",
                                      headers: [
                                        "Cookie": cookie,
                                        "User-Agent": webUA,
                                        "Referer": panHost + "/s/" + surl,
                                        "Content-Type": "application/x-www-form-urlencoded"
                                      ],
                                      body: body)

        let errno = json.yxInt("errno") ?? 0
        if errno == -12 { throw YXError.business("提取码错误（errno=-12）") }
        if errno == 403 { throw YXError.business("分享已失效（errno=403）") }
        try checkErrno(json, fallback: "验证提取码失败")

        guard let randsk = json.yxString("randsk"), !randsk.isEmpty else {
            throw YXError.business("未返回分享密钥")
        }
        return randsk
    }

    /// POST d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload
    /// 响应 urls[] / dlink[]（每项 url + encrypt）：rank1 的 d2-ant 是 encrypt=1（AES-CTR），排除
    private func locateDownload(path: String, cookie: String) async throws -> String {
        guard !path.isEmpty else { throw YXError.business("缺少文件路径，无法取链") }

        let time = Int(Date().timeIntervalSince1970)
        let url = "https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload"
            + "&app_id=" + appID
            + "&clienttype=17&ver=4.0&ant=1&check_blue=1&es=1&esl=1&apn_id=1_-1"
            + "&freeisp=0&queryfree=0&use=1&dtype=1&eck=1&ehps=1&err_ver=1.0"
            + "&network_type=WIFI&channel=0"
            + "&path=" + YXURLUtil.encode(path)
            + "&time=" + String(time)
            + "&rand=5ed606e9da222cde0474cdf70eda884b"
            + "&devuid=0F1E9FC2E084472DA5A61C4CF4C759AF"
            + "&cuid=0F1E9FC2E084472DA5A61C4CF4C759AF"
            + "&deviceid=348642637967375013"
            + "&psign=860a071f77c860e8cea06e4e54c518f3"
            + "&version=2.2.111.34&version_app=12.24.6&vip=0"
        let json = try await callJSON(url: url,
                                      method: "POST",
                                      headers: [
                                        "Cookie": cookie,
                                        "User-Agent": netdiskUA,
                                        "Content-Type": "application/x-www-form-urlencoded"
                                      ],
                                      body: "0".data(using: .utf8))
        try checkErrno(json, fallback: "获取高速下载链接失败")

        var candidates = json.yxArray("urls")
        if candidates.isEmpty { candidates = json.yxArray("dlink") }
        let usable = candidates.filter { !(($0.yxString("url") ?? "")).isEmpty }
        guard !usable.isEmpty else { throw YXError.business("未返回下载链接") }

        // ① encrypt=0（明文）且 https；② 任意 https；③ 第一个
        if let plain = usable.first(where: { ($0.yxInt("encrypt") ?? 1) == 0 && ($0.yxString("url") ?? "").hasPrefix("https") }),
           let value = plain.yxString("url"), !value.isEmpty {
            return value
        }
        if let secure = usable.first(where: { ($0.yxString("url") ?? "").hasPrefix("https") }),
           let value = secure.yxString("url"), !value.isEmpty {
            return value
        }
        if let first = usable.first, let value = first.yxString("url"), !value.isEmpty {
            return value
        }
        throw YXError.business("未返回可用的下载链接")
    }

    // MARK: 免转存分享下载（主路径）

    /// 分享页 HTML 里带 sign / timestamp / shareid / uk，用它直接调 sharedownload：
    /// 不用转存、不占用户空间、不需要 bdstoken。
    private struct ShareSign {
        var sign: String
        var timestamp: String
        var shareId: String
        var uk: String
    }

    private func sharePageSign(surl: String, cookie: String) async -> ShareSign? {
        let pageURL = panHost + "/s/" + surl
        guard let html = try? await PanTool.text(url: pageURL, headers: [
            "Cookie": cookie,
            "User-Agent": webUA,
            "Referer": panHost + "/"
        ], allowStatus: [200, 302]) else { return nil }

        // 字段在页面内嵌的 yunData 里，逐个正则比整段 JSON 解析更抗结构变化
        guard let sign = YXHTML.first("\"sign\"\\s*:\\s*\"([A-Za-z0-9]{16,64})\"", in: html)
                ?? YXHTML.first("sign=([A-Za-z0-9]{16,64})", in: html),
              let timestamp = YXHTML.first("\"timestamp\"\\s*:\\s*\"?(\\d{10,13})", in: html),
              let shareId = YXHTML.first("\"shareid\"\\s*:\\s*\"?(\\d+)\"?", in: html)
                ?? YXHTML.first("\"share_id\"\\s*:\\s*\"?(\\d+)\"?", in: html),
              let uk = YXHTML.first("\"uk\"\\s*:\\s*\"?(\\d+)\"?", in: html)
                ?? YXHTML.first("\"share_uk\"\\s*:\\s*\"?(\\d+)\"?", in: html) else {
            return nil
        }
        return ShareSign(sign: sign, timestamp: timestamp, shareId: shareId, uk: uk)
    }

    /// POST /api/sharedownload —— 免转存直链
    private func shareDownload(surl: String, fsIds: [String], cookie: String) async throws -> String {
        guard !fsIds.isEmpty else { throw YXError.business("缺少文件 ID") }
        guard let p = await sharePageSign(surl: surl, cookie: cookie) else {
            throw YXError.business("分享页签名解析失败")
        }

        let url = panHost + "/api/sharedownload?sign=" + YXURLUtil.encode(p.sign)
            + "&timestamp=" + p.timestamp
            + "&channel=chunlei&web=1&app_id=" + appID + "&clienttype=0"

        let idList = "[" + fsIds.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let body = "encrypt=0&product=share&uk=" + p.uk
            + "&primaryid=" + p.shareId
            + "&fid_list=" + YXURLUtil.encode(idList)

        var req = HTTPRequest(url: url, method: "POST")
        req.headers = [
            "Cookie": cookie,
            "User-Agent": YXUA.baiduNetdisk,
            "Referer": panHost + "/s/" + surl,
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        req.body = body.data(using: .utf8)
        req.injectCookies = false

        let json = try await HTTPClient.shared.json(req)
        let errno = json.yxInt("errno") ?? 0
        guard errno == 0 else {
            throw YXError.business("分享下载失败（errno=\(errno)）")
        }

        var usable: [[String: Any]] = []
        for key in ["dlink", "list", "data.dlink"] {
            usable.append(contentsOf: json.yxArray(key))
        }
        guard let picked = Self.pickLink(usable) else {
            // 有些响应只给 dlink 字符串数组
            if let raw = json.yxPath("dlink") as? [String], let first = raw.first, first.contains("://") {
                return first
            }
            throw YXError.business("分享下载未返回直链")
        }
        return picked
    }

    /// 选链优先级：① encrypt=0 且 https ② 任意 https ③ 第一个
    static func pickLink(_ rows: [[String: Any]]) -> String? {
        let usable = rows.filter { ($0.yxString("url") ?? "").contains("://") }
        guard !usable.isEmpty else { return nil }
        if let plain = usable.first(where: {
            ($0.yxInt("encrypt") ?? 1) == 0 && ($0.yxString("url") ?? "").hasPrefix("https")
        }), let value = plain.yxString("url"), !value.isEmpty {
            return value
        }
        if let secure = usable.first(where: { ($0.yxString("url") ?? "").hasPrefix("https") }),
           let value = secure.yxString("url"), !value.isEmpty {
            return value
        }
        if let first = usable.first, let value = first.yxString("url"), !value.isEmpty {
            return value
        }
        return nil
    }

    // MARK: 个人网盘（转存兜底用）

    /// GET /api/gettemplatevariable → result.<field>（规格写作 data.<field>，两者都认）
    private func templateValue(cookie: String, field: String) async -> String? {
        let fields = "[\"" + field + "\"]"
        let url = panHost + "/api/gettemplatevariable?clienttype=0&app_id=" + appID
            + "&web=1&fields=" + YXURLUtil.encode(fields)
        guard let json = try? await PanTool.json(url: url, headers: [
            "Cookie": cookie,
            "User-Agent": webUA,
            "Referer": panHost + "/disk/home"
        ]) else { return nil }
        guard (json.yxInt("errno") ?? 0) == 0 else { return nil }
        if let v = json.yxString("result." + field), !v.isEmpty { return v }
        if let v = json.yxString("data." + field), !v.isEmpty { return v }
        return nil
    }

    private func fetchBdstoken(cookie: String, forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cached = BaiduProvider.cachedBdstoken(), !cached.isEmpty {
            return cached
        }
        if forceRefresh { BaiduProvider.storeBdstoken(nil) }

        // ① gettemplatevariable
        if let token = await templateValue(cookie: cookie, field: "bdstoken"), !token.isEmpty {
            BaiduProvider.storeBdstoken(token)
            return token
        }
        // ② 网盘主页 HTML 里抓（gettemplatevariable 偶尔对某些账号返回空）
        if let token = await homeBdstoken(cookie: cookie), !token.isEmpty {
            BaiduProvider.storeBdstoken(token)
            return token
        }
        throw YXError.business("获取 bdstoken 失败（gettemplatevariable 与网盘主页都没返回 token，通常说明 Cookie 缺少 BDUSS/STOKEN 或已过期）")
    }

    /// 从网盘主页 HTML 里提取 bdstoken
    private func homeBdstoken(cookie: String) async -> String? {
        for path in ["/disk/home", "/disk/main"] {
            guard let html = try? await PanTool.text(url: panHost + path, headers: [
                "Cookie": cookie,
                "User-Agent": webUA,
                "Referer": panHost + "/disk/home",
                "Accept": "text/html,application/xhtml+xml"
            ], allowStatus: [200, 301, 302]) else { continue }

            if let t = YXHTML.first("\"bdstoken\"\\s*:\\s*\"([A-Za-z0-9]{8,64})\"", in: html) { return t }
            if let t = YXHTML.first("'bdstoken'\\s*:\\s*'([A-Za-z0-9]{8,64})'", in: html) { return t }
            if let t = YXHTML.first("bdstoken=([A-Za-z0-9]{8,64})", in: html) { return t }
        }
        return nil
    }

    /// 个人网盘目录下的 path 集合（用于判断临时转存目录是否存在）
    private func cloudPaths(dir: String, cookie: String, bdstoken: String) async -> [String] {
        var url = panHost + "/api/list?clienttype=0&app_id=" + appID
            + "&web=1&channel=chunlei&order=time&desc=1&showempty=0"
            + "&dir=" + YXURLUtil.encode(dir) + "&num=100&page=1"
        if !bdstoken.isEmpty { url += "&bdstoken=" + YXURLUtil.encode(bdstoken) }
        guard let json = try? await PanTool.json(url: url, headers: [
            "Cookie": cookie,
            "User-Agent": webUA,
            "Referer": panHost + "/disk/main"
        ]) else { return [] }
        guard (json.yxInt("errno") ?? 0) == 0 else { return [] }
        return json.yxArray("list").compactMap { $0.yxString("path") }
    }

    /// 临时转存目录：存在则复用，否则创建；创建失败回退根目录（鲁棒性优先）
    private func ensureTempDir(cookie: String, bdstoken: String) async -> String {
        let tempPath = "/" + tempDirName
        if await cloudPaths(dir: "/", cookie: cookie, bdstoken: bdstoken).contains(tempPath) {
            return tempPath
        }
        if await createDir(path: tempPath, cookie: cookie, bdstoken: bdstoken) {
            return tempPath
        }
        return "/"
    }

    /// POST /api/create?a=commit —— 纯 Cookie 认证下 filemanager?opera=mkdir 恒 errno=2
    private func createDir(path: String, cookie: String, bdstoken: String) async -> Bool {
        let body = ("path=" + YXURLUtil.encode(path)
            + "&isdir=1&size&block_list=%5B%5D&method=post&dataType=json").data(using: .utf8)
        let url = panHost + "/api/create?a=commit&channel=chunlei&web=1&app_id=" + appID
            + "&clienttype=0&bdstoken=" + YXURLUtil.encode(bdstoken)
        guard let json = try? await PanTool.json(url: url,
                                                 method: "POST",
                                                 headers: [
                                                   "Cookie": cookie,
                                                   "User-Agent": webUA,
                                                   "Referer": panHost + "/disk/main",
                                                   "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
                                                 ],
                                                 body: body) else { return false }
        let errno = json.yxInt("errno") ?? 0
        return errno == 0 || errno == -8   // -8 = 目录已存在
    }

    /// POST /share/transfer（body 只含 fsidlist / path）
    /// errno=-6（bdstoken 失效）时清缓存重取一次
    private func transfer(shareId: String,
                          uk: String,
                          sekey: String,
                          fsId: String,
                          fileName: String,
                          toDir: String,
                          cookie: String,
                          bdstoken: String) async throws -> String {
        var token = bdstoken
        var json = try await transferRequest(shareId: shareId,
                                             uk: uk,
                                             sekey: sekey,
                                             fsId: fsId,
                                             toDir: toDir,
                                             cookie: cookie,
                                             bdstoken: token)
        if (json.yxInt("errno") ?? 0) == -6 {
            token = try await fetchBdstoken(cookie: cookie, forceRefresh: true)
            json = try await transferRequest(shareId: shareId,
                                             uk: uk,
                                             sekey: sekey,
                                             fsId: fsId,
                                             toDir: toDir,
                                             cookie: cookie,
                                             bdstoken: token)
        }
        try checkErrno(json, fallback: "转存失败")

        if let newPath = json.yxString("extra.list.0.to"), !newPath.isEmpty {
            return newPath
        }
        // 响应缺 to 字段时按目录 + 原名拼（对齐桌面版兜底）
        let base = toDir.hasSuffix("/") ? String(toDir.dropLast()) : toDir
        return base + "/" + fileName
    }

    private func transferRequest(shareId: String,
                                 uk: String,
                                 sekey: String,
                                 fsId: String,
                                 toDir: String,
                                 cookie: String,
                                 bdstoken: String) async throws -> [String: Any] {
        var url = panHost + "/share/transfer?shareid=" + YXURLUtil.encode(shareId)
            + "&from=" + YXURLUtil.encode(uk)
            + "&channel=chunlei&ondup=newcopy&web=1&app_id=" + appID
            + "&bdstoken=" + YXURLUtil.encode(bdstoken) + "&clienttype=0"
        if !sekey.isEmpty { url += "&sekey=" + sekey }

        let body = ("fsidlist=%5B%22" + YXURLUtil.encode(fsId) + "%22%5D&path=" + YXURLUtil.encode(toDir))
            .data(using: .utf8)
        return try await callJSON(url: url,
                                  method: "POST",
                                  headers: [
                                    "Cookie": authCookie(cookie, randsk: sekey),
                                    "User-Agent": webUA,
                                    "Origin": panHost,
                                    "Referer": panHost + "/s/",
                                    "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
                                  ],
                                  body: body)
    }

    /// 删除个人网盘文件（清理转存），失败不阻断
    private func deleteSilently(path: String, cookie: String, bdstoken: String) async {
        let fileList = "[\"" + path + "\"]"
        let body = ("filelist=" + YXURLUtil.encode(fileList)).data(using: .utf8)
        let url = panHost + "/api/filemanager?async=2&onnest=fail&opera=delete"
            + "&bdstoken=" + YXURLUtil.encode(bdstoken)
            + "&newVerify=1&clienttype=0&app_id=" + appID + "&web=1"
        _ = try? await PanTool.json(url: url,
                                    method: "POST",
                                    headers: [
                                      "Cookie": cookie,
                                      "User-Agent": webUA,
                                      "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
                                    ],
                                    body: body)
    }

    // MARK: 账号

    func quota() async -> (used: Int64, total: Int64)? {
        let ck = storedCookie()
        guard isLoggedIn(ck) else { return nil }
        let url = panHost + "/api/quota?checkexpire=1&checkfree=1&clienttype=0&app_id=" + appID
            + "&web=1&channel=chunlei"
        guard let json = try? await PanTool.json(url: url, headers: [
            "Cookie": ck,
            "User-Agent": webUA,
            "X-Requested-With": "XMLHttpRequest",
            "Referer": panHost + "/disk/main"
        ]) else { return nil }
        guard (json.yxInt("errno") ?? 0) == 0 else { return nil }
        guard let total = json.yxInt64("total"), total > 0 else { return nil }
        return (used: json.yxInt64("used") ?? 0, total: total)
    }

    func nickname(cookie: String) async -> String? {
        guard isLoggedIn(cookie) else { return nil }
        return await templateValue(cookie: cookie, field: "username")
    }

    // MARK: 公共

    private func storedCookie() -> String {
        PanTool.cookie(.baidu)
    }

    private func isLoggedIn(_ cookie: String) -> Bool {
        cookie.contains("BDUSS=")
    }

    private func randskOf(_ session: ShareSession) -> String {
        let direct = session.value("randsk")
        return direct.isEmpty ? session.stoken : direct
    }

    /// 子目录 / 转存必须带 BDCLND=<randsk>（值即 sekey）；已存在则不重复拼接
    private func authCookie(_ cookie: String, randsk: String) -> String {
        guard !randsk.isEmpty, !cookie.contains("BDCLND=") else { return cookie }
        return "\(cookie); BDCLND=\(randsk)"
    }

    private func checkErrno(_ json: [String: Any], fallback: String) throws {
        let errno = json.yxInt("errno") ?? 0
        guard errno != 0 else { return }
        let message = json.yxString("err_msg") ?? json.yxString("show_msg") ?? ""
        let text = message.isEmpty ? fallback : message
        throw YXError.business("\(text)（errno=\(errno)）")
    }

    /// 统一 JSON 请求：errno=8888（限流）自动重试 3 次 × 2s
    private func callJSON(url: String,
                          method: String = "GET",
                          headers: [String: String],
                          body: Data? = nil) async throws -> [String: Any] {
        var json = try await PanTool.json(url: url, method: method, headers: headers, body: body)
        var errno = json.yxInt("errno") ?? 0
        var attempt = 0
        while errno == 8888 && attempt < 3 {
            attempt += 1
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            var retryHeaders = headers
            retryHeaders["Accept"] = "*/*"
            retryHeaders["Accept-Language"] = "zh-CN,zh;q=0.9"
            json = try await PanTool.json(url: url, method: method, headers: retryHeaders, body: body)
            errno = json.yxInt("errno") ?? 0
        }
        return json
    }
}
