//
//  LanzouProvider.swift
//  YunX · 蓝奏云（匿名分享链路，HTML 抓取型协议）
//
//  蓝奏没有 JSON API：分享页是 HTML + 内联 JS，目录分页与取链都是「同源 form POST 换 JSON」。
//  本文件按桌面版 data/network/LanzouApi.kt 逐条对齐：
//    1) GET 分享页（手动跟随跳转，每跳 host 必须在蓝奏域名族内）；
//    2) 命中 acw_sc__v2 人机校验页时本地算出 Cookie 写回并重放（纯字符串变换，见 LanzouCrypto.kt）；
//    3) 解析 HTML：title / 是否要提取码 / 是否文件夹 / fileId / lx,fid,t,k / wp_sign / ajaxdata / kdns / domain1,domain2；
//    4) 文件夹列表 POST {origin}/filemoreajax.php（zt: 1 成功 / 2 结束 / 3 提取码错 / 4 频繁）；
//    5) 取链 POST ajaxm.php（无码）/ ajaxfile.php（有码）→ {zt, dom, url, inf} → https://{dom host}/file/{url}；
//    6) HEAD 探一跳拿到最终地址与大小，并把 down_ip=1 与 acw_sc__v2 一起塞进下载头。
//
//  两个跨实例状态（重要）：
//   · LanzouProvider 由 PanProviders 每次新建，所以按 host 分罐的 Cookie 必须是 **static**：
//     蓝奏各节点下发的 acw_sc__v2 值不同，混成一个 Cookie 串必然被拒；
//   · 分享页解析结果同样放 static 缓存 —— 取链要用页面里的 wp_sign/ajaxdata/kdns/domain1，
//     缓存未命中时按 session 里记录的分享地址重新抓一次（PanProviders 不复用实例）。
//
//  传输层没有复用 HTTPClient：HTTPClient 会跟随跳转并吞掉中间跳的 Set-Cookie，
//  而本协议要求逐跳校验 host、逐跳写回 Cookie、HEAD 且不跟随跳转，因此这里用
//  一个禁止跳转的 URLSession（仍只用 Foundation）。
//

import Foundation

// MARK: - 跳转拦截

/// 让 URLSession 不自己跟随 302：蓝奏的每一跳 host 与 Set-Cookie 都必须由本文件处理。
private final class LanzouRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Provider

final class LanzouProvider: PanProvider {

    // MARK: 元信息

    let platform: SharePlatform = .lanzou

    // MARK: 常量

    /// 浏览器 UA（个人盘接口与下载节点都要求与网页一致，非浏览器 UA 易被风控）
    private static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// 域名族：lanzou*、lan[zs]o[ux]，后缀 com/net/org/cn
    private static let hostPattern = "^(?:[a-z0-9-]+\\.)*(?:lanzou[a-z]?|lan[zs]o[ux])\\.(?:com|net|org|cn)$"

    /// 下载节点注入的 Cookie（缺它下载节点拒绝直链）
    private static let downIpCookie = "down_ip=1"

    /// 列表 fId 前缀：文件夹 `d:` / 文件 `f:`（folder_id 与 file_id 会撞值）
    private static let folderPrefix = "d:"
    private static let filePrefix = "f:"

    /// 跳数 / 分页上限（防止接口异常时死循环）
    private static let maxHops = 8
    private static let maxPages = 500

    /// 分享码 → 分享地址的候选节点（ShareLinkParser 只给分享码，host 已丢失）
    private static let shareHostCandidates = ["pan.lanzoui.com", "wwx.lanzoui.com", "www.lanzoui.com"]

    // MARK: acw_sc__v2（与 LanzouCrypto.kt 逐字节一致）

    /// 重排位置表：把 arg1 的第 POS[z] 个字符放到第 z 位（1-based）
    private static let acwPosition: [Int] = [
        15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11,
        39, 18, 20, 8, 14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36
    ]

    /// 异或掩码（40 位十六进制，即 20 字节）
    private static let acwMask = "3000176000856006061501533003690027800375"

    // MARK: 跨实例状态

    private static let stateLock = NSLock()

    /// host → name → value。
    /// **必须是 static**：LanzouProvider 每次调用都是新实例，实例字段留不住 acw_sc__v2 / down_ip。
    private static var cookieJar: [String: [String: String]] = [:]

    /// 分享页解析缓存（取链需要页面里的签名变量），key = 规范化后的分享地址
    private static var pageCache: [String: SharePage] = [:]
    private static var pageKeys: [String] = []

