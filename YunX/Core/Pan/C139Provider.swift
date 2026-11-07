//
//  C139Provider.swift
//  YunX · 139 网盘（中国移动·和彩云）分享解析
//
//  协议真源：desktop 版 C139Api.kt / C139Constants.kt / C139ResolveRepository.kt。
//  只走「分享通道」share-kd-njs.yun.139.com：
//    - 请求体 AES-128-CBC（全账号固定 KEY，IV 16B 随机前置）→ base64 作为 body
//    - 匿名：不带 Authorization、不带 Cookie、不带 mcloud-* （getOutLinkInfoV6/getOutLinkGeneral）
//    - 取直链 dlFromOutLinkV3 额外带 mcloud-sign（按明文 body 计算）与（可选）Authorization
//    - 响应体可能是「加密 base64」也可能是明文 JSON，两种都要兼容
//  个人盘只做 quota（personal/user host，明文 JSON + Authorization + mcloud-sign）。
//

import Foundation

final class C139Provider: PanProvider {
    let platform: SharePlatform = .c139

    // MARK: - 常量（对齐 C139Constants.kt）

    /// 分享专用 host：share-kd-njs.yun.139.com
    /// 列目录（7.13+ 请求/响应加密）
    private static let listURL = "https://share-kd-njs.yun.139.com"
        + "/yun-share/richlifeApp/devapp/IOutLink/getOutLinkInfoV6"
    /// 取直链
    private static let linkURL = "https://share-kd-njs.yun.139.com"
        + "/yun-share/richlifeApp/devapp/IOutLink/dlFromOutLinkV3"
    /// 分享标题 / 明文提取码回吐
    private static let generalURL = "https://share-kd-njs.yun.139.com"
        + "/yun-share/richlifeApp/devapp/IOutLink/getOutLinkGeneral"
    /// 个人盘空间详情（quota 用）
    private static let quotaURL = "https://user-njs.yun.139.com/user/disk/quota/detail"

    /// §14：分享接口 AES-CBC 固定密钥（16 字节，全账号共用）
    private static let shareAESKey = Data("PVGDwmcvfs1uV3d1".utf8)

    /// 分享接口必带的设备/渠道头（缺任一 → 9530 或空数据）
    private static let shareDeviceInfo = "||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||"
    private static let shareChannelSrc = "10245500"
    private static let shareMmSource = "0002"

    /// 分享接口 UA（必须浏览器 UA，不能用 okhttp/URLSession 默认串）
    private static let mobileUA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"

    /// 个人盘通道（quota）PC 侧上下文
    private static let pcUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private static let cloudChannelSource = "10000034"
    private static let cloudDeviceInfo = "||9|7.17.9|chrome|116.0.0.0|2cdaf7ada9e353c70eba99092e177991||windows 10||zh-CN|||"
    private static let cloudClientInfo = "||9|7.17.9|chrome|116.0.0.0|2cdaf7ada9e353c70eba99092e177991||windows 10||zh-CN|||dW5kZWZpbmVk||"

    private static let pageSize = 200
    private static let maxFetched = 20_000

    // MARK: - 会话

    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        let linkId = shareId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !linkId.isEmpty else { throw YXError.business("139 分享链接无效：缺少 linkID") }

        let cookie = PanTool.cookie(.c139)
        var passwd = (pwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var title = ""

        // getOutLinkGeneral：一次拿标题 + 服务端明文回吐的提取码（失败不阻断，可能是提取码保护分享）
        if let general = try? await generalInfo(linkId: linkId) {
            if passwd.isEmpty, let leaked = general.passwd, !leaked.isEmpty {
                passwd = leaked
            }
            if let name = general.title, !name.isEmpty {
                title = name
            }
        }
        if title.isEmpty { title = linkId }

        var extra: [String: String] = ["linkID": linkId, "pwd": passwd]
        if let account = Self.accountFull(cookie), !account.isEmpty {
            extra["account"] = account
        }
        let session = ShareSession(platform: .c139,
                                   shareId: linkId,
                                   stoken: passwd,
                                   title: title,
                                   extra: extra)

        // 立刻列一页：提取码错误（9188）/ 分享失效能第一时间抛出
        _ = try await listFiles(session: session, dirFid: "0")
        return session
    }

