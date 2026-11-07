//
//  LoginView.swift
//  YunX · WKWebView 登录（抓 Cookie / Token）
//
//  桌面版用内嵌 Chromium 登录后遍历 Cookie 库；iOS 用 WKWebView + WKHTTPCookieStore，
//  轮询检测必需键，命中即回调保存。
//

import SwiftUI
import WebKit

struct LoginView: View {
    let platform: SharePlatform
    var onSuccess: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 0
    @State private var hint: String = "请在页面内完成登录"
    @State private var manualCookie: String = ""
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                CookieWebView(urlString: loginURL,
                              cookieDomains: [platform.cookieDomain,
                                              platform.cookieDomain.replacingOccurrences(of: ".", with: "")],
                              requiredKeys: requiredKeys,
                              onProgress: { progress = $0 },
                              onFound: { cookie in
                                  onSuccess(cookie)
                                  dismiss()
                              })
                    .ignoresSafeArea(edges: .bottom)

                if progress < 1 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(YXColor.brand)
                }
            }
            .navigationTitle("登录 \(platform.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("手动") { showManual = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(hint)
                    Spacer(minLength: 0)
                }
                .font(.yxFootnote)
                .foregroundStyle(YXColor.secondaryLabel)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
            .sheet(isPresented: $showManual) {
                manualSheet
            }
        }
    }

    private var requiredKeys: [String] {
        switch platform {
        case .quark, .uc:  return ["__pus", "__puus"]
        case .baidu:       return ["BDUSS"]
        case .pan115:      return ["UID", "SEID"]
        case .lanzou:      return ["phpdisk_info"]
        default:           return []
        }
    }

    private var loginURL: String {
        switch platform {
        case .quark:   return "https://pan.quark.cn/?fr=pc&platform=pc"
        case .uc:      return "https://drive.uc.cn/"
        case .baidu:   return "https://pan.baidu.com/"
        case .pan115:  return "https://115.com/"
        case .lanzou:  return "https://pc.woozooo.com/account.php"
        case .ilanzou: return "https://www.ilanzou.com/"
        case .xunlei:  return "https://pan.xunlei.com/"
        case .c139:    return "https://yun.139.com/"
        case .guangya: return "https://www.guangyapan.com/"
        case .pan123:  return "https://www.123pan.com/"
        case .github:  return "https://github.com/login"
        }
    }

    private var manualSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("从任何能登录的浏览器复制完整 Cookie 串粘贴进来")
                    .font(.yxCaption)
                    .foregroundStyle(YXColor.secondaryLabel)
                YXTextField(placeholder: "k1=v1; k2=v2; …",
                            text: $manualCookie,
                            symbol: "key",
                            axis: .vertical,
                            lineLimit: 4...10)
                YXPrimaryButton(title: "保存并校验", symbol: "checkmark.seal") {
                    Task {
                        if let nick = await ResolveService.nickname(platform: platform, cookie: manualCookie) {
                            CookieStore.shared.setCookie(manualCookie, for: platform)
                            await MainActor.run {
                                hint = "已登录：\(nick)"
                                showManual = false
                                onSuccess(manualCookie)
                                dismiss()
                            }
                        } else {
                            await MainActor.run { hint = "Cookie 无效或已过期" }
                        }
                    }
                }
                Spacer()
            }
            .padding(20)
            .yxPageBackground()
            .navigationTitle("手动填写 Cookie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showManual = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - WKWebView 封装

struct CookieWebView: UIViewRepresentable {
    let urlString: String
    let cookieDomains: [String]
    let requiredKeys: [String]
    let onProgress: (Double) -> Void
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = YXUA.chromeDesktop

        context.coordinator.startPolling()

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: CookieWebView
        private var timer: Timer?

        init(_ parent: CookieWebView) {
            self.parent = parent
        }

        func startPolling() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                self?.checkCookies()
            }
        }

        deinit {
            timer?.invalidate()
        }

        private func checkCookies() {
            // 没有明确必需键的平台不做自动检测，只走手动粘贴
            guard !parent.requiredKeys.isEmpty else { return }
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let names = Set(cookies.map { $0.name })
                guard self.parent.requiredKeys.allSatisfy({ names.contains($0) }) else { return }

                let relevant = cookies.filter { cookie in
                    let d = cookie.domain.lowercased()
                    return self.parent.cookieDomains.contains { domain in
                        let clean = domain.lowercased()
                        return d == clean || d.hasSuffix(clean) || clean.hasSuffix(d)
                    }
                }
                let chosen = relevant.isEmpty ? cookies : relevant
                let header = chosen
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                guard !header.isEmpty else { return }

                self.timer?.invalidate()
                self.timer = nil
                DispatchQueue.main.async {
                    self.parent.onFound(header)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onProgress(1)
            checkCookies()
        }

        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onProgress(0.3)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            parent.onProgress(1)
        }
    }
}
