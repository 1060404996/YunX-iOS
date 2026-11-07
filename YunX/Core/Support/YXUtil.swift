//
//  YXUtil.swift
//  YunX · 通用工具（URL 编码 / Base64 变体 / HTML 提取）
//

import Foundation

// MARK: - URL

enum YXURLUtil {
    /// RFC3986（除 unreserved 全编码）—— stoken 里的 = + 必须编码
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// JS encodeURIComponent 语义：还原 ! ' ( ) * 四个字符
    static func encodeURIComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
    }

    static func queryRaw(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    static func formBody(_ pairs: [(String, String)]) -> Data {
        queryRaw(pairs).data(using: .utf8) ?? Data()
    }

    static func parseQuery(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in raw.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            let decoded = value.removingPercentEncoding ?? value
            out[String(key).removingPercentEncoding ?? String(key)] = decoded
        }
        return out
    }

    static func appending(_ url: String, query: [(String, String)]) -> String {
        guard !query.isEmpty else { return url }
        let sep = url.contains("?") ? "&" : "?"
        return url + sep + queryRaw(query)
    }
}

// MARK: - Base64

enum YXBase64 {
    static func decode(_ s: String) -> Data? {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Data(base64Encoded: text) { return d }
        // URL-safe
        text = text.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        return Data(base64Encoded: text)
    }

    static func decodeURLSafe(_ s: String) -> Data? {
        decode(s)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    /// 123 云盘 download-v2?params=<base64url> 用
    static func decodeBase64URL(_ s: String) -> Data? {
        var text = s.replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        return Data(base64Encoded: text)
    }
}

// MARK: - 文本 / HTML

enum YXHTML {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[pattern] { return hit }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache[pattern] = re
        return re
    }

    static func first(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = regex(pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              group < m.numberOfRanges else { return nil }
        let range = m.range(at: group)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }

    static func all(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let re = regex(pattern) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            guard group < m.numberOfRanges else { return nil }
            let range = m.range(at: group)
            guard range.location != NSNotFound else { return nil }
            return ns.substring(with: range)
        }
    }

    static func contains(_ pattern: String, in text: String) -> Bool {
        first(pattern, in: text, group: 0) != nil
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&nbsp;": " ", "&mdash;": "—", "&hellip;": "…"
        ]
        for (k, v) in map {
            out = out.replacingOccurrences(of: k, with: v)
        }
        // 数字实体
        let pattern = "&#(\\d{1,6});"
        if let re = regex(pattern, options: []) {
            let ns = out as NSString
            let matches = re.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                guard m.numberOfRanges > 1 else { continue }
                let codeStr = ns.substring(with: m.range(at: 1))
                if let code = UInt32(codeStr), let scalar = Unicode.Scalar(code) {
                    out = (out as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
                }
            }
        }
        return out
    }

    static func stripTags(_ s: String) -> String {
        var out = s
        if let re = regex("<[^>]+>") {
            out = re.stringByReplacingMatches(in: out, options: [],
                                              range: NSRange(location: 0, length: (out as NSString).length),
                                              withTemplate: "")
        }
        return decodeEntities(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 常用 HTTP 头

enum YXUA {
    static let chromeDesktop = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let chrome124 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static let dart = "Dart/3.12 (dart:io)"
    static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let baiduNetdisk = "netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0"
}
