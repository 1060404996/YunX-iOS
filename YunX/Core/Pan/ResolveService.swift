//
//  ResolveService.swift
//  YunX · 解析编排 + 下载请求头组装
//
//  一次完整链路：分享链接 → session(stoken) → 文件列表 → 取下载直链 → 组 headers 入队。
//  登录态优先「免转存」直取；失败回退「转存到临时目录 → 轮询任务 → 用新 fid 取链」。
//  无登录态时走游客取链（夸克约 50MB 上限）。
//

import Foundation

/// 一条可下载的直链（含下载所需的全部请求头）
struct ResolvedDownload {
    var url: String
    var filename: String
    var size: Int64
    var headers: [String: String]
    var platform: SharePlatform
    var isGuest: Bool
    /// 下载成功后需清理的云端临时目录
    var cleanupDirFid: String?
}

enum ResolveService {

    /// 下载请求头：直链签名绑死「取链那一刻的那份 Cookie」
    static func downloadHeaders(platform: SharePlatform, link: PanDownloadLink) -> [String: String] {
        guard let cfg = PanConfigs.config(for: platform) else { return [:] }
        var headers: [String: String] = [
            "User-Agent": cfg.userAgent,
            "Referer": cfg.referer,
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
        if !link.guestCookie.isEmpty {
            headers["Cookie"] = link.guestCookie
            if let guestUA = cfg.guestUA { headers["User-Agent"] = guestUA }
            if let secCh = cfg.guestSecChUa { headers["Sec-Ch-Ua"] = secCh }
        } else {
            let cookie = CookieStore.shared.cookie(for: platform) ?? ""
            if !cookie.isEmpty { headers["Cookie"] = cookie }
        }
        if platform == .uc {
            headers["Origin"] = cfg.webOrigin
        }
        return headers
    }

    /// 建会话
    static func createSession(platform: SharePlatform, shareId: String, pwd: String?) async throws -> ShareSession {
        let client = PanClient(platform: platform)
        let cookie = CookieStore.shared.cookie(for: platform) ?? ""
        let token = try await client.shareToken(shareId: shareId, pwd: pwd, cookie: cookie)
        return ShareSession(platform: platform,
                            shareId: shareId,
                            stoken: token.stoken,
                            title: token.title)
    }

    /// 列目录
    static func listFiles(session: ShareSession, dirFid: String = "0") async throws -> [ShareFileItem] {
        let client = PanClient(platform: session.platform)
        return try await client.shareFilesAll(session: session, dirFid: dirFid)
    }

    /// 取直链（登录免转存 → 转存兜底 → 游客）
    static func resolveDownload(session: ShareSession,
                                file: ShareFileItem,
                                preferNoSave: Bool = true) async throws -> ResolvedDownload {
        let platform = session.platform
        let client = PanClient(platform: platform)
        let cookie = CookieStore.shared.cookie(for: platform) ?? ""
        let loggedIn = PanUtil.isValidCookie(cookie)

        var link: PanDownloadLink
        var cleanupDirFid: String? = nil

        if loggedIn {
            if preferNoSave {
                do {
                    link = try await client.downloadLinkWithoutSave(session: session, file: file, cookie: cookie)
                } catch {
                    link = try await transferThenDownload(client: client,
                                                          session: session,
                                                          file: file,
                                                          cookie: cookie,
                                                          cleanup: &cleanupDirFid)
                }
            } else {
                link = try await transferThenDownload(client: client,
                                                      session: session,
                                                      file: file,
                                                      cookie: cookie,
                                                      cleanup: &cleanupDirFid)
            }
        } else {
            guard platform == .quark || platform == .uc else {
                throw YXError.business("下载需要先登录 \(platform.displayName)")
            }
            link = try await client.guestDownloadLink(session: session, file: file)
        }

        let headers = downloadHeaders(platform: platform, link: link)
        return ResolvedDownload(url: link.url,
                                filename: file.name,
                                size: link.size > 0 ? link.size : file.size,
                                headers: headers,
                                platform: platform,
                                isGuest: !loggedIn,
                                cleanupDirFid: cleanupDirFid)
    }

    private static func transferThenDownload(client: PanClient,
                                             session: ShareSession,
                                             file: ShareFileItem,
                                             cookie: String,
                                             cleanup: inout String?) async throws -> PanDownloadLink {
        let baseDir = try await client.ensureTempDir(cookie: cookie)
        // 每次用唯一子目录：夸克去重键是 to_pdir_fid，目录不同 ⇒ 每次都是新 fid
        let unique = "tr_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0...999999))"
        let subDir = try await client.createFolder(name: unique, parentFid: baseDir, cookie: cookie)
        cleanup = subDir

        let taskId = try await client.saveShareFile(session: session, file: file, toDirFid: subDir, cookie: cookie)
        let savedFid = try await client.pollTask(taskId: taskId, cookie: cookie)
        return try await client.cloudDownloadLink(fid: savedFid, cookie: cookie)
    }

    /// 下载完成后清理云端临时目录（失败不清理，留给用户重试用）
    static func cleanup(platform: SharePlatform, dirFid: String?) async {
        guard let dirFid, !dirFid.isEmpty else { return }
        let client = PanClient(platform: platform)
        let cookie = CookieStore.shared.cookie(for: platform) ?? ""
        guard PanUtil.isValidCookie(cookie) else { return }
        await client.deleteFile(fid: dirFid, cookie: cookie)
    }

    /// 账号昵称（登录校验）
    static func nickname(platform: SharePlatform, cookie: String) async -> String? {
        await PanClient(platform: platform).fetchNickname(cookie: cookie)
    }

    /// 网盘容量
    static func quota(platform: SharePlatform) async -> (used: Int64, total: Int64)? {
        let cookie = CookieStore.shared.cookie(for: platform) ?? ""
        guard PanUtil.isValidCookie(cookie) else { return nil }
        return await PanClient(platform: platform).quota(cookie: cookie)
    }

    /// 会话刷新（__puus 约 3 小时有效，90 分钟节流一次）
    static func refreshSessionIfNeeded(platform: SharePlatform) async {
        let key = "yunx.puusRefresh.\(platform.rawValue)"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard now - last > 90 * 60 else { return }
        let cookie = CookieStore.shared.cookie(for: platform) ?? ""
        guard PanUtil.isValidCookie(cookie) else { return }
        if let fresh = await PanClient(platform: platform).refreshSession(cookie: cookie) {
            CookieStore.shared.setCookie(fresh, for: platform)
        }
        UserDefaults.standard.set(now, forKey: key)
    }
}
