//
//  GitHubProvider.swift
//  YunX · GitHub 仓库浏览 / 下载（匿名可用，可选 Token 提升限额）
//
//  结构与桌面版 GitHubLinkParser / GitHubApi 对齐：
//  分享链接 → owner/repo(/path)，目录用 contents API 逐层列，文件用 download_url 直下。
//  根目录 dirFid 是空串（外部可能传 "0" / "/"，一并归一）。
//  Token 复用 .github 平台的凭证槽，仅用于提升 API 限额，不影响匿名浏览。
//

import Foundation

final class GitHubProvider: PanProvider {
    let platform: SharePlatform = .github

    private let apiBase = "https://api.github.com"
    private let rawBase = "https://raw.githubusercontent.com"

    // MARK: 会话

    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        guard let target = Self.parseTarget(shareId) else {
            throw YXError.business("无法识别 GitHub 仓库：\(shareId)")
        }
        let fullName = target.owner + "/" + target.repo

        var extra: [String: String] = [
            "owner": target.owner,
            "repo": target.repo
        ]
        if !target.path.isEmpty { extra["path"] = target.path }
        if let branch = await defaultBranch(owner: target.owner, repo: target.repo), !branch.isEmpty {
            extra["branch"] = branch
        }

        // 立刻探一次目录：仓库不存在 / 私有仓库 / 限流第一时间暴露
        _ = try await contents(owner: target.owner, repo: target.repo, path: target.path)

