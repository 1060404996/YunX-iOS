//
//  XunleiProvider.swift
//  YunX · 迅雷网盘（游客态分享解析）
//
//  与桌面端 Kotlin 实现一一对应（XunleiApi.kt / XunleiConstants.kt /
//  XunleiDeviceFingerprint.kt / XunleiWebCredential.kt）：
//  · 设备指纹 deviceId / peerId 首次生成后持久化复用，devicesign 按 §8 公式派生；
//  · pan 请求头固定为「桌面 UA + X-Device-Id + X-Client-Version」，抓包确认无 x-signature；
//  · 游客态（无 access_token）**不写 Authorization 行** —— 写空 Bearer 会被判 unauthenticated；
//  · 分享接口在 share_status ∈ {PASS_CODE_EMPTY/ERROR/NEED} 时 HTTP 200 但 files 为空数组，
//    必须显式判掉，否则会被误显示成「此目录为空」。
//

import Foundation

// MARK: - 协议常量（照抄 Kotlin 源码，盐的顺序敏感，一位都不能改）

private enum XC {
    static let authBase = "https://xluser-ssl.xunlei.com"
    static let panBase = "https://api-pan.xunlei.com"

    /// 客户端版本 / 包名（captcha_sign 的 raw 与 pan 头共用）
    static let clientVersion = "8.31.0.9726"
    static let packageName = "com.xunlei.downloadprovider"

    /// App 通道 OAuth 凭据
    static let appClientId = "Xp6vsxz_7IYVw2BB"
    static let appClientSecret = "Xp6vsy4tN9toTVdMSpomVdXpRmES"

    /// 网页通道 OAuth client_id（刷新**不带** secret，与 App 不是同一套客户端）
    static let webClientId = "Xqp0kJBXWhwaTpB6"

    /// devicesign 派生常量（§8：div101.{deviceId}{md5(sha1(deviceId+package+appid+appkey))}）
    static let appId = "40"
    static let appKey = "34a062aaa22f906fca4fefe9fb3a3021"

    /// 网页通道 captcha 签名参数（版本与 9 条盐随 bundle 轮换，必须整组更新）
    static let webClientVersion = "1.93.10"
    static let webPackageName = "pan.xunlei.com"
    static let webSignHost = "pan.xunlei.com"

    /// 浏览器 UA（pan 接口用；注意比 YXUA.chromeDesktop 短，末尾没有 Chrome/xx 段）
    static let webUa = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    /// 官方 App UA（仅 captcha/init 与换 token 用）
    static let appUa = "ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 "
        + "deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 "
        + "platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)"

    /// App 通道 10 条盐（XunleiConstants.CAPTCHA_SALTS，顺序敏感）
    static let appSalts: [String] = [
        "9uJNVj/wLmdwKrJaVj/omlQ",
        "Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf",
        "Eb+L7Ce+Ej48u",
        "jKY0",
        "ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd",
        "wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK",
        "gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O",
        "5IiCoM9B1/788ntB",
        "P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf",
        "+oK0AN"
    ]

    /// 网页通道 9 条盐（XunleiWebCredential.WEB_CAPTCHA_SALTS，顺序敏感）
    static let webSalts: [String] = [
        "DVM8BRQfJWDsIE0JbH5GCUM0z0jU1yGymBTj4Eyloazv1F+w0G7ig",
        "T",
        "a1fUxfjOO1/dW++DpGupRgw9P93L",
        "aktKbp+/lQc3MvlMHIupt65LjAgJOL6ttMFvTKK+7+WKubSf9rT",
        "SB/ne9FQUnQmWz4Wuv9KqKfGOBOCUubpHpECxOHfD4hNoMclYA2Yq",
        "sOZFBQ8IMFy3OFjAIf/eA65iqFvS9TIKzLyrhiT6",
        "ZhJdLgL7MGh2GanboB0yk",
        "Osf",
        "v"
    ]

    /// 网页 captcha_token 只有 300s，按 270s 保守处理（与 Kotlin WEB_CAPTCHA_TOKEN_TTL_MS 一致）
    static let webCaptchaTtl: TimeInterval = 270

    /// App 通道 captcha_token 有效期兜底（服务端 expires_in 缺失时用）
    static let appCaptchaTtl: TimeInterval = 240

    /// App 通道签名：raw = client_id + client_version + package_name + device_id + ts → 10 层 md5
    static func appCaptchaSign(deviceId: String, timestamp: String) -> String {
        var hash = appClientId + clientVersion + packageName + deviceId + timestamp
        for salt in appSalts {
            hash = YXCrypto.md5Hex(hash + salt)
        }
        return "1." + hash
    }

