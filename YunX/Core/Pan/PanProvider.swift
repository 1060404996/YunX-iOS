//
//  PanProvider.swift
//  YunX · 网盘平台统一抽象
//
//  夸克/UC 走 PanClient（同构客户端）；其余平台各自实现本协议，
//  ResolveService 只做分发，UI 层完全不感知平台差异。
//

import Foundation

/// 解析会话：不同平台需要的凭证字段不同，统一塞进 extra
struct ShareSession: Equatable {
    let platform: SharePlatform
    let shareId: String
    /// 夸克/UC 的 stoken；其他平台为空串
    var stoken: String
    var title: String
    /// 平台私有字段（115 的 receiveCode/userId、蓝奏的 host/fileId、139 的 linkID/passwd 等）
    var extra: [String: String] = [:]

    func value(_ key: String) -> String { extra[key] ?? "" }
}

/// 分享内的一个文件/文件夹条目。
/// `fid` 是平台内唯一 id（115 用 cid、百度用 fs_id、蓝奏带 d:/f: 前缀）；
/// `fidToken` 是取链所需的平台令牌（夸克 share_fid_token、115 pickcode、123 的 S3KeyFlag|Etag|Node）。
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

/// 一条可下载的直链（含下载必需请求头）
struct ResolvedDownload {
    var url: String
    var filename: String
    var size: Int64
    var headers: [String: String]
    var platform: SharePlatform
    var isGuest: Bool
    /// 需要跟随的跳转（如 123 的 auto_redirect 中间页）
    var followupURL: String? = nil
    /// 下载成功后需清理的云端临时目录
    var cleanupDirFid: String? = nil
}

protocol PanProvider: AnyObject {
    var platform: SharePlatform { get }

    /// 建立解析会话（换 token / 校验提取码）
    func createSession(shareId: String, pwd: String?) async throws -> ShareSession

    /// 列目录（dirFid = "0" 或平台根标识）
    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem]

    /// 取直链
    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload

    /// 容量（可选）
    func quota() async -> (used: Int64, total: Int64)?

    /// 校验 Cookie 是否有效，返回昵称
    func nickname(cookie: String) async -> String?
}

extension PanProvider {
    func quota() async -> (used: Int64, total: Int64)? { nil }
    func nickname(cookie: String) async -> String? { nil }
}

// MARK: - 注册中心

enum PanProviders {
    static func provider(for platform: SharePlatform) -> PanProvider? {
        switch platform {
        case .quark:   return QuarkProvider()
        case .uc:      return UCProvider()
        case .pan123:  return Pan123Provider()
        case .baidu:   return BaiduProvider()
        case .lanzou:  return LanzouProvider()
        case .ilanzou: return ILanzouProvider()
        case .pan115:  return Pan115Provider()
        case .c139:    return C139Provider()
        case .guangya: return GuangYaProvider()
        case .xunlei:  return XunleiProvider()
        case .github:  return GitHubProvider()
        }
    }

    /// 该平台是否已具备可用实现
    static func isSupported(_ platform: SharePlatform) -> Bool {
        provider(for: platform) != nil
    }
}

// MARK: - 公共辅助

enum PanTool {
    /// 平台 Cookie（Keychain）
    static func cookie(_ platform: SharePlatform) -> String {
        CookieStore.shared.cookie(for: platform) ?? ""
    }

    static func setCookie(_ value: String, _ platform: SharePlatform) {
        CookieStore.shared.setCookie(value, for: platform)
    }

    /// 各平台登录态判定规则不同，不能统一用夸克/UC 的 __puus 规则
    static func hasCredential(_ platform: SharePlatform) -> Bool {
        let value = cookie(platform)
        guard !value.isEmpty else { return false }
        switch platform {
        case .quark, .uc:
            return PanUtil.isValidCookie(value)
        case .baidu:
            return value.contains("BDUSS=")
        case .pan115:
            return value.contains("UID=") || value.contains("SEID=")
        case .lanzou:
            return value.contains("phpdisk_info=")
        case .ilanzou:
            return value.count > 16
        case .xunlei, .guangya, .c139:
            // Token 型凭证，非 Cookie 结构
            return value.count > 16
        case .pan123, .github:
            return value.count > 8
        }
    }

    /// 统一 JSON 请求
    static func json(url: String,
                     method: String = "GET",
                     headers: [String: String] = [:],
                     body: Data? = nil,
                     injectCookies: Bool = false,
                     allowStatus: Set<Int> = [200]) async throws -> [String: Any] {
        var req = HTTPRequest(url: url, method: method)
        req.headers = headers
        req.body = body
        req.injectCookies = injectCookies
        return try await HTTPClient.shared.json(req, allowStatus: allowStatus)
    }

    static func text(url: String,
                     method: String = "GET",
                     headers: [String: String] = [:],
                     body: Data? = nil,
                     injectCookies: Bool = false,
                     allowStatus: Set<Int> = [200]) async throws -> String {
        var req = HTTPRequest(url: url, method: method)
        req.headers = headers
        req.body = body
        req.injectCookies = injectCookies
        let res = try await HTTPClient.shared.send(req)
        guard allowStatus.contains(res.status) else {
            throw YXError.badStatus(res.status, nil)
        }
        return res.text
    }

    static func jsonBody(_ dict: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: dict)
    }
}