        return ShareSession(platform: .github,
                            shareId: fullName,
                            stoken: "",
                            title: fullName,
                            extra: extra)
    }

    // MARK: 列表

    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem] {
        let owner = session.value("owner")
        let repo = session.value("repo")
        guard !owner.isEmpty, !repo.isEmpty else { throw YXError.business("GitHub 仓库信息缺失") }

        let dir = Self.resolveDir(dirFid)
        let rows = try await contents(owner: owner, repo: repo, path: dir)

        let items: [ShareFileItem] = rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let type = (row["type"] as? String) ?? ""
            let itemPath = (row["path"] as? String) ?? name
            let isDir = type == "dir"
            // 目录的 download_url 恒为 null，取到空串即为不可直下
            let download = (row["download_url"] as? String) ?? ""
            let size = (row["size"] as? NSNumber)?.int64Value ?? 0
            return ShareFileItem(fid: itemPath,
                                 name: name,
                                 size: size,
                                 isDir: isDir,
                                 parentFid: dir,
                                 fidToken: download,
                                 modifyTime: "")
        }

        // 目录优先，同组按名称自然序
        return items.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: 取链

    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        guard !file.isDir else { throw YXError.business("文件夹不支持直接下载") }

        let owner = session.value("owner")
        let repo = session.value("repo")
        guard !owner.isEmpty, !repo.isEmpty else { throw YXError.business("GitHub 仓库信息缺失") }

        var url = file.fidToken
        if url.isEmpty {
            // download_url 缺失时按默认分支拼 raw 地址（HEAD 亦可用于 public 仓库）
            var branch = session.value("branch")
            if branch.isEmpty {
                branch = await defaultBranch(owner: owner, repo: repo) ?? "HEAD"
            }
            url = rawBase + "/" + Self.encodeSegment(owner)
                + "/" + Self.encodeSegment(repo)
                + "/" + Self.encodeSegment(branch)
                + Self.encodePath(file.fid)
        }
        guard !url.isEmpty else { throw YXError.business("未能确定下载地址") }

        let token = tokenString()
        var headers: [String: String] = [
            "User-Agent": "YunX",
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
        if !token.isEmpty { headers["Authorization"] = "Bearer " + token }

        return ResolvedDownload(url: url,
                                filename: file.name,
                                size: file.size,
                                headers: headers,
                                platform: .github,
                                isGuest: token.isEmpty)
    }

    // MARK: 账号（可选）

    func nickname(cookie: String) async -> String? {
        let token = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        var req = HTTPRequest(url: apiBase + "/user")
        req.headers = [
            "User-Agent": "YunX",
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + token
        ]
        req.injectCookies = false
        guard let res = try? await HTTPClient.shared.send(req), res.status == 200 else { return nil }
        guard let json = try? res.json() else { return nil }
        let login = json.yxString("login") ?? ""
        return login.isEmpty ? nil : login
    }

    // MARK: 链接解析

    private struct Target {
        var owner: String
        var repo: String
        var path: String
    }

    /// 支持：owner/repo(/path)、https://github.com/{owner}/{repo}[/tree|blob|raw/{ref}/{path}]、
    /// releases/download/{tag}/{file}、raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}
    private static func parseTarget(_ raw: String) -> Target? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let range = text.range(of: "raw.githubusercontent.com/") {
            text = String(text[range.upperBound...])
        } else if let range = text.range(of: "github.com/") {
            text = String(text[range.upperBound...])
        }

        // 去掉 query / fragment
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[text.startIndex..<cut])
        }
        // 去掉尾随标点与斜杠
        let trailing: Set<Character> = ["。", "，", ",", "；", ";", ")", "]", "}", "\"", "'", "/"]
        while let last = text.last, trailing.contains(last) {
            text.removeLast()
        }

        let segments = text.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return nil }
        let owner = segments[0]
        var repo = segments[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }

        var rest = Array(segments.dropFirst(2))
        if let head = rest.first {
            switch head {
            case "tree", "blob", "raw":
                // 去掉 tree/blob/raw 与紧跟的分支名
                rest = Array(rest.dropFirst())
                if !rest.isEmpty { rest = Array(rest.dropFirst()) }
            case "releases":
                // releases 列表 / 资产直链都不构成目录，回落到仓库根
                rest = []
            default:
                break
            }
        }

        return Target(owner: owner, repo: repo, path: rest.joined(separator: "/"))
    }

    /// 根目录归一："" / "0" / "/" 都视为空串
    private static func resolveDir(_ dirFid: String) -> String {
        let trimmed = dirFid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "0" || trimmed == "/" { return "" }
        return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
    }

    private static func encodeSegment(_ value: String) -> String {
        YXURLUtil.encodeURIComponent(value)
    }

    private static func encodePath(_ path: String) -> String {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else { return "" }
        let encoded = clean.split(separator: "/").map { YXURLUtil.encodeURIComponent(String($0)) }
        return "/" + encoded.joined(separator: "/")
    }

    // MARK: 请求

    private func tokenString() -> String {
        PanTool.cookie(.github).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func authHeaders() -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": "YunX",
            "Accept": "application/vnd.github+json"
        ]
        let token = tokenString()
        if !token.isEmpty { headers["Authorization"] = "Bearer " + token }
        return headers
    }

    /// GET /repos/{owner}/{repo}/contents/{path}：目录返回数组，文件返回单个对象
    private func contents(owner: String, repo: String, path: String) async throws -> [[String: Any]] {
        let url = apiBase + "/repos/" + Self.encodeSegment(owner)
            + "/" + Self.encodeSegment(repo) + "/contents" + Self.encodePath(path)
        let payload = try await call(url)
        if let rows = payload as? [[String: Any]] { return rows }
        if payload is [String: Any] {
            throw YXError.business("该路径是文件，不是目录")
        }
        return []
    }

    private func defaultBranch(owner: String, repo: String) async -> String? {
        let url = apiBase + "/repos/" + Self.encodeSegment(owner) + "/" + Self.encodeSegment(repo)
        guard let payload = try? await call(url), let json = payload as? [String: Any] else { return nil }
        let branch = json.yxString("default_branch") ?? ""
        return branch.isEmpty ? nil : branch
    }

    private func call(_ url: String,
                      method: String = "GET",
                      allowStatus: Set<Int> = [200]) async throws -> Any {
        var req = HTTPRequest(url: url)
        req.method = method
        req.headers = authHeaders()
        req.injectCookies = false
        let res = try await HTTPClient.shared.send(req)
        guard allowStatus.contains(res.status) else {
            throw YXError.badStatus(res.status, res.text.prefix(200).description)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: res.data) else {
            throw YXError.decoding("GitHub 响应不是 JSON")
        }
        return payload
    }
}
