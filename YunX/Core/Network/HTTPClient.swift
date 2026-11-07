//
//  HTTPClient.swift
//  YunX · 统一 HTTP 层
//

import Foundation

enum YXError: LocalizedError {
    case invalidURL(String)
    case badStatus(Int, String?)
    case business(String)
    case decoding(String)
    case network(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s):        return "链接无效：\(s)"
        case .badStatus(let c, let m):  return m ?? "请求失败（HTTP \(c)）"
        case .business(let m):          return m
        case .decoding(let m):          return "数据解析失败：\(m)"
        case .network(let m):           return "网络错误：\(m)"
        case .cancelled:                return "已取消"
        }
    }
}

struct HTTPRequest {
    var url: String
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 30
    /// 是否跳过 Cookie 自动注入（下载直链走自己的 Cookie）
    var injectCookies: Bool = true
}

struct HTTPResponse {
    let data: Data
    let response: HTTPURLResponse

    var status: Int { response.statusCode }
    var headers: [AnyHashable: Any] { response.allHeaderFields }

    var text: String { String(data: data, encoding: .utf8) ?? "" }

    func json() throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YXError.decoding("响应不是 JSON 对象")
        }
        return obj
    }
}

final class HTTPClient {
    static let shared = HTTPClient()

    private let session: URLSession
    private let cookieStore: CookieStore

    init(cookieStore: CookieStore = .shared, timeout: TimeInterval = 30) {
        self.cookieStore = cookieStore
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = 120
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: cfg)
    }

    func send(_ req: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: req.url) else { throw YXError.invalidURL(req.url) }
        var request = URLRequest(url: url)
        request.httpMethod = req.method
        request.timeoutInterval = req.timeout

        for (k, v) in req.headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if req.injectCookies, request.value(forHTTPHeaderField: "Cookie") == nil {
            let host = url.host ?? ""
            if let cookie = cookieStore.cookieHeader(forHost: host), !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        }
        if let body = req.body {
            request.httpBody = body
        }

        do {
            let (data, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse else {
                throw YXError.network("非 HTTP 响应")
            }
            return HTTPResponse(data: data, response: http)
        } catch is CancellationError {
            throw YXError.cancelled
        } catch let e as YXError {
            throw e
        } catch {
            throw YXError.network(error.localizedDescription)
        }
    }

    /// 发请求并要求 2xx，返回解析后的 JSON
    @discardableResult
    func json(_ req: HTTPRequest, allowStatus: Set<Int> = [200]) async throws -> [String: Any] {
        let res = try await send(req)
        guard allowStatus.contains(res.status) else {
            throw YXError.badStatus(res.status, res.text.prefix(160).description)
        }
        return try res.json()
    }
}

// MARK: - Cookie 存储

/// 按平台保存 Cookie 串（桌面版来自内嵌 Chromium / 导入 / 手动粘贴；
/// iOS 版来自 WKWebView 登录成功后抓取）。
/// 落盘走 Keychain —— 与桌面版「凭证加密存本机」对齐。
final class CookieStore {
    static let shared = CookieStore()

    private let keyPrefix = "yunx.cookie."

    func setCookie(_ cookie: String, for platform: SharePlatform) {
        YXKeychain.set(cookie, for: keyPrefix + platform.rawValue)
    }

    func cookie(for platform: SharePlatform) -> String? {
        YXKeychain.get(keyPrefix + platform.rawValue)
    }

    func removeCookie(for platform: SharePlatform) {
        YXKeychain.remove(keyPrefix + platform.rawValue)
    }

    func isLoggedIn(_ platform: SharePlatform) -> Bool {
        !(cookie(for: platform) ?? "").isEmpty
    }

    /// 按 host 找到所属平台并返回 Cookie
    func cookieHeader(forHost host: String) -> String? {
        let h = host.lowercased()
        for platform in SharePlatform.allCases {
            let domain = platform.cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if h.hasSuffix(domain), let c = cookie(for: platform), !c.isEmpty {
                return c
            }
        }
        return nil
    }
}

// MARK: - JSON 取值

extension Dictionary where Key == String, Value == Any {
    /// 支持 "data.list.0.file_name" 这种路径
    func yxPath(_ path: String) -> Any? {
        var current: Any? = self
        for seg in path.split(separator: ".") {
            let key = String(seg)
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else if let arr = current as? [Any], let idx = Int(key), idx >= 0, idx < arr.count {
                current = arr[idx]
            } else {
                return nil
            }
        }
        return current
    }

    func yxString(_ path: String) -> String? {
        switch yxPath(path) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    func yxInt(_ path: String) -> Int? {
        switch yxPath(path) {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    func yxInt64(_ path: String) -> Int64? {
        switch yxPath(path) {
        case let i as Int64: return i
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    func yxBool(_ path: String) -> Bool? {
        switch yxPath(path) {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return nil
        }
    }

    func yxArray(_ path: String) -> [[String: Any]] {
        (yxPath(path) as? [[String: Any]]) ?? []
    }

    func yxDict(_ path: String) -> [String: Any] {
        (yxPath(path) as? [String: Any]) ?? [:]
    }
}
