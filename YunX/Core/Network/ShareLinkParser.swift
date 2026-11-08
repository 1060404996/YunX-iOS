//
//  ShareLinkParser.swift
//  YunX · 分享链接识别
//
//  与桌面版 ShareLinkParser.kt 对齐，另外补两个 iOS 端必须处理的现实情况：
//  1) 很多人复制出来的链接没有 http:// 前缀（尤其百度 App 的文案）；
//  2) 百度还有 /share/init?surl=xxx 这种老形态。
//  所以「提取 URL」失败时会退化成「用原文直接跑平台正则」。
//

import Foundation

enum ShareLinkParser {

    // MARK: - 模式表（全部大小写不敏感）

    private static let urlPattern = "https?://[^\\s]+"

    private static let quarkPattern = "pan\\.quark\\.cn/s/([A-Za-z0-9]+)"
    private static let ucPattern = "drive\\.uc\\.cn/s/([A-Za-z0-9]+)"
    private static let xunleiPattern = "pan\\.xunlei\\.com/s/([A-Za-z0-9_-]+)"

    /// 百度两种形态：/s/1xxxx 与 /share/init?surl=xxxx
    private static let baiduPattern = "pan\\.baidu\\.com/s/(1[A-Za-z0-9_-]+)"
    private static let baiduInitPattern = "pan\\.baidu\\.com/share/init\\?surl=([A-Za-z0-9_-]+)"

    private static let c139Pattern = "yun\\.139\\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)"

    private static let pan123Pattern = "123(?:865|pan)\\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)"
    private static let pan123SubPattern = "share\\.123pan\\.cn/123pan/([A-Za-z0-9-]+)"
    private static let pan123SrrPattern = "api/srr\\?sk=([A-Za-z0-9-]+)"

    private static let pan115Pattern = "115(?:cdn|rc)?\\.com/s/(sw[A-Za-z0-9]+)"
    private static let pan115CommandPattern = "115(?:cdn|rc)?\\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"
    private static let pwd115Pattern = "[?&]password=([A-Za-z0-9]+)"

    private static let guangyaPattern = "guangyapan\\.com/s/([A-Za-z0-9_-]+)"

    /// 优享版必须先判：前置边界防止把 www.ilanzou.com 吞成 lanzou.com
    private static let ilanzouPattern = "(?:^|[/.])ilanzou\\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)"
    private static let lanzouPattern = "(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux])\\.(?:com|net|org|cn)/([A-Za-z0-9]+)"
    private static let pwdLanzouPattern = "[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)"

    private static let pwdInUrlPattern = "[?&]pwd=([A-Za-z0-9]+)"
    private static let pwdInTextPattern = "(?:提取码|访问码|密码|提取码:|提取码：)[：:\\s]*([A-Za-z0-9]{4,8})"

    // MARK: - 入口

    /// 从分享链接或整段分享文案中提取 shareId 与提取码。
    static func parse(_ rawText: String) -> ParsedShare? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 第 1 轮：先按标准 URL 提取
        if let rawUrl = firstMatch(urlPattern, in: trimmed) {
            let trailing: Set<Character> = ["。", "，", ",", "；", ";", ")", "]", "}", "\"", "'", "」", "』", "）", "》"]
            var url = rawUrl
            while let last = url.last, trailing.contains(last) {
                url.removeLast()
            }
            if let result = matchPlatform(url, fullText: trimmed) {
                return result
            }
        }