    /// 网页通道签名：raw = client_id + version + host + device_id + ts → 9 层 md5
    static func webCaptchaSign(deviceId: String, timestamp: String) -> String {
        var hash = webClientId + webClientVersion + webSignHost + deviceId + timestamp
        for salt in webSalts {
            hash = YXCrypto.md5Hex(hash + salt)
        }
        return "1." + hash
    }
}

// MARK: - 设备指纹（生成一次、永久持久化）

private enum XLDevice {
    private static let idKey = "yunx.xunlei.deviceId"
    private static let peerKey = "yunx.xunlei.peerId"

    static let deviceId: String = loadOrCreate(idKey)
    static let peerId: String = loadOrCreate(peerKey)

    /// div101.{deviceId}{md5(sha1(deviceId + package + appid + appkey))}
    static let deviceSign: String = {
        let base = deviceId + XC.packageName + XC.appId + XC.appKey
        let digest = YXCrypto.md5Hex(YXCrypto.sha1Hex(base))
        return "div101." + deviceId + digest
    }()

    private static func loadOrCreate(_ key: String) -> String {
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        // 32 位 hex = randomHex(16)
        let value = YXCrypto.randomHex(16)
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}

// MARK: - Provider

final class XunleiProvider: PanProvider {
    let platform: SharePlatform = .xunlei

    /// pan 接口可用的 access_token。iOS 侧暂无登录链路，只在 Cookie 里存的是裸 token 时启用；
    /// 为空即游客态 —— 请求里**不写** Authorization 行。
    private var bearerToken: String = XunleiProvider.bearerFromStoredCookie()

    /// captcha_token 与过期时刻（网页 token 300s，过期后绝不复用，否则每次解析先撞一次 captcha_invalid）
    private var captchaToken: String = ""
    private var captchaExpiry: Date = .distantPast

    // MARK: 会话

    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        let passCode = (pwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = Self.shareURL(shareId: shareId, passCode: passCode, pageToken: "")
        let response = try await panJSON(url: url, action: "GET:/drive/v1/share")
        let data = Self.payload(response)
        try Self.checkShareStatus(data)

        let passCodeToken = data.yxString("pass_code_token") ?? ""
        let title = data.yxString("title") ?? ""
        let status = data.yxString("share_status") ?? ""

        var extra: [String: String] = [
            "pass_code": passCode,
            "pass_code_token": passCodeToken,
            "share_status": status
        ]
        // 分享者信息（服务端给了就带上，缺失不影响解析）
        if let sharerId = data.yxString("share_user.id") ?? data.yxString("user_id") {
            extra["sharer_id"] = sharerId
        }
        if let sharerName = data.yxString("share_user.nickname") ?? data.yxString("nickname") {
            extra["sharer"] = sharerName
        }
        if !title.isEmpty { extra["title"] = title }

        return ShareSession(platform: .xunlei,
                            shareId: shareId,
                            stoken: passCodeToken,
                            title: title.isEmpty ? "迅雷网盘分享" : title,
                            extra: extra)
    }

    // MARK: 列表

    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem] {
        let passCode = session.value("pass_code")
        let passCodeToken = session.stoken.isEmpty ? session.value("pass_code_token") : session.stoken
        let isRoot = dirFid.isEmpty || dirFid == "0"

        var items: [ShareFileItem] = []
        var seen = Set<String>()
        var pageToken = ""
        var pages = 0

        while pages < 100 {
            let url: String
            let action: String
            if isRoot {
                url = Self.shareURL(shareId: session.shareId, passCode: passCode, pageToken: pageToken)
                action = "GET:/drive/v1/share"
            } else {
                url = Self.shareDetailURL(shareId: session.shareId,
                                          parentId: dirFid,
                                          passCodeToken: passCodeToken,
                                          pageToken: pageToken)
                action = "GET:/drive/v1/share/detail"
            }

            let response = try await panJSON(url: url, action: action)
            let data = Self.payload(response)
            if isRoot { try Self.checkShareStatus(data) }

            var added = 0
            for item in Self.parseFiles(data, parentFid: dirFid, fidToken: passCodeToken) {
                if seen.contains(item.fid) { continue }
                seen.insert(item.fid)
                items.append(item)
                added += 1
            }

            let next = data.yxString("next_page_token") ?? ""
            pages += 1
            if added == 0 { break }
            if next.isEmpty || next == pageToken { break }
            pageToken = next
        }

        return items
    }

    // MARK: 取链

    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        if file.isDir {
            throw YXError.business("文件夹不能直接下载，请展开后选择文件")
        }

