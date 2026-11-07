//
//  Pan123Provider.swift
//  YunX · 123 云盘（匿名分享链路，无需登录）
//
//  分享列表与分享直链都是匿名接口，签名只用于个人盘，本文件不涉及 CRC32 签名。
//  直链有两种形态：整段 base64 / download-v2?params=<base64url>，解出来还可能带
//  auto_redirect=0 的中间 JSON，需要再跟一跳。
//

import Foundation

final class Pan123Provider: PanProvider {
    let platform: SharePlatform = .pan123

    private let listHost = "https://yun.123pan.cn"
    private let downloadHost = "https://www.123865.com"

    // MARK: 会话

    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        var extra: [String: String] = [:]
        if let pwd, !pwd.isEmpty { extra["pwd"] = pwd }
        var session = ShareSession(platform: .pan123,
                                   shareId: shareId,
                                   stoken: "",
                                   title: "123 云盘分享",
                                   extra: extra)
        // 立刻拉一页做校验：提取码错误 / 分享失效能第一时间暴露
        let page = try await fetchPage(session: session, dirFid: "0", page: 1, next: "")
        if !page.title.isEmpty { session.title = page.title }
        return session
    }

    // MARK: 列表

    func listFiles(session: ShareSession, dirFid: String) async throws -> [ShareFileItem] {
        var all: [ShareFileItem] = []
        var seen = Set<String>()
        var page = 1
        var next = ""
        while page <= 30 {
            let result = try await fetchPage(session: session, dirFid: dirFid, page: page, next: next)
            if result.items.isEmpty { break }
            var added = 0
            for item in result.items where !seen.contains(item.fid) {
                seen.insert(item.fid)
                all.append(item)
                added += 1
            }
            if added == 0 { break }
            if result.next == "-1" || result.next.isEmpty { break }
            next = result.next
            page += 1
        }
        return all
    }

    private struct PageResult {
        var items: [ShareFileItem]
        var next: String
        var title: String
    }

    private func fetchPage(session: ShareSession, dirFid: String, page: Int, next: String) async throws -> PageResult {
        var pairs: [(String, String)] = [
            ("limit", "100"),
            ("next", next),
            ("orderBy", "file_name"),
            ("orderDirection", "asc"),
            ("shareKey", session.shareId),
            ("ParentFileId", dirFid),
            ("Page", String(page))
        ]
        let pwd = session.value("pwd")
        if !pwd.isEmpty {
            pairs.append(("SharePwd", pwd))
        }
        let url = listHost + "/b/api/share/get?" + YXURLUtil.query(pairs)

        let json = try await PanTool.json(url: url, headers: [
            "User-Agent": YXUA.dart,
            "Accept": "application/json",
            "Referer": listHost + "/"
        ])

        let code = json.yxInt("code") ?? -1
        if code != 0 && code != 200 {
            let msg = json.yxString("message") ?? "123 云盘解析失败（code \(code)）"
            // 提取码相关错误给更明确的提示
            if msg.contains("密码") || msg.contains("passwd") || msg.contains("pass") {
                throw YXError.business("提取码错误或需要提取码")
            }
            throw YXError.business(msg)
        }

        let data = json.yxDict("data")
        let rawList = data.yxArray("InfoList")
        let expired = data.yxBool("Expired") ?? false
        if rawList.isEmpty && expired {
            throw YXError.business("分享已失效")
        }

        let title = data.yxString("ShareName")
            ?? data.yxString("ShareInfo.ShareName")
            ?? ""

        let items: [ShareFileItem] = rawList.compactMap { row in
            let fileId = row.yxString("FileId") ?? row.yxString("fileId") ?? ""
            guard !fileId.isEmpty else { return nil }
            let type = row.yxInt("Type") ?? row.yxInt("type") ?? 0
            let s3 = row.yxString("S3KeyFlag") ?? row.yxString("s3KeyFlag") ?? ""
            let etag = row.yxString("Etag") ?? row.yxString("etag") ?? ""
            let node = row.yxString("StorageNode") ?? row.yxString("storageNode") ?? ""
            return ShareFileItem(
                fid: fileId,
                name: row.yxString("FileName") ?? row.yxString("fileName") ?? "未命名",
                size: row.yxInt64("Size") ?? row.yxInt64("size") ?? 0,
                isDir: type == 1,
                parentFid: row.yxString("ParentFileId") ?? dirFid,
                // fidToken 复用为 "S3KeyFlag|Etag|StorageNode"
                fidToken: "\(s3)|\(etag)|\(node)",
                modifyTime: row.yxString("UpdateAt") ?? ""
            )
        }

        return PageResult(items: items,
                          next: data.yxString("Next") ?? "",
                          title: title)
    }

    // MARK: 取链

    func resolveDownload(session: ShareSession, file: ShareFileItem) async throws -> ResolvedDownload {
        let parts = file.fidToken.components(separatedBy: "|")
        let s3KeyFlag = parts.count > 0 ? parts[0] : ""
        let etag = parts.count > 1 ? parts[1] : ""
        let node = parts.count > 2 ? parts[2] : ""
        _ = node

        let body: [String: Any] = [
            "ShareKey": session.shareId,
            "FileID": Int64(file.fid) ?? 0,
            "S3KeyFlag": s3KeyFlag,
            "Size": file.size,
            "Etag": etag
        ]

        let json = try await PanTool.json(
            url: downloadHost + "/b/api/share/download/info",
            method: "POST",
            headers: [
                "User-Agent": YXUA.dart,
                "Content-Type": "application/json",
                "platform": "android",
                "app-version": "39",
                "Referer": downloadHost + "/"
            ],
            body: PanTool.jsonBody(body)
        )

        let code = json.yxInt("code") ?? -1
        guard code == 0 || code == 200 else {
            throw YXError.business(json.yxString("message") ?? "取链失败（code \(code)）")
        }
        guard let raw = json.yxString("data.DownloadURL"), !raw.isEmpty else {
            throw YXError.business("未返回下载地址")
        }

        let decoded = Self.decodeDownloadURL(raw)
        let finalURL = try await followRedirectIfNeeded(decoded)

        return ResolvedDownload(
            url: finalURL,
            filename: file.name,
            size: file.size,
            headers: [
                "User-Agent": YXUA.dart,
                "Referer": listHost + "/",
                "Accept": "*/*",
                "Accept-Encoding": "identity"
            ],
            platform: .pan123,
            isGuest: true
        )
    }

    /// 两种编码形态 + 一种中间页
    static func decodeDownloadURL(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // download-v2?params=<base64url>
        if let range = text.range(of: "params=") {
            let param = String(text[range.upperBound...])
            if let data = YXBase64.decodeBase64URL(param),
               let decoded = String(data: data, encoding: .utf8),
               decoded.contains("://") {
                text = decoded
            }
        }

        // 整段 base64
        if !text.contains("://") {
            if let data = YXBase64.decode(text),
               let decoded = String(data: data, encoding: .utf8) {
                text = decoded
            }
        }

        // 还可能再套一层
        if text.contains("download-v2?params="), let range = text.range(of: "params=") {
            let param = String(text[range.upperBound...])
            if let data = YXBase64.decodeBase64URL(param),
               let decoded = String(data: data, encoding: .utf8) {
                text = decoded
            }
        }
        return text
    }

    /// auto_redirect=0 时，GET 会返回一个指向真实地址的小 JSON
    private func followRedirectIfNeeded(_ url: String) async throws -> String {
        var current = url
        for _ in 0..<5 {
            guard current.contains("auto_redirect=0") else { return current }
            var req = HTTPRequest(url: current)
            req.headers = [
                "User-Agent": YXUA.dart,
                "Referer": listHost + "/"
            ]
            req.injectCookies = false
            guard let res = try? await HTTPClient.shared.send(req) else { return current }
            guard res.status == 200, res.data.count <= 8192 else { return current }
            let text = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("{") else { return current }
            guard let json = try? res.json() else { return current }
            guard let next = json.yxString("data.redirect_url") ?? json.yxString("redirect_url"),
                  !next.isEmpty else { return current }
            current = next
        }
        return current
    }

    func nickname(cookie: String) async -> String? { nil }
}