    /// 禁止自动跳转的会话（Cookie 全部手工管理）
    private static let httpSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config,
                          delegate: LanzouRedirectBlocker(),
                          delegateQueue: nil)
    }()

    // MARK: 内部模型

    private struct RawResponse {
        var status: Int
        var body: Data
        var setCookies: [String]
        var location: String?
        var fields: [String: String]

        var text: String { String(data: body, encoding: .utf8) ?? "" }

        func header(_ name: String) -> String? { fields[name.lowercased()] }
    }

    /// 分享页解析结果
    private struct SharePage {
        var shareURL: String
        var origin: String
        var host: String
        var title: String
        var needsPwd: Bool
        var isFolder: Bool
        var fileId: String
        var iframeURL: String
        var lx: String
        var fid: String
        var t: String
        var k: String
        var sign: String
        var sizeText: String
        var html: String
        var pwd: String
    }

    private struct ProbedDownload {
        var url: String
        var size: Int64
    }

    // MARK: - PanProvider

    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        let pwdText = (pwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = Self.shareURLCandidates(shareId)
        guard !candidates.isEmpty else { throw YXError.invalidURL(shareId) }

        var lastError = YXError.business("蓝奏分享解析失败，请确认分享链接和提取码后重试")
        for url in candidates {
            do {
                return try await buildSession(shareURL: url, pwd: pwdText)
            } catch let error as YXError {
                lastError = error
                // 提取码类错误换 host 也没用，直接向上抛
                if case .business(let message) = error, message.contains("提取码") {
                    throw error
                }
                continue
            } catch {
                lastError = YXError.network(error.localizedDescription)
                continue
            }
        }
        throw lastError
    }

    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem] {
        let page = try await pageFor(session: session)

        // 单文件分享：整页就是一个文件
        if !page.isFolder {
            guard Self.isRoot(dirFid) else { return [] }
            guard !page.fileId.isEmpty else {
                throw YXError.business("蓝奏分享解析失败，请确认分享链接有效或稍后重试")
            }
            let name = page.title.isEmpty ? "蓝奏文件" : page.title
            return [ShareFileItem(fid: Self.filePrefix + page.fileId,
                                  name: name,
                                  size: Self.parseSize(page.sizeText),
                                  isDir: false,
                                  parentFid: "0",
                                  fidToken: "",
                                  modifyTime: "")]
        }

        // 文件夹分享：filemoreajax.php 分页（fid 用分享页里的那个）
        let fid = Self.isRoot(dirFid) ? page.fid : Self.stripFidPrefix(dirFid)
        guard !fid.isEmpty, !page.lx.isEmpty, !page.t.isEmpty, !page.k.isEmpty else {
            throw YXError.business("蓝奏分享分页异常，请重试")
        }
        let parentFid = dirFid.isEmpty ? "0" : dirFid
        return try await listFolder(page: page, fid: fid, parentFid: parentFid)
    }

    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        let page = try await pageFor(session: session)
        let pwd = Self.pwdOf(session)

        // 旧版单文件页把下载区放在同源 iframe 里；跨域 iframe 说明链接被改过
        var html = page.html
        if !page.iframeURL.isEmpty {
            let iframeHost = Self.hostOf(page.iframeURL)
            guard !iframeHost.isEmpty, iframeHost == page.host else {
                throw YXError.business("蓝奏下载页面地址异常，请检查分享链接")
            }
            let iframeHTML = try await fetchHTML(page.iframeURL, referer: page.shareURL)
            // 旧版把下载参数放在外层分享页，新版放在同源 iframe 里。
            // 之前直接覆盖 html：外层有 sign 而 iframe 没有时就误报
            // 「分享页缺少下载参数」。两个页面都保留，iframe 优先。
            html = iframeHTML + "\n" + page.html
        }

        // 文件 id：列表项里带 f: 前缀，单文件分享回落到页面里的 fileId
        let itemFid = Self.stripFidPrefix(file.fid)
        let fileId = itemFid.isEmpty ? page.fileId : itemFid
        guard !fileId.isEmpty else {
            throw YXError.business("蓝奏解析失败，请确认分享链接和提取码后重试")
        }

        let withPwd = !pwd.isEmpty
        let ajaxURL = Self.resolveAjaxURL(html: html,
                                          origin: page.origin,
                                          fileId: fileId,
                                          withPwd: withPwd)
        // 新版页面的签名变量叫 wp_sign，旧版叫 sign，也有以属性 / JSON 字段下发的
        guard let sign = Self.downloadSign(html) else {
            if Self.arg1(in: html) != nil || html.contains("acw_sc__v2") {
                throw YXError.business("蓝奏返回了人机验证页，请稍后重新解析")
            }
            throw YXError.business("蓝奏分享页缺少下载参数，请重新解析")
        }

        var fields: [(String, String)] = [("action", "downprocess"), ("sign", sign)]
        if withPwd {
            fields.append(("p", pwd))
            fields.append(("kd", "1"))
        } else {
            // 新版无码协议：websignkey / signs 用 ajaxdata，websign 空，kd 用 kdns
            let key = Self.jsVar(html, "ajaxdata")
                ?? Self.jsVar(html, "websignkey")
                ?? Self.inputValue(html, "websignkey")
                ?? ""
            let signs = Self.jsVar(html, "signs") ?? key
            let websign = Self.jsVar(html, "websign") ?? ""
            let kd = Self.jsVarRaw(html, "kdns") ?? "1"
            fields.append(("signs", signs))
            fields.append(("websignkey", key))
            fields.append(("websign", websign))
            fields.append(("kd", kd))
            fields.append(("ves", "1"))
        }

        let json = try await postFormJSONRetrying(url: ajaxURL,
                                                  fields: fields,
                                                  referer: page.shareURL,
                                                  origin: page.origin)
        try Self.validateAjax(json)

        let dom = Self.stringValue(json["dom"])
        let rel = Self.stringValue(json["url"])
        guard !dom.isEmpty, !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("://") else {
            throw YXError.business("蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        let domOrigin = Self.originOf(dom)
        guard !domOrigin.isEmpty else {
            throw YXError.business("蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        let jump = domOrigin + "/file/" + rel

        let referer = page.origin.isEmpty ? page.shareURL + "/" : page.origin + "/"
        let probed = try await probeDownload(jump, referer: referer)

        let inf = Self.stringValue(json["inf"])
        let filename = !file.name.isEmpty ? file.name : (inf.isEmpty ? "蓝奏文件" : inf)
        return ResolvedDownload(url: probed.url,
                                filename: filename,
                                size: probed.size > 0 ? probed.size : file.size,
                                headers: downloadHeaders(nodeURL: probed.url, referer: referer),
                                platform: .lanzou,
                                isGuest: true)
    }

    /// 个人盘不在本文件范围内
    func quota() async -> (used: Int64, total: Int64)? { nil }

    func nickname(cookie: String) async -> String? { nil }

    // MARK: - 会话

    private func buildSession(shareURL: String, pwd: String) async throws -> ShareSession {
        let page = try await fetchPage(shareURL: shareURL, pwd: pwd)
        if page.needsPwd && pwd.isEmpty {
            throw YXError.business("提取码错误：此蓝奏分享需要提取码，请填写后重新解析")
        }
        if !page.isFolder && page.fileId.isEmpty && page.sign.isEmpty {
            throw YXError.business("蓝奏分享解析失败，请确认分享链接有效或稍后重试")
        }

        Self.storePage(page.shareURL, page)

        var extra: [String: String] = [
            "shareURL": page.shareURL,
            "origin": page.origin,
            "host": page.host,
            "isFolder": page.isFolder ? "1" : "0",
            "needsPwd": page.needsPwd ? "1" : "0",
            "fileId": page.fileId,
            "sizeText": page.sizeText
        ]
        if !pwd.isEmpty { extra["pwd"] = pwd }
        if page.isFolder {
            extra["lx"] = page.lx
            extra["fid"] = page.fid
            extra["t"] = page.t
            extra["k"] = page.k
        }

        return ShareSession(platform: .lanzou,
                            shareId: page.shareURL,
                            stoken: pwd,
                            title: page.title.isEmpty ? "蓝奏云分享" : page.title,
                            extra: extra)
    }

    /// 分享页取用：先查 static 缓存，未命中按 session 里的分享地址重抓
    private func pageFor(session: ShareSession) async throws -> SharePage {
        let recorded = session.value("shareURL")
        let key = recorded.isEmpty ? session.shareId : recorded
        guard !key.isEmpty else { throw YXError.invalidURL(session.shareId) }
        if let cached = Self.cachedPage(key) { return cached }

        let normalized = Self.normalizeShareURL(key)
        let target: String
        if Self.isLanzouHost(Self.hostOf(normalized)) {
            target = normalized
        } else {
            // 会话里只存了分享码时，按候选节点兜底
            guard let first = Self.shareURLCandidates(key).first else {
                throw YXError.invalidURL(key)
            }
            target = first
        }
        let page = try await fetchPage(shareURL: target, pwd: Self.pwdOf(session))
        Self.storePage(page.shareURL, page)
        if page.shareURL != key { Self.storePage(key, page) }
        return page
    }

    // MARK: - 分享页（跳转 + 人机校验 + 解析）

    private func fetchPage(shareURL: String, pwd: String) async throws -> SharePage {
        var current = Self.normalizeShareURL(shareURL)
        var challenged = Set<String>()

        for _ in 0..<Self.maxHops {
            let host = Self.hostOf(current)
            guard Self.isLanzouHost(host) else { throw YXError.business("蓝奏分享链接无效") }

            var headers: [String: String] = [
                "User-Agent": Self.webUA,
                "Referer": current,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh;q=0.9"
            ]
            let cookie = Self.cookieHeader(host: host)
            if !cookie.isEmpty { headers["Cookie"] = cookie }

            let response = try await send(current, headers: headers)
            Self.absorb(setCookies: response.setCookies, host: host)

            if (300...399).contains(response.status) {
                guard let location = response.location, !location.isEmpty else {
                    throw YXError.business("蓝奏页面跳转次数过多，请重新解析")
                }
                let next = Self.absolutize(base: current, target: location)
                guard Self.isLanzouHost(Self.hostOf(next)) else {
                    throw YXError.business("蓝奏分享链接无效")
                }
                current = next
                continue
            }
            if response.status == 429 {
                throw YXError.business("蓝奏请求过于频繁，请稍后再试")
            }
            if response.status >= 400 {
                throw YXError.badStatus(response.status, "蓝奏文件已取消分享或不存在")
            }

            let html = response.text
            guard !html.isEmpty else { throw YXError.business("蓝奏分享页面为空，请稍后重试") }
            guard html.count <= 2_000_000 else { throw YXError.business("蓝奏分享页面过大或异常") }

            // 人机校验页：算出 acw_sc__v2 写回该 host 的罐后重放同一跳
            if let arg1 = Self.arg1(in: html) {
                guard challenged.insert(host).inserted else {
                    throw YXError.business("蓝奏需要进一步验证，请在分享页完成验证后重试")
                }
                guard let value = Self.acwScV2(arg1: arg1) else {
                    throw YXError.business("蓝奏人机校验解析失败，请稍后重试")
                }
                Self.storeCookie(host: host, name: "acw_sc__v2", value: value)
                continue
            }

            if html.contains("文件已取消") || html.contains("来晚啦") {
                throw YXError.business("蓝奏文件已取消分享或不存在")
            }
            if html.contains("请求过于频繁") || html.contains("稍后再试") {
                throw YXError.business("蓝奏请求过于频繁，请稍后再试")
            }
            return parsePage(html: html, shareURL: current, pwd: pwd)
        }
        throw YXError.business("蓝奏页面跳转次数过多，请重新解析")
    }

    private func parsePage(html: String, shareURL: String, pwd: String) -> SharePage {
        let origin = Self.originOf(shareURL)
        let host = Self.hostOf(shareURL)
        let title = Self.extractTitle(html)
        let needsPwd = html.contains("请输入密码")
            || html.contains("id=\"pwbox\"")
            || html.contains("id='pwbox'")
            || html.contains("input_password")
            || html.contains("密码不正确")
        let isFolder = html.contains("filemoreajax")
            || html.contains("class=\"filemore\"")
            || html.contains("file_more")

        let fileId = YXHTML.first("(?:ajaxm|ajaxfile)\\.php\\?file=(\\d+)", in: html)
            ?? YXHTML.first("name=[\"']file[\"']\\s+value=[\"'](\\d+)[\"']", in: html)
            ?? YXHTML.first("file=(\\d+)", in: html)
            ?? ""

        var iframeURL = YXHTML.first("<iframe[^>]+src=[\"']([^\"']+)[\"']", in: html)
            ?? YXHTML.first("<iframe[^>]+data-src=[\"']([^\"']+)[\"']", in: html)
            ?? ""
        if !iframeURL.isEmpty {
            iframeURL = Self.absolutize(base: shareURL, target: iframeURL)
        }

        var fid = Self.jsVar(html, "fid") ?? ""
        if fid.isEmpty {
            // 回落到「分享码」：path 的最后一段
            if let url = URL(string: shareURL) {
                let last = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }.last ?? ""
                fid = last
            }
        }

        let sign = Self.downloadSign(html) ?? ""
        let sizeText = YXHTML.first("(?:文件大小|大小)\\s*[:：]\\s*([0-9.]+\\s*[KMGT]?)", in: html) ?? ""

        return SharePage(shareURL: shareURL,
                         origin: origin,
                         host: host,
                         title: title,
                         needsPwd: needsPwd,
                         isFolder: isFolder,
                         fileId: fileId,
                         iframeURL: iframeURL,
                         lx: Self.jsVar(html, "lx") ?? "",
                         fid: fid,
                         t: Self.jsVar(html, "t") ?? "",
                         k: Self.jsVar(html, "k") ?? "",
                         sign: sign,
                         sizeText: sizeText,
                         html: html,
                         pwd: pwd)
    }

    // MARK: - 文件夹分页

    private func listFolder(page: SharePage, fid: String, parentFid: String) async throws -> [ShareFileItem] {
        var items: [ShareFileItem] = []
        var seen = Set<String>()
        var frequent = 0
        var pg = 1

        while pg <= Self.maxPages {
            let body = try await postFormJSONRetrying(url: page.origin + "/filemoreajax.php",
                                                      fields: [
                                                        ("lx", page.lx),
                                                        ("fid", fid),
                                                        ("t", page.t),
                                                        ("k", page.k),
                                                        ("pwd", page.pwd),
                                                        ("pg", String(pg))
                                                      ],
                                                      referer: page.shareURL,
                                                      origin: page.origin)
            switch Self.intValue(body["zt"]) {
            case 1:
                break
            case 2:
                return items
            case 3:
                throw YXError.business("提取码错误")
            case 4:
                frequent += 1
                if frequent > 3 { throw YXError.business("蓝奏请求过于频繁，请稍后再试") }
                try? await Task.sleep(nanoseconds: 600_000_000)
                continue
            default:
                throw YXError.business("蓝奏解析失败，请确认分享链接和提取码后重试")
            }

            let rows = (body["text"] as? [[String: Any]]) ?? []
            if rows.isEmpty { break }

            var added = 0
            for row in rows {
                let rawId = Self.stringValue(row["id"])
                guard !rawId.isEmpty else { continue }
                // 蓝奏的 filemoreajax 历史上把子项都当文件返回；这里只认显式的目录标记
                let isDir = Self.boolValue(row["is_dir"])
                    || Self.boolValue(row["isdir"])
                    || Self.boolValue(row["isFolder"])
                let itemFid = (isDir ? Self.folderPrefix : Self.filePrefix) + rawId
                guard seen.insert(itemFid).inserted else { continue }

                var name = Self.firstNonBlank(Self.stringValue(row["name_all"]),
                                              Self.stringValue(row["name"]))
                if name.isEmpty { name = "未命名" }
                items.append(ShareFileItem(fid: itemFid,
                                           name: name,
                                           size: isDir ? 0 : Self.parseSize(Self.stringValue(row["size"])),
                                           isDir: isDir,
                                           parentFid: parentFid,
                                           fidToken: "",
                                           modifyTime: Self.stringValue(row["time"])))
                added += 1
            }
            if added == 0 { break }
            pg += 1
        }
        return items
    }

    // MARK: - 取链探测

    /// HEAD 逐跳跟随 → 需要时解 acw 校验，最终给出可直连地址与大小
    private func probeDownload(_ jump: String, referer: String) async throws -> ProbedDownload {
        var current = jump
        var visited = Set<String>()
        var challenged = Set<String>()

        for _ in 0..<Self.maxHops {
            guard visited.insert(current).inserted else {
                throw YXError.business("蓝奏下载地址循环跳转，请重新解析")
            }
            let host = Self.hostOf(current)
            guard !host.isEmpty else {
                throw YXError.business("蓝奏下载地址暂时不可用，请稍后重试")
            }
            // 下载节点要求注入 down_ip=1
            Self.storeCookie(host: host, name: "down_ip", value: "1")

            var headers: [String: String] = [
                "User-Agent": Self.webUA,
                "Referer": referer,
                "Accept": "*/*"
            ]
            let cookie = Self.cookieHeader(host: host)
            if !cookie.isEmpty { headers["Cookie"] = cookie }

            let response = try await send(current, method: "HEAD", headers: headers)
            Self.absorb(setCookies: response.setCookies, host: host)

            if (300...399).contains(response.status) {
                guard let location = response.location, !location.isEmpty else {
                    throw YXError.business("蓝奏下载地址暂时不可用，请稍后重试")
                }
                current = Self.absolutize(base: current, target: location)
                continue
            }
            if response.status == 403 || response.status == 404 || response.status == 410 {
                throw YXError.business("蓝奏下载地址已失效，请稍后重新解析")
            }
            if response.status == 429 {
                throw YXError.business("蓝奏下载请求过于频繁，请稍后再试")
            }
            if response.status == 200 || response.status == 206 {
                var size = Self.contentSize(response)
                let contentType = (response.header("content-type") ?? "").lowercased()
                if contentType.contains("text/html") {
                    let html = try await fetchHTML(current, referer: referer)
                    if let arg1 = Self.arg1(in: html) {
                        guard challenged.insert(host).inserted else {
                            throw YXError.business("蓝奏需要进一步验证，请在分享页完成验证后重试")
                        }
                        guard let value = Self.acwScV2(arg1: arg1) else {
                            throw YXError.business("蓝奏人机校验解析失败，请稍后重试")
                        }
                        Self.storeCookie(host: host, name: "acw_sc__v2", value: value)
                        continue
                    }
                    throw YXError.business("蓝奏返回的是验证页面，未创建下载任务，请在分享页完成验证后重试")
                }
                if size <= 0 {
                    size = try await rangeSize(current, referer: referer, host: host)
                }
                return ProbedDownload(url: current, size: size)
            }

            let fallback = try await rangeSize(current, referer: referer, host: host)
            if fallback > 0 { return ProbedDownload(url: current, size: fallback) }
            throw YXError.business("蓝奏下载地址暂时不可用，请稍后重试")
        }
        throw YXError.business("蓝奏下载地址暂时不可用，请稍后重试")
    }

    private func rangeSize(_ url: String, referer: String, host: String) async throws -> Int64 {
        var headers: [String: String] = [
            "User-Agent": Self.webUA,
            "Referer": referer,
            "Accept": "*/*",
            "Range": "bytes=0-8191"
        ]
        let cookie = Self.cookieHeader(host: host)
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let response = try await send(url, headers: headers)
        Self.absorb(setCookies: response.setCookies, host: host)
        return Self.contentSize(response)
    }

    private func downloadHeaders(nodeURL: String, referer: String) -> [String: String] {
        let host = Self.hostOf(nodeURL)
        var cookie = Self.cookieHeader(host: host)
        if !cookie.contains("down_ip=") {
            cookie = cookie.isEmpty ? Self.downIpCookie : cookie + "; " + Self.downIpCookie
        }
        var headers: [String: String] = [
            "User-Agent": Self.webUA,
            "Referer": referer,
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    // MARK: - HTTP

    private func send(_ url: String,
                      method: String = "GET",
                      headers: [String: String],
                      body: Data? = nil) async throws -> RawResponse {
        guard let parsed = URL(string: url) else { throw YXError.invalidURL(url) }
        var request = URLRequest(url: parsed)
        request.httpMethod = method
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.httpBody = body
        }

        let result: (Data, URLResponse)
        do {
            result = try await Self.httpSession.data(for: request)
        } catch is CancellationError {
            throw YXError.cancelled
        } catch {
            throw YXError.network(error.localizedDescription)
        }

        guard let http = result.1 as? HTTPURLResponse else {
            throw YXError.network("非 HTTP 响应")
        }

        var fields: [String: String] = [:]
        var cookieValues: [String] = []
        for (rawKey, rawValue) in http.allHeaderFields {
            guard let key = rawKey as? String else { continue }
            let lower = key.lowercased()
            let value = (rawValue as? String) ?? String(describing: rawValue)
            if lower == "set-cookie" {
                cookieValues.append(value)
                continue
            }
            fields[lower] = value
        }
        var setCookies: [String] = []
        for value in cookieValues {
            setCookies.append(contentsOf: Self.splitSetCookie(value))
        }
        return RawResponse(status: http.statusCode,
                           body: result.0,
                           setCookies: setCookies,
                           location: fields["location"],
                           fields: fields)
    }

    private func fetchHTML(_ url: String, referer: String) async throws -> String {
        let host = Self.hostOf(url)
        var headers: [String: String] = [
            "User-Agent": Self.webUA,
            "Referer": referer,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        let cookie = Self.cookieHeader(host: host)
        if !cookie.isEmpty { headers["Cookie"] = cookie }

        let response = try await send(url, headers: headers)
        Self.absorb(setCookies: response.setCookies, host: host)
        guard response.status < 400 else {
            throw YXError.badStatus(response.status, "蓝奏文件已取消分享或不存在")
        }
        var html = response.text

        // 节点页也可能是 acw 校验页：算 Cookie 后同址重放一次
        if let arg1 = Self.arg1(in: html), let value = Self.acwScV2(arg1: arg1) {
            Self.storeCookie(host: host, name: "acw_sc__v2", value: value)
            var retryHeaders = headers
            let refreshed = Self.cookieHeader(host: host)
            if !refreshed.isEmpty { retryHeaders["Cookie"] = refreshed }
            let second = try await send(url, headers: retryHeaders)
            Self.absorb(setCookies: second.setCookies, host: host)
            html = second.text
        }
        return html
    }

    private func postFormJSONRetrying(url: String,
                                     fields: [(String, String)],
                                     referer: String,
                                     origin: String) async throws -> [String: Any] {
        var attempt = 0
        var last = YXError.network("蓝奏请求失败")
        while attempt <= 2 {
            do {
                return try await postFormJSON(url: url, fields: fields, referer: referer, origin: origin)
            } catch let error as YXError {
                switch error {
                case .network(_), .badStatus(_, _):
                    last = error
                default:
                    throw error
                }
            } catch {
                last = YXError.network(error.localizedDescription)
            }
            attempt += 1
            if attempt <= 2 {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        throw last
    }

    private func postFormJSON(url: String,
                             fields: [(String, String)],
                             referer: String,
                             origin: String) async throws -> [String: Any] {
        let host = Self.hostOf(url)
        var headers: [String: String] = [
            "User-Agent": Self.webUA,
            "Referer": referer,
            "Origin": origin,
            "X-Requested-With": "XMLHttpRequest",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        let cookie = Self.cookieHeader(host: host)
        if !cookie.isEmpty { headers["Cookie"] = cookie }

        let response = try await send(url,
                                      method: "POST",
                                      headers: headers,
                                      body: YXURLUtil.formBody(fields))
        Self.absorb(setCookies: response.setCookies, host: host)

        if response.status == 429 { throw YXError.business("蓝奏请求过于频繁，请稍后再试") }
        let text = response.text
        guard text.count <= 4_000_000 else {
            throw YXError.business("蓝奏解析服务返回内容过大，请稍后重试")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            throw YXError.business("蓝奏返回了验证页面，请稍后重试或在分享页完成验证")
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            if response.status != 200 {
                throw YXError.badStatus(response.status, "蓝奏解析服务响应异常")
            }
            throw YXError.business("蓝奏解析服务响应异常，请稍后重试")
        }
        return dict
    }

    // MARK: - Cookie 罐

    private static func storeCookie(host: String, name: String, value: String) {
        let key = host.lowercased()
        guard !key.isEmpty, !name.isEmpty, !value.isEmpty else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        var jar = cookieJar[key] ?? [:]
        jar[name] = value
        cookieJar[key] = jar
    }

    private static func cookieHeader(host: String) -> String {
        let key = host.lowercased()
        guard !key.isEmpty else { return "" }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let jar = cookieJar[key], !jar.isEmpty else { return "" }
        return jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private static func absorb(setCookies: [String], host: String) {
        guard !host.isEmpty else { return }
        for raw in setCookies {
            guard let pair = parseCookiePair(raw) else { continue }
            storeCookie(host: host, name: pair.name, value: pair.value)
        }
    }

    private static func parseCookiePair(_ raw: String) -> (name: String, value: String)? {
        let first = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { String($0) } ?? raw
        guard let eq = first.firstIndex(of: "=") else { return nil }
        let name = String(first[first.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(first[first.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !value.isEmpty else { return nil }
        return (name, value)
    }

    /// URLSession 会把多个 Set-Cookie 折成一行；Expires 里的逗号不能当分隔符，
    /// 所以只在「逗号后紧跟 name=」时切分。
    private static func splitSetCookie(_ raw: String) -> [String] {
        let chars = Array(raw)
        var out: [String] = []
        var buffer = ""
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "," {
                var scan = index + 1
                while scan < chars.count, chars[scan] == " " { scan += 1 }
                var name = ""
                var cursor = scan
                while cursor < chars.count, chars[cursor] != "=", chars[cursor] != ";", chars[cursor] != "," {
                    name.append(chars[cursor])
                    cursor += 1
                }
                let isPair = cursor < chars.count
                    && chars[cursor] == "="
                    && !name.isEmpty
                    && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                if isPair {
                    out.append(buffer)
                    buffer = ""
                    index = scan
                    continue
                }
            }
            buffer.append(ch)
            index += 1
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - 分享页缓存

    private static func cachedPage(_ key: String) -> SharePage? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pageCache[key]
    }

    private static func storePage(_ key: String, _ page: SharePage) {
        guard !key.isEmpty else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        if pageCache[key] == nil { pageKeys.append(key) }
        pageCache[key] = page
        while pageKeys.count > 8 {
            let old = pageKeys.removeFirst()
            pageCache.removeValue(forKey: old)
        }
    }

    // MARK: - HTML 提取

    private static func arg1(in html: String) -> String? {
        YXHTML.first("arg1\\s*=\\s*['\"]([0-9A-Fa-f]{40})['\"]", in: html)
    }

    /// arg1 按 POS 重排 → 与 MASK 逐字节异或 → 20 字节小写十六进制
    static func acwScV2(arg1: String) -> String? {
        let chars = Array(arg1)
        guard chars.count >= 40 else { return nil }

        var reordered = [Character](repeating: "0", count: acwPosition.count)
        for x in 0..<min(chars.count, 40) {
            for z in 0..<acwPosition.count where acwPosition[z] == x + 1 {
                reordered[z] = chars[x]
            }
        }

        let mask = Array(acwMask)
        var out = ""
        var index = 0
        while index + 2 <= reordered.count && index + 2 <= mask.count {
            let source = String(reordered[index..<(index + 2)])
            let target = String(mask[index..<(index + 2)])
            guard let a = UInt8(source, radix: 16), let b = UInt8(target, radix: 16) else {
                return nil
            }
            out += String(format: "%02x", Int(a ^ b))
            index += 2
        }
        return out.isEmpty ? nil : out
    }

    private static func extractTitle(_ html: String) -> String {
        if let raw = YXHTML.first("<title>([^<]*)</title>", in: html) {
            let clean = YXHTML.decodeEntities(raw)
                .replacingOccurrences(of: " - 蓝奏云", with: "")
                .replacingOccurrences(of: "蓝奏云", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !clean.contains("密码") { return clean }
        }
        if let raw = YXHTML.first("class=[\"']n[\"']>([^<]+)<", in: html) {
            let clean = YXHTML.stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        if let raw = YXHTML.first("var\\s+filename\\s*=\\s*[\"']([^\"']+)[\"']", in: html),
           !raw.isEmpty {
            return raw
        }
        return ""
    }

    /// 下载签名在各版本蓝奏页面里的落点不统一：JS 变量 / hidden input /
    /// HTML5 data 属性 / JSON 字段 / iframe query 都出现过，逐个兜底。
    private static func downloadSign(_ html: String) -> String? {
        let candidates: [String?] = [
            jsVar(html, "wp_sign"),
            jsVar(html, "sign"),
            inputValue(html, "sign"),
            YXHTML.first("[\"']sign[\"']\\s*:\\s*[\"']([^\"']{6,128})[\"']", in: html),
            YXHTML.first("data-sign=[\"']([^\"']{6,128})[\"']", in: html),
            YXHTML.first("[?&]sign=([A-Za-z0-9_-]{6,128})", in: html)
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// 读取带引号的 JS 变量（如 `var wp_sign = '...'`）
    private static func jsVar(_ html: String, _ name: String) -> String? {
        let pattern = "(?<![A-Za-z0-9_$])(?:(?:var|let|const)\\s+)?\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        return YXHTML.first(pattern, in: html)
    }

    /// 读取未加引号的 JS 变量（如 `var kdns = 1`）
    private static func jsVarRaw(_ html: String, _ name: String) -> String? {
        let pattern = "(?:var|let|const)\\s+\(name)\\s*=\\s*([^;,\\n\\r]+)"
        guard let raw = YXHTML.first(pattern, in: html) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func inputValue(_ html: String, _ name: String) -> String? {
        if let value = YXHTML.first("<input[^>]*name=[\"']\(name)[\"'][^>]*value=[\"']([^\"']*)[\"']",
                                    in: html) {
            return value
        }
        return YXHTML.first("<input[^>]*value=[\"']([^\"']*)[\"'][^>]*name=[\"']\(name)[\"']",
                            in: html)
    }

    /// 下载接口 URL：优先页面里的 domain1 / domain2（新版在 apifile.woozooo.com，跨域）
    private static func resolveAjaxURL(html: String,
                                       origin: String,
                                       fileId: String,
                                       withPwd: Bool) -> String {
        let apiPath = withPwd ? "/ajaxfile.php?file=" : "/ajaxm.php?file="
        for name in ["domain1", "domain2"] {
            guard let raw = jsVar(html, name), !raw.isEmpty else { continue }
            let candidate = absolutize(base: origin, target: raw)
            if candidate.contains("/ajax") { return candidate }
            let candidateOrigin = originOf(candidate)
            if !candidateOrigin.isEmpty { return candidateOrigin + apiPath + fileId }
        }
        if let absolute = YXHTML.first("https?://[^'\"\\s]+/(?:ajaxm|ajaxfile)\\.php\\?file=\\d+",
                                       in: html, group: 0) {
            return absolute
        }
        return origin + apiPath + fileId
    }

    private static func validateAjax(_ json: [String: Any]) throws {
        if intValue(json["zt"]) == 1 { return }
        let inf = stringValue(json["inf"])
        if inf.contains("密码") || inf.contains("提取码") {
            throw YXError.business("提取码错误")
        }
        if inf.contains("不存在") || inf.contains("取消") || inf.contains("过期") || inf.contains("删除") {
            throw YXError.business("蓝奏文件已取消分享或不存在")
        }
        if inf.contains("频繁") || inf.contains("次数") || inf.contains("稍后") {
            throw YXError.business("蓝奏请求过于频繁，请稍后再试")
        }
        throw YXError.business("蓝奏解析失败，请确认分享链接和提取码后重试")
    }

    // MARK: - 取值 / 单位

    /// HTML 里只有 "1.5 M" 这类展示文本，需要换算成字节
    static func parseSize(_ text: String) -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        guard let numberText = YXHTML.first("([0-9]+(?:\\.[0-9]+)?)", in: trimmed),
              let value = Double(numberText) else { return 0 }
        let unit = (YXHTML.first("([0-9]+(?:\\.[0-9]+)?)\\s*([KMGT]?)", in: trimmed, group: 2) ?? "")
            .uppercased()
        let factor: Double
        switch unit {
        case "K": factor = 1024
        case "M": factor = 1024 * 1024
        case "G": factor = 1024 * 1024 * 1024
        case "T": factor = 1024 * 1024 * 1024 * 1024
        default:  factor = 1
        }
        let bytes = value * factor
        guard bytes.isFinite, bytes >= 0, bytes < 9.0e18 else { return 0 }
        return Int64(bytes)
    }

    private static func contentSize(_ response: RawResponse) -> Int64 {
        if let contentRange = response.header("content-range") {
            let total = contentRange.split(separator: "/").last.map { String($0) } ?? ""
            if let value = Int64(total.trimmingCharacters(in: .whitespaces)) { return value }
        }
        if let length = response.header("content-length"), let value = Int64(length) {
            return value
        }
        return 0
    }

    private static func stringValue(_ raw: Any?) -> String {
        guard let raw else { return "" }
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return ""
    }

    private static func intValue(_ raw: Any?) -> Int {
        guard let raw else { return 0 }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return 0
    }

    private static func boolValue(_ raw: Any?) -> Bool {
        guard let raw else { return false }
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.intValue != 0 }
        if let text = raw as? String { return text == "1" || text.lowercased() == "true" }
        return false
    }

    private static func firstNonBlank(_ values: String...) -> String {
        for value in values where !value.isEmpty { return value }
        return ""
    }

    // MARK: - URL / 会话工具

    private static func pwdOf(_ session: ShareSession) -> String {
        let fromExtra = session.value("pwd")
        return fromExtra.isEmpty ? session.stoken : fromExtra
    }

    private static func isRoot(_ dirFid: String) -> Bool {
        dirFid.isEmpty || dirFid == "0" || dirFid == "-1"
    }

    private static func stripFidPrefix(_ fid: String) -> String {
        if fid.hasPrefix(folderPrefix) { return String(fid.dropFirst(folderPrefix.count)) }
        if fid.hasPrefix(filePrefix) { return String(fid.dropFirst(filePrefix.count)) }
        return fid
    }

    private static func normalizeShareURL(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = text.firstIndex(of: "#") {
            text = String(text[text.startIndex..<hash])
        }
        if text.lowercased().hasPrefix("http://") {
            text = "https://" + String(text.dropFirst("http://".count))
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private static func shareURLCandidates(_ shareId: String) -> [String] {
        let raw = shareId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }

        let lowered = raw.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return [normalizeShareURL(raw)]
        }
        // "wwx.lanzoui.com/xxxx" 这类缺 scheme 的形态
        if raw.contains(".") && raw.contains("/") {
            let candidate = normalizeShareURL("https://" + raw)
            if isLanzouHost(hostOf(candidate)) { return [candidate] }
        }
        // 只有分享码：host 已在解析阶段丢失，按候选节点依次尝试
        let pathPart = raw.split(separator: "/").last.map { String($0) } ?? raw
        let code = pathPart.split(separator: "?").first.map { String($0) } ?? pathPart
        guard !code.isEmpty else { return [] }
        return shareHostCandidates.map { "https://\($0)/\(code)" }
    }

    private static func hostOf(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = URL(string: trimmed), let host = parsed.host, !host.isEmpty {
            return host.lowercased()
        }
        if let parsed = URL(string: "https://" + trimmed), let host = parsed.host, !host.isEmpty {
            return host.lowercased()
        }
        return ""
    }

    private static func originOf(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = URL(string: trimmed), let host = parsed.host, !host.isEmpty {
            let scheme = (parsed.scheme ?? "https").lowercased()
            return "\(scheme)://\(host.lowercased())"
        }
        if let parsed = URL(string: "https://" + trimmed), let host = parsed.host, !host.isEmpty {
            return "https://\(host.lowercased())"
        }
        return ""
    }

    private static func isLanzouHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        return YXHTML.first(hostPattern, in: host, group: 0) != nil
    }

    private static func absolutize(base: String, target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return trimmed }
        let origin = originOf(base)
        guard !origin.isEmpty else { return trimmed }
        if trimmed.isEmpty { return base }
        // "//host/path" 必须先于单斜杠判断，否则会被当成站内路径
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("/") { return origin + trimmed }
        return origin + "/" + trimmed
    }
}