        let encodedFid = YXURLUtil.encode(file.fid)
        let url = XC.panBase + "/drive/v1/files/" + encodedFid
            + "?_magic=2021&usage=PLAY&thumbnail_size=SIZE_LARGE"
            + "&with=hdr10&with=subtitle_files&with=task&with=public_share_tag"

        let response = try await panJSON(url: url, action: "GET:/drive/v1/files/\(file.fid)")
        let data = Self.payload(response)

        // links["application/octet-stream"].url 是官方直链；缺失时退回 web_content_link
        let links = data.yxDict("links")
        let octet = links.yxDict("application/octet-stream")
        var link = octet.yxString("url") ?? ""
        if link.isEmpty { link = data.yxString("web_content_link") ?? "" }
        guard !link.isEmpty else {
            throw YXError.business("未获取到迅雷下载地址，该分享可能需要在迅雷网盘登录后才能取直链")
        }

        let declaredSize = data.yxInt64("size") ?? 0
        let filename = data.yxString("name") ?? file.name

        return ResolvedDownload(url: link,
                                filename: filename.isEmpty ? file.name : filename,
                                size: declaredSize > 0 ? declaredSize : file.size,
                                headers: [
                                    "User-Agent": XC.webUa,
                                    "Referer": "https://pan.xunlei.com/",
                                    "Accept": "*/*",
                                    "Accept-Encoding": "identity"
                                ],
                                platform: .xunlei,
                                isGuest: bearerToken.isEmpty)
    }

    // MARK: 账号

    func quota() async -> (used: Int64, total: Int64)? {
        guard !bearerToken.isEmpty else { return nil }
        do {
            let response = try await panJSON(url: XC.panBase + "/drive/v1/about",
                                            action: "GET:/drive/v1/about")
            // App 通道包在 data 里，网页通道 quota 在顶层 —— 两处都兜底
            let data = Self.payload(response)
            var quota = data.yxDict("quota")
            if quota.isEmpty { quota = response.yxDict("quota") }
            let used = quota.yxInt64("usage") ?? 0
            let total = quota.yxInt64("limit") ?? 0
            guard total > 0 else { return nil }
            return (used: used, total: total)
        } catch {
            return nil
        }
    }

    func nickname(cookie: String) async -> String? {
        // 迅雷昵称只出现在登录链路（v3/login / smslogin），游客态无从获取
        return nil
    }

    // MARK: - pan 请求

    /// 带验证码刷新重试的 pan 调用。
    /// attempt 0：当前 captcha（过期即现签）+ Authorization（仅有 token 时）；
    /// attempt 1：强制重签 captcha（对齐 Kotlin 的 captcha_invalid 重试一次）；
    /// attempt 2：游客降级，不带队头 —— 迅雷分享接口本身允许匿名，带失效 captcha 反而被拒。
    private func panJSON(url: String,
                         method: String = "GET",
                         body: Data? = nil,
                         action: String) async throws -> [String: Any] {
        var lastMessage = "迅雷接口请求失败"

        for attempt in 0..<3 {
            let useCaptcha = attempt < 2
            let forceSign = attempt == 1
            var captcha = ""
            if useCaptcha {
                captcha = await captchaTokenFor(action: action, forceRefresh: forceSign)
            }

            do {
                let response = try await PanTool.json(url: url,
                                                      method: method,
                                                      headers: panHeaders(captcha: captcha),
                                                      body: body,
                                                      injectCookies: false,
                                                      allowStatus: [200, 201, 204])

                let error = response.yxString("error") ?? ""
                if error.isEmpty { return response }

                lastMessage = Self.errorMessage(response)
                if error == "unauthenticated" || error == "captcha_invalid" {
                    // 游客链路：token 与 captcha 双双作废，下一轮重新现签（或直接匿名）
                    bearerToken = ""
                    invalidateCaptcha()
                    continue
                }
                throw YXError.business(lastMessage)
            } catch YXError.badStatus(let code, let text) {
                let hint = text ?? ""
                lastMessage = hint.isEmpty ? "HTTP \(code)" : "HTTP \(code)：\(hint)"
                if code == 401 || code == 403 {
                    bearerToken = ""
                    invalidateCaptcha()
                    continue
                }
                throw YXError.business(Self.friendlyMessage(code: code, raw: hint))
            } catch YXError.decoding(let message) {
                throw YXError.business("迅雷响应解析失败：\(message)")
            }
        }

        throw YXError.business(lastMessage)
    }

    /// pan 固定头：抓包确认无 x-signature。游客态整行不写 Authorization。
    private func panHeaders(captcha: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": XC.webUa,
            "X-Device-Id": XLDevice.deviceId,
            "X-Client-Version": XC.clientVersion,
            "Content-Type": "application/json",
            "Origin": "https://pan.xunlei.com",
            "Referer": "https://pan.xunlei.com/",
            "Accept": "application/json, text/plain, */*"
        ]
        if !bearerToken.isEmpty {
            headers["Authorization"] = "Bearer " + bearerToken
        }
        if !captcha.isEmpty {
            headers["X-Captcha-Token"] = captcha
        }
        return headers
    }

    // MARK: - captcha（游客态也要一条可用的 X-Captcha-Token）

    private func captchaTokenFor(action: String, forceRefresh: Bool) async -> String {
        if !forceRefresh, !captchaToken.isEmpty, captchaExpiry > Date() {
            return captchaToken
        }

        let result: (token: String, ttl: TimeInterval)
        if bearerToken.isEmpty {
            result = await initCaptchaApp(action: action)
        } else {
            result = await initCaptchaWeb(action: action)
        }

        guard !result.token.isEmpty else {
            invalidateCaptcha()
            return ""
        }
        captchaToken = result.token
        captchaExpiry = Date().addingTimeInterval(result.ttl)
        return result.token
    }

    private func invalidateCaptcha() {
        captchaToken = ""
        captchaExpiry = .distantPast
    }

    /// App 通道 captcha init（XunleiApi.initPanCaptcha）：meta 带 10 盐签名；游客 user_id 传空串，
    /// 服务端会给出降级 token —— GET 类分享接口仍可用，这正是匿名解析能走通的关键。
    private func initCaptchaApp(action: String) async -> (token: String, ttl: TimeInterval) {
        let timestamp = Self.timestampMs()
        let meta: [String: Any] = [
            "client_version": XC.clientVersion,
            "package_name": XC.packageName,
            "timestamp": timestamp,
            "captcha_sign": XC.appCaptchaSign(deviceId: XLDevice.deviceId, timestamp: timestamp),
            "user_id": ""
        ]
        let payload: [String: Any] = [
            "client_id": XC.appClientId,
            "action": action,
            "device_id": XLDevice.deviceId,
            "redirect_uri": "xlaccsdk01://xunlei.com/callback?state=harbor",
            "meta": meta,
            "captcha_token": captchaToken
        ]
        let headers: [String: String] = [
            "User-Agent": XC.appUa,
            "Accept": "application/json;charset=UTF-8",
            "Content-Type": "application/json",
            "X-Client-Id": XC.appClientId,
            "X-Device-Id": XLDevice.deviceId,
            "X-Client-Version": XC.clientVersion
        ]
        return await requestCaptchaToken(payload: payload,
                                         headers: headers,
                                         fallbackTtl: XC.appCaptchaTtl)
    }

    /// 网页通道 captcha init（XunleiApi.initWebCaptcha）：9 盐签名 + 桌面 UA + Origin/Referer。
    /// 用 App 签名去换网页 token 会被判 `client_id not match`，两套盐绝不能串。
    private func initCaptchaWeb(action: String) async -> (token: String, ttl: TimeInterval) {
        let timestamp = Self.timestampMs()
        let meta: [String: Any] = [
            "username": "",
            "phone_number": "",
            "email": "",
            "package_name": XC.webPackageName,
            "client_version": XC.webClientVersion,
            "captcha_sign": XC.webCaptchaSign(deviceId: XLDevice.deviceId, timestamp: timestamp),
            "timestamp": timestamp,
            "user_id": ""
        ]
        let payload: [String: Any] = [
            "client_id": XC.webClientId,
            "action": action,
            "device_id": XLDevice.deviceId,
            "meta": meta
        ]
        let headers: [String: String] = [
            "Accept": "*/*",
            "Content-Type": "text/plain;charset=UTF-8",
            "Origin": "https://pan.xunlei.com",
            "Referer": "https://pan.xunlei.com/",
            "User-Agent": YXUA.chromeDesktop
        ]
        return await requestCaptchaToken(payload: payload,
                                         headers: headers,
                                         fallbackTtl: XC.webCaptchaTtl)
    }

    private func requestCaptchaToken(payload: [String: Any],
                                     headers: [String: String],
                                     fallbackTtl: TimeInterval) async -> (token: String, ttl: TimeInterval) {
        do {
            let response = try await PanTool.json(url: XC.authBase + "/v1/shield/captcha/init",
                                                  method: "POST",
                                                  headers: headers,
                                                  body: PanTool.jsonBody(payload),
                                                  injectCookies: false,
                                                  allowStatus: [200, 201, 400, 401, 403, 429])
            let token = response.yxString("captcha_token") ?? ""
            let expires = TimeInterval(response.yxInt("expires_in") ?? 0)
            return (token: token, ttl: expires > 0 ? expires : fallbackTtl)
        } catch {
            // 盾接口偶发 4xx/非 JSON：拿不到 token 就按游客无队头继续，不阻断分享解析
            return (token: "", ttl: 0)
        }
    }

    // MARK: - URL

    private static func shareURL(shareId: String, passCode: String, pageToken: String) -> String {
        let pairs: [(String, String)] = [
            ("share_id", shareId),
            ("pass_code", passCode),
            ("limit", "100"),
            ("page_token", pageToken),
            ("thumbnail_size", "SIZE_SMALL")
        ]
        return XC.panBase + "/drive/v1/share?" + YXURLUtil.query(pairs)
    }

    private static func shareDetailURL(shareId: String,
                                       parentId: String,
                                       passCodeToken: String,
                                       pageToken: String) -> String {
        let pairs: [(String, String)] = [
            ("share_id", shareId),
            ("parent_id", parentId),
            ("pass_code_token", passCodeToken),
            ("limit", "100"),
            ("page_token", pageToken),
            ("thumbnail_size", "SIZE_SMALL")
        ]
        return XC.panBase + "/drive/v1/share/detail?" + YXURLUtil.query(pairs)
    }

    // MARK: - 解析

    /// App 通道把结果包在 data 里，网页通道是顶层 —— 统一取最内层
    private static func payload(_ response: [String: Any]) -> [String: Any] {
        let data = response.yxDict("data")
        return data.isEmpty ? response : data
    }

    /// 分享提取码状态：这三种情况 HTTP 200 但 files 是空数组，必须显式判掉
    private static func checkShareStatus(_ data: [String: Any]) throws {
        switch data.yxString("share_status") ?? "" {
        case "PASS_CODE_EMPTY":
            throw YXError.business("请输入提取码")
        case "PASS_CODE_ERROR":
            throw YXError.business("提取码错误")
        case "PASS_CODE_NEED":
            throw YXError.business("该分享需要提取码")
        default:
            break
        }
    }

    private static func parseFiles(_ data: [String: Any],
                                   parentFid: String,
                                   fidToken: String) -> [ShareFileItem] {
        var items: [ShareFileItem] = []
        for row in data.yxArray("files") {
            let fid = row.yxString("id") ?? ""
            if fid.isEmpty { continue }
            let kind = row.yxString("kind") ?? ""
            let name = row.yxString("name") ?? ""
            items.append(ShareFileItem(fid: fid,
                                       name: name.isEmpty ? "未命名" : name,
                                       size: row.yxInt64("size") ?? 0,
                                       isDir: kind == "drive#folder",
                                       parentFid: row.yxString("parent_id") ?? parentFid,
                                       fidToken: fidToken,
                                       modifyTime: row.yxString("modified_time") ?? ""))
        }
        return items
    }

    // MARK: - 杂项

    private static func timestampMs() -> String {
        String(Int64((Date().timeIntervalSince1970 * 1000).rounded()))
    }

    private static func errorMessage(_ response: [String: Any]) -> String {
        let candidates: [String?] = [
            response.yxString("error_description"),
            response.yxString("message"),
            response.yxString("error")
        ]
        for candidate in candidates {
            if let text = candidate, !text.isEmpty { return text }
        }
        return "迅雷接口返回错误"
    }

    private static func friendlyMessage(code: Int, raw: String) -> String {
        if raw.contains("client_id not match") { return "验证码与当前登录方式不匹配，请重新登录迅雷网页版" }
        if raw.contains("captcha") { return "迅雷验证码校验失败，请稍后重试" }
        if raw.isEmpty { return "迅雷接口请求失败（HTTP \(code)）" }
        return "迅雷接口请求失败（HTTP \(code)）：\(raw)"
    }

    /// 只在 Cookie 存的是「裸 access_token」时启用登录态；存的是 cookie 串（含 ; 或 =）时一律按游客走
    private static func bearerFromStoredCookie() -> String {
        let raw = PanTool.cookie(.xunlei).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "" }
        var text = raw
        if text.lowercased().hasPrefix("bearer ") {
            text = String(text.dropFirst("bearer ".count))
        }
        text = text.trimmingCharacters(in: .whitespaces)
        // JWT 形态：a.b.c，长度足够，且不含 cookie 分隔符
        if text.contains(";") || text.contains("=") || text.count < 16 || !text.contains(".") {
            return ""
        }
        return text
    }
}