    // MARK: - 列表

    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem] {
        // 根目录 pCaID 必须是字符串 "root"，不能空串（空串报「pCaID不能为空」）
        let pcaId = (dirFid == "0" || dirFid.isEmpty) ? "root" : dirFid
        let extraPwd = session.value("pwd")
        let passwd = extraPwd.isEmpty ? session.stoken : extraPwd

        var all: [ShareFileItem] = []
        var seen = Set<String>()
        var begin = 1
        while begin <= Self.maxFetched {
            let batch = try await fetchPage(session: session,
                                            pcaId: pcaId,
                                            passwd: passwd,
                                            begin: begin,
                                            end: begin + Self.pageSize - 1)
            for item in batch where !item.fid.isEmpty && !seen.contains(item.fid) {
                seen.insert(item.fid)
                all.append(item)
            }
            if batch.count < Self.pageSize { break }
            begin += Self.pageSize
        }
        return all
    }

    private func fetchPage(session: ShareSession,
                           pcaId: String,
                           passwd: String,
                           begin: Int,
                           end: Int) async throws -> [ShareFileItem] {
        // body 字段一个都不能少（少字段 → 9530）；列表 account 必须空串
        let req: [String: Any] = [
            "getOutLinkInfoReq": [
                "account": "",
                "linkID": session.shareId,
                "passwd": passwd,
                "caSrt": 1,
                "coSrt": 1,
                "srtDr": 0,
                "bNum": begin,
                "pCaID": pcaId,
                "eNum": end
            ]
        ]
        let plain = try Self.jsonString(req)
        let json = try await sharePost(url: Self.listURL,
                                       plainBody: plain,
                                       withSign: false,
                                       authorization: nil)
        try Self.ensureShareSuccess(json, fallback: "获取 139 分享文件列表失败")

        let data = json.yxDict("data")
        var items: [ShareFileItem] = []

        // 1) caLst：子文件夹（只读 coLst 会表现为「顶层全是文件夹时显示为空」）
        for row in data.yxArray("caLst") {
            guard let caId = row.yxString("caID"), !caId.isEmpty else { continue }
            let name = row.yxString("caName") ?? ""
            let modify = Self.modifyTime(row)
            items.append(ShareFileItem(fid: caId,
                                       name: name.isEmpty ? "未命名文件夹" : name,
                                       size: 0,
                                       isDir: true,
                                       parentFid: pcaId,
                                       fidToken: "",
                                       modifyTime: modify))
        }

        // 2) coLst：文件 + coType == 2 的文件夹
        for row in data.yxArray("coLst") {
            guard let coId = row.yxString("coID"), !coId.isEmpty else { continue }
            let name = row.yxString("coName") ?? ""
            let isDir = row.yxBool("isdir") ?? ((row.yxInt("coType") ?? 1) == 2)
            items.append(ShareFileItem(fid: coId,
                                       name: name.isEmpty ? "未命名文件" : name,
                                       size: isDir ? 0 : (row.yxInt64("coSize") ?? 0),
                                       isDir: isDir,
                                       parentFid: pcaId,
                                       fidToken: "",
                                       modifyTime: Self.modifyTime(row)))
        }
        return items
    }

    private static func modifyTime(_ row: [String: Any]) -> String {
        if let ud = row.yxString("udTime"), !ud.isEmpty { return ud }
        return row.yxString("ctTime") ?? ""
    }

    // MARK: - 取直链

    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        guard !file.isDir else { throw YXError.business("139 分享的文件夹不支持直接下载") }
        guard !file.fid.isEmpty else { throw YXError.business("文件缺少 coID，无法取直链") }

        let cookie = PanTool.cookie(.c139)
        // 取直链 account 必须是完整手机号：Cookie → ORCHES-I-ACCOUNT-ENCRYPT → authorization → Login_UserNumber
        var account = Self.accountFull(cookie) ?? ""
        if account.isEmpty { account = session.value("account") }
        let authorization = Self.authorization(from: cookie)

        let body: [String: Any] = [
            "dlFromOutLinkReqV3": [
                "account": account,
                "linkID": session.shareId,
                "coIDLst": ["item": [file.fid]],
                "commonAccountInfo": ["account": account, "accountType": 1]
            ]
        ]
        let plain = try Self.jsonString(body)
        let json = try await sharePost(url: Self.linkURL,
                                       plainBody: plain,
                                       withSign: true,
                                       authorization: authorization)
        try Self.ensureShareSuccess(json, fallback: "获取 139 下载直链失败")

        guard let url = json.yxString("data.redrUrl"),
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if account.isEmpty {
                throw YXError.business("139 取直链需要完整手机号账号：请先登录 139 网盘后重试")
            }
            throw YXError.business("139 未返回下载直链（分享可能已失效或需要提取码）")
        }

        let name = file.name.isEmpty
            ? (json.yxString("data.fileName") ?? json.yxString("data.coName") ?? file.fid)
            : file.name
        let size = file.size > 0
            ? file.size
            : (json.yxInt64("data.coSize") ?? json.yxInt64("data.size") ?? 0)

        return ResolvedDownload(url: url,
                                filename: name,
                                size: size,
                                headers: [
                                    "User-Agent": Self.mobileUA,
                                    "Referer": "https://yun.139.com",
                                    "Accept": "*/*"
                                ],
                                platform: .c139,
                                isGuest: account.isEmpty)
    }

    // MARK: - 空间（个人盘，可选）

    func quota() async -> (used: Int64, total: Int64)? {
        let cookie = PanTool.cookie(.c139)
        guard let authorization = Self.authorization(from: cookie),
              let account = Self.accountFull(cookie),
              !account.isEmpty else { return nil }

        let body: [String: Any] = [
            "userDomainId": "",
            "commonAccountInfo": ["account": account, "accountType": 1]
        ]
        guard let plain = try? Self.jsonString(body),
              let bodyData = plain.data(using: .utf8) else { return nil }

        var headers = Self.cloudHeaders(authorization: authorization, plainBody: plain)
        if let skey = Self.skey(from: cookie) { headers["mcloud-skey"] = skey }
        if !cookie.isEmpty { headers["Cookie"] = cookie }

        do {
            let json = try await PanTool.json(url: Self.quotaURL,
                                              method: "POST",
                                              headers: headers,
                                              body: bodyData,
                                              injectCookies: false)
            let code = json.yxString("code") ?? ""
            let success = json.yxBool("success") ?? true
            guard success, code.isEmpty || code == "0" || code == "0000" else { return nil }
            guard let totalMB = json.yxInt64("data.diskSize"), totalMB > 0 else { return nil }
            let total = totalMB * 1024 * 1024
            let used: Int64
            if let usedMB = json.yxInt64("data.quotaList.0.usedSize") {
                used = usedMB * 1024 * 1024
            } else if let freeMB = json.yxInt64("data.freeDiskSize") {
                used = total - freeMB * 1024 * 1024
            } else {
                return nil
            }
            return (used: max(0, used), total: total)
        } catch {
            return nil
        }
    }

    // MARK: - 昵称 / Cookie 校验

    func nickname(cookie: String) async -> String? {
        let raw = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let pairs = Self.cookiePairs(raw)

        // 有效登录态：authorization 非空，或 Os_SSo_Sid + RMKEY 同时存在
        let hasAuth = !(pairs["authorization"] ?? "").isEmpty
        let hasFastLogin = !(pairs["Os_SSo_Sid"] ?? "").isEmpty && !(pairs["RMKEY"] ?? "").isEmpty
        guard hasAuth || hasFastLogin else { return nil }

        // 优先脱敏手机号 → base64 手机号 → Login_UserNumber → authorization 里的账号
        if let simplify = pairs["ORCHES-I-ACCOUNT-SIMPLIFY"], !simplify.isEmpty { return simplify }
        if let encrypt = pairs["ORCHES-I-ACCOUNT-ENCRYPT"], !encrypt.isEmpty {
            if let data = YXBase64.decode(encrypt),
               let decoded = String(data: data, encoding: .utf8),
               !decoded.isEmpty {
                return decoded
            }
            return encrypt
        }
        if let login = pairs["Login_UserNumber"], !login.isEmpty { return login }
        return Self.accountFull(raw)
    }

    // MARK: - getOutLinkGeneral（标题 + 明文提取码）

    private struct GeneralInfo {
        let title: String?
        let passwd: String?
    }

    private func generalInfo(linkId: String) async throws -> GeneralInfo? {
        let body: [String: Any] = [
            "getOutLinkGeneralReq": [
                "linkID": linkId,
                "isPasswd": 1,
                "account": ""
            ]
        ]
        let plain = try Self.jsonString(body)
        let json = try await sharePost(url: Self.generalURL,
                                       plainBody: plain,
                                       withSign: false,
                                       authorization: nil)
        guard Self.isShareSuccess(json) else { return nil }
        guard let first = json.yxArray("data.getOutLinkGeneralResp.outLinkGeneral").first else {
            return nil
        }
        return GeneralInfo(title: first.yxString("lkName"), passwd: first.yxString("passwd"))
    }

    // MARK: - 分享通道 POST（AES 加密 body + 设备头）

    private func sharePost(url: String,
                           plainBody: String,
                           withSign: Bool,
                           authorization: String?) async throws -> [String: Any] {
        guard let encrypted = Self.encryptBody(plainBody),
              let bodyData = encrypted.data(using: .utf8) else {
            throw YXError.business("139 分享请求体加密失败")
        }

        var headers: [String: String] = [
            "hcy-cool-flag": "1",
            "x-deviceinfo": Self.shareDeviceInfo,
            "x-huawei-channelsrc": Self.shareChannelSrc,
            "x-mm-source": Self.shareMmSource,
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": Self.mobileUA,
            "Origin": "https://yun.139.com",
            "Referer": "https://yun.139.com/",
            "Accept": "application/json, text/plain, */*"
        ]
        if withSign { headers["mcloud-sign"] = Self.signHeader(plainBody) }
        if let authorization, !authorization.isEmpty {
            headers["Authorization"] = authorization
        }

        var req = HTTPRequest(url: url, method: "POST")
        req.headers = headers
        req.body = bodyData
        // 分享通道匿名：绝不注入 Cookie
        req.injectCookies = false
        req.timeout = 30

        let res = try await HTTPClient.shared.send(req)
        if let json = Self.parseSharePayload(res.data) { return json }
        let snippet = String(res.text.prefix(200))
        throw YXError.badStatus(res.status, snippet.isEmpty ? nil : snippet)
    }

    // MARK: - AES-CBC 封装

    /// 明文 JSON → base64( IV(16B) ‖ AES-128-CBC-PKCS7(KEY, IV, 明文) )
    private static func encryptBody(_ plaintext: String) -> String? {
        let iv = randomIV()
        guard let cipher = YXCrypto.aesCBC(key: shareAESKey,
                                           iv: iv,
                                           data: Data(plaintext.utf8),
                                           encrypt: true) else { return nil }
        return (iv + cipher).base64EncodedString()
    }

    /// 取前 16B 作 IV，其余解密；解出首 2B 为 1f 8b 时先 gunzip
    private static func decryptBody(_ raw: Data) -> String? {
        guard raw.count > 16 else { return nil }
        let iv = Data(raw.prefix(16))
        let cipher = Data(raw.dropFirst(16))
        guard !cipher.isEmpty,
              let plain = YXCrypto.aesCBC(key: shareAESKey, iv: iv, data: cipher, encrypt: false) else {
            return nil
        }
        if plain.count > 2,
           plain[plain.startIndex] == 0x1F,
           plain[plain.startIndex + 1] == 0x8B {
            guard let unzipped = YXCrypto.gunzip(plain) else { return nil }
            return String(data: unzipped, encoding: .utf8)
        }
        return String(data: plain, encoding: .utf8)
    }

    /// 响应可能是加密 base64，也可能是网关透传的明文 JSON —— 两种都兼容
    private static func parseSharePayload(_ data: Data) -> [String: Any]? {
        if !data.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let raw = YXBase64.decode(trimmed),
              let plain = decryptBody(raw),
              let plainData = plain.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: plainData) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func randomIV() -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: 0...255, using: &generator))
        }
        return Data(bytes)
    }

    // MARK: - mcloud-sign（§4：按明文 body 计算）

    private static func signHeader(_ plainBody: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ts = formatter.string(from: Date())
        let rand = YXCrypto.randomAlphaNumeric(16)
        return "\(ts),\(rand),\(calSign(plainBody, ts: ts, rand: rand))"
    }

    /// body' 单字符 ASCII 升序 → base64 → md5(base64) + md5(ts:rand) → md5 → upper
    private static func calSign(_ bodyJSON: String, ts: String, rand: String) -> String {
        var bytes = Array(YXURLUtil.encodeURIComponent(bodyJSON).utf8)
        bytes.sort()
        let sorted = String(decoding: bytes, as: UTF8.self)
        let base64 = YXBase64.encode(Data(sorted.utf8))
        let merged = YXCrypto.md5Hex(base64) + YXCrypto.md5Hex("\(ts):\(rand)")
        return YXCrypto.md5Hex(merged).uppercased()
    }

    // MARK: - 个人盘通道头（quota）

    private static func cloudHeaders(authorization: String, plainBody: String) -> [String: String] {
        [
            "Authorization": authorization,
            "mcloud-sign": signHeader(plainBody),
            "x-yun-channel-source": cloudChannelSource,
            "x-yun-app-channel": cloudChannelSource,
            "x-huawei-channelSrc": cloudChannelSource,
            "mcloud-version": "7.17.9",
            "mcloud-client": "10701",
            "mcloud-channel": "1000101",
            "mcloud-route": "001",
            "x-yun-module-type": "100",
            "x-yun-api-version": "v1",
            "x-yun-svc-type": "1",
            "x-SvcType": "1",
            "caller": "web",
            "x-inner-ntwk": "2",
            "CMS-DEVICE": "default",
            "x-m4c-src": "10002",
            "x-m4c-caller": "PC",
            "X-Deviceinfo": cloudDeviceInfo,
            "x-yun-client-info": cloudClientInfo,
            "INNER-HCY-ROUTER-HTTPS": "1",
            "Sec-Fetch-Site": "same-site",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
            "X-Requested-With": "mark.via",
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": pcUA,
            "Origin": "https://yun.139.com",
            "Referer": "https://yun.139.com/",
            "Accept": "application/json, text/plain, */*"
        ]
    }

    // MARK: - 结果判定

    private static func isShareSuccess(_ json: [String: Any]) -> Bool {
        let code = json.yxString("resultCode") ?? ""
        let success = json.yxBool("success") ?? true
        return success && (code.isEmpty || code == "0")
    }

    private static func ensureShareSuccess(_ json: [String: Any], fallback: String) throws {
        if isShareSuccess(json) { return }
        let code = json.yxString("resultCode") ?? ""
        if code == "9188" {
            throw YXError.business("139 提取码错误或分享已失效（9188）")
        }
        if code == "9530" {
            throw YXError.business("139 分享接口校验失败（9530），请稍后重试")
        }
        let desc = json.yxString("desc") ?? ""
        if !desc.isEmpty { throw YXError.business(desc) }
        let message = json.yxString("message") ?? ""
        if !message.isEmpty { throw YXError.business(message) }
        throw YXError.business(code.isEmpty ? fallback : "\(fallback)（\(code)）")
    }

    // MARK: - JSON / Cookie 小工具

    private static func jsonString(_ dict: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(dict) else {
            throw YXError.decoding("139 请求体包含无法序列化的类型")
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw YXError.decoding("139 请求体编码失败")
        }
        return text
    }

    /// "a=b; c=d" → ["a": "b", "c": "d"]（值里允许出现 "="）
    private static func cookiePairs(_ cookie: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in cookie.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = kv.first else { continue }
            let name = String(key).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let value = kv.count > 1 ? String(kv[1]).trimmingCharacters(in: .whitespaces) : ""
            if out[name] == nil { out[name] = value }
        }
        return out
    }

    /// 完整账号（解析/取直链必须完整手机号）：ORCHES-I-ACCOUNT-ENCRYPT → authorization → Login_UserNumber
    private static func accountFull(_ cookie: String) -> String? {
        guard !cookie.isEmpty else { return nil }
        let pairs = cookiePairs(cookie)
        if let encrypt = pairs["ORCHES-I-ACCOUNT-ENCRYPT"], !encrypt.isEmpty {
            if let data = YXBase64.decode(encrypt),
               let decoded = String(data: data, encoding: .utf8),
               !decoded.isEmpty {
                return decoded
            }
        }
        if let auth = pairs["authorization"], !auth.isEmpty,
           let account = accountFromAuthorization(auth) {
            return account
        }
        if let login = pairs["Login_UserNumber"], !login.isEmpty { return login }
        return nil
    }

    /// "Basic base64(pc:账号:authToken)" → 账号
    private static func accountFromAuthorization(_ authorization: String) -> String? {
        var text = authorization.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("basic") {
            text = String(text.dropFirst("basic".count)).trimmingCharacters(in: .whitespaces)
        }
        guard let data = YXBase64.decode(text),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        let parts = decoded.components(separatedBy: ":")
        guard parts.count > 1 else { return nil }
        let account = parts[1].trimmingCharacters(in: .whitespaces)
        return account.isEmpty ? nil : account
    }

    private static func authorization(from cookie: String) -> String? {
        guard !cookie.isEmpty else { return nil }
        let value = cookiePairs(cookie)["authorization"] ?? ""
        return value.isEmpty ? nil : value
    }

    private static func skey(from cookie: String) -> String? {
        guard !cookie.isEmpty else { return nil }
        let value = cookiePairs(cookie)["skey"] ?? ""
        return value.isEmpty ? nil : value
    }
}