        // 第 2 轮：没有 scheme 的链接（百度 App 文案常见），直接拿原文跑平台正则
        return matchPlatform(trimmed, fullText: trimmed)
    }

    /// 磁力 / ed2k 识别（iOS 端交给外部 BT 引擎，本机只做提示）
    static func isP2PLink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("magnet:?") || t.hasPrefix("ed2k://")
    }

    /// 从文案里挑出第一段 URL 原文（用于界面回填）
    static func firstUrl(in text: String) -> String? {
        firstMatch(urlPattern, in: text)
    }

    /// 仅做平台判定（不关心能否拿到完整链接），用于输入框实时提示
    static func detectPlatform(_ text: String) -> SharePlatform? {
        parse(text)?.platform
    }

    // MARK: - 平台匹配（顺序敏感）

    private static func matchPlatform(_ url: String, fullText: String) -> ParsedShare? {
        // 夸克
        if let sid = firstMatch(quarkPattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: pwdFromUrl(url) ?? pwdFromText(fullText),
                               platform: .quark)
        }
        // UC
        if let sid = firstMatch(ucPattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: pwdFromUrl(url) ?? pwdFromText(fullText),
                               platform: .uc)
        }
        // 迅雷
        if let sid = firstMatch(xunleiPattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: pwdFromUrl(url) ?? pwdFromText(fullText),
                               platform: .xunlei)
        }
        // 百度 /s/1xxxx：surl 不含开头的 "1"
        if let sid = firstMatch(baiduPattern, in: url) {
            let surl = sid.hasPrefix("1") ? String(sid.dropFirst()) : sid
            return ParsedShare(shareId: surl,
                               pwd: pwdFromUrl(url) ?? pwdFromText(fullText),
                               platform: .baidu)
        }
        // 百度 /share/init?surl=xxxx：本身就是 surl，不再去前缀
        if let sid = firstMatch(baiduInitPattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: pwdFromUrl(url) ?? pwdFromText(fullText),
                               platform: .baidu)
        }
        // 139（和彩云）
        if let sid = firstMatch(c139Pattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: pwdFromUrl(url) ?? pwdFromText(fullText),
                               platform: .c139)
        }
        // 123 云盘：三种形态
        if let sid = firstMatch(pan123Pattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: pwdFromUrl(url) ?? pwdFromText(fullText),
                               platform: .pan123)
        }
        if let sid = firstMatch(pan123SubPattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: pwdFromUrl(url) ?? pwdFromText(fullText),
                               platform: .pan123)
        }
        if let sid = firstMatch(pan123SrrPattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: pwdFromUrl(url) ?? pwdFromText(fullText),
                               platform: .pan123)
        }
        // 115 普通链接
        if let sid = firstMatch(pan115Pattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: firstMatch(pwd115Pattern, in: url) ?? pwdFromText(fullText),
                               platform: .pan115)
        }
        // 115 口令形式：115.com/sws8lxs36jf-n307/
        if let m = matchGroups(pan115CommandPattern, in: url), m.count >= 3 {
            return ParsedShare(shareId: m[1], pwd: m[2], platform: .pan115)
        }
        // 光鸭云盘
        if let sid = firstMatch(guangyaPattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: pwdFromUrl(url) ?? pwdFromText(fullText),
                               platform: .guangya)
        }
        // 蓝奏云优享版（必须先于蓝奏云）
        if let sid = firstMatch(ilanzouPattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: firstMatch(pwdLanzouPattern, in: url) ?? pwdFromText(fullText),
                               platform: .ilanzou)
        }
        // 蓝奏云
        if let sid = firstMatch(lanzouPattern, in: url) {
            return ParsedShare(shareId: sid,
                               pwd: firstMatch(pwdLanzouPattern, in: url) ?? pwdFromText(fullText),
                               platform: .lanzou)
        }
        // GitHub（最宽松，放最后）
        // firstMatch 只返回第 1 个捕获组。早期版本写成两个组，shareId 只剩 owner，
        // 而 GitHubProvider.parseTarget 至少要求 owner/repo，导致所有 GitHub 链接
        // 都报「无法识别仓库」。这里把 owner/repo 及后续 tree/blob 路径收进单个组，
        // 交给 parseTarget 自行拆分。
        if let m = firstMatch("github\\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[^\\s?#]*)?)", in: url) {
            return ParsedShare(shareId: m, pwd: nil, platform: .github)
        }
        return nil
    }

    // MARK: - 私有工具

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[pattern] { return hit }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        cache[pattern] = re
        return re
    }

    /// 返回第 1 个捕获组
    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let groups = matchGroups(pattern, in: text), groups.count > 1 else { return nil }
        return groups[1]
    }

    /// 返回 [group0, group1, ...]，未匹配的组为空串
    private static func matchGroups(_ pattern: String, in text: String) -> [String]? {
        guard let re = regex(pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var out: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            out.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return out
    }

    private static func pwdFromUrl(_ url: String) -> String? {
        firstMatch(pwdInUrlPattern, in: url)
    }

    private static func pwdFromText(_ text: String) -> String? {
        firstMatch(pwdInTextPattern, in: text)
    }
}
