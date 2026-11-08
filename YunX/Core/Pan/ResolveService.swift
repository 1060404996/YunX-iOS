//
//  ResolveService.swift
//  YunX · 解析分发 + 公共能力
//
//  平台差异全部收敛在各 PanProvider 实现里；本文件只做分发与账号侧公共操作。
//

import Foundation

enum ResolveService {

    // MARK: 分发

    static func provider(for platform: SharePlatform) throws -> PanProvider {
        guard let p = PanProviders.provider(for: platform) else {
            throw YXError.business("\(platform.displayName) 暂未接入")
        }
        return p
    }

    static func createSession(platform: SharePlatform, shareId: String, pwd: String?) async throws -> ShareSession {
        // __puus 约 3 小时过期；此前 refreshSessionIfNeeded 只有定义、没有调用点，
        // 登录态过 3 小时后只能一直撞 412。三个入口统一做 90 分钟节流刷新。
        await refreshSessionIfNeeded(platform: platform)
        return try await provider(for: platform).createSession(shareId: shareId, pwd: pwd)
    }

    static func listFiles(session: ShareSession, dirFid: String = "0") async throws -> [ShareFileItem] {
        await refreshSessionIfNeeded(platform: session.platform)
        return try await provider(for: session.platform).listFiles(session: session, dirFid: dirFid)
    }

    static func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        await refreshSessionIfNeeded(platform: session.platform)
        return try await provider(for: session.platform).resolveDownload(session: session, file: file)
    }

    // MARK: 账号侧

    static func nickname(platform: SharePlatform, cookie: String) async -> String? {
        guard let p = PanProviders.provider(for: platform) else { return nil }
        return await p.nickname(cookie: cookie)
    }

    static func quota(platform: SharePlatform) async -> (used: Int64, total: Int64)? {
        guard let p = PanProviders.provider(for: platform) else { return nil }
        return await p.quota()
    }

    /// 会话刷新（夸克/UC 的 __puus 约 3 小时有效，90 分钟节流一次）
    static func refreshSessionIfNeeded(platform: SharePlatform) async {
        guard platform == .quark || platform == .uc else { return }
        let key = "yunx.puusRefresh.\(platform.rawValue)"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard now - last > 90 * 60 else { return }
        let cookie = PanTool.cookie(platform)
        guard PanUtil.isValidCookie(cookie) else { return }
        if let fresh = await PanClient(platform: platform).refreshSession(cookie: cookie) {
            PanTool.setCookie(fresh, platform)
        }
        UserDefaults.standard.set(now, forKey: key)
    }

    /// 下载完成后清理云端临时转存目录
    static func cleanup(platform: SharePlatform, dirFid: String?) async {
        guard let dirFid, !dirFid.isEmpty else { return }
        guard platform == .quark || platform == .uc else { return }
        let cookie = PanTool.cookie(platform)
        guard PanUtil.isValidCookie(cookie) else { return }
        await PanClient(platform: platform).deleteFile(fid: dirFid, cookie: cookie)
    }
}
