//
//  QuarkProvider.swift
//  YunX · 夸克 / UC（同构，共用 PanClient）
//

import Foundation

class QuarkLikeProvider: PanProvider {
    let platform: SharePlatform
    private let client: PanClient

    init(platform: SharePlatform) {
        self.platform = platform
        self.client = PanClient(platform: platform)
    }

    // MARK: 会话

    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        let cookie = PanTool.cookie(platform)
        let token = try await client.shareToken(shareId: shareId, pwd: pwd, cookie: cookie)
        return ShareSession(platform: platform,
                            shareId: shareId,
                            stoken: token.stoken,
                            title: token.title)
    }

    // MARK: 列表

    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem] {
        try await client.shareFilesAll(session: session, dirFid: dirFid)
    }

    // MARK: 取链

    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        let cookie = PanTool.cookie(platform)
        let loggedIn = PanUtil.isValidCookie(cookie)
        var link: PanDownloadLink
        var cleanupDirFid: String? = nil

        if loggedIn {
            do {
                link = try await client.downloadLinkWithoutSave(session: session, file: file, cookie: cookie)
            } catch {
                // 服务端仍要求先转存的分享类型，走转存兜底
                let fallback = try await transferThenDownload(session: session, file: file, cookie: cookie)
                link = fallback.link
                cleanupDirFid = fallback.cleanupDirFid
            }
        } else {
            link = try await client.guestDownloadLink(session: session, file: file)
        }

        // 把「取链那一刻」的 Cookie 钉在直链上（游客态用 guestCookie，
        // 登录态用本次取链入参 cookie），供下载头复用。
        link.linkCookie = loggedIn ? cookie : link.guestCookie
        let headers = Self.downloadHeaders(platform: platform, link: link)
        return ResolvedDownload(url: link.url,
                                filename: file.name,
                                size: link.size > 0 ? link.size : file.size,
                                headers: headers,
                                platform: platform,
                                isGuest: !loggedIn,
                                cleanupDirFid: cleanupDirFid)
    }

    private func transferThenDownload(session: ShareSession,
                                      file: ShareFileItem,
                                      cookie: String) async throws -> (link: PanDownloadLink, cleanupDirFid: String?) {
        let baseDir = try await client.ensureTempDir(cookie: cookie)
        let unique = "tr_\(Int(Date().timeIntervalSince1970 * 1000))_\(YXCrypto.randomInt(1_000_000))"
        let subDir = try await client.createFolder(name: unique, parentFid: baseDir, cookie: cookie)
        let taskId = try await client.saveShareFile(session: session, file: file, toDirFid: subDir, cookie: cookie)
        let savedFid = try await client.pollTask(taskId: taskId, cookie: cookie)
        let link = try await client.cloudDownloadLink(fid: savedFid, cookie: cookie)
        return (link, subDir)
    }

    // MARK: 账号

    func quota() async -> (used: Int64, total: Int64)? {
        let cookie = PanTool.cookie(platform)
        guard PanUtil.isValidCookie(cookie) else { return nil }
        return await client.quota(cookie: cookie)
    }

    func nickname(cookie: String) async -> String? {
        await client.fetchNickname(cookie: cookie)
    }

    // MARK: 下载头

    /// 直链签名绑死「取链那一刻的那份 Cookie」
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
        } else if !link.linkCookie.isEmpty {
            // 直链签名绑死取链时的那份 Cookie；重新读 Keychain 可能已换成
            // 另一个账号或刷新后的 __puus，服务端会直接返 412。
            headers["Cookie"] = link.linkCookie
        } else {
            let cookie = PanTool.cookie(platform)
            if !cookie.isEmpty { headers["Cookie"] = cookie }
        }
        if platform == .uc {
            headers["Origin"] = cfg.webOrigin
        }
        return headers
    }
}

final class QuarkProvider: QuarkLikeProvider {
    init() { super.init(platform: .quark) }
}

final class UCProvider: QuarkLikeProvider {
    init() { super.init(platform: .uc) }
}
