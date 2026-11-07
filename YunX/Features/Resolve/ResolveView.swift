//
//  ResolveView.swift
//  YunX · 解析页（粘贴分享链接 → 识别 → 浏览/下载）
//

import SwiftUI

struct ResolveView: View {
    @State private var input: String = ""
    @State private var isResolving = false
    @State private var errorText: String?
    @State private var session: ShareSession?
    @State private var showBrowser = false
    @State private var history: [ResolveHistoryItem] = ResolveHistoryItem.load()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YXMetric.sectionGap) {
                    inputCard
                    platformCard
                    if !history.isEmpty { historyCard }
                }
                .padding(.horizontal, YXMetric.pagePadding)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .yxPageBackground()
            .navigationTitle("解析")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let s = UIPasteboard.general.string {
                            input = s
                            errorText = nil
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                }
            }
            .navigationDestination(isPresented: $showBrowser) {
                if let session {
                    ShareBrowserView(session: session)
                }
            }
        }
    }

    // MARK: 输入

    private var inputCard: some View {
        YXGroupCard {
            VStack(alignment: .leading, spacing: 12) {
                YXTextField(placeholder: "粘贴分享链接或整段分享文案",
                            text: $input,
                            symbol: "link",
                            axis: .vertical,
                            lineLimit: 2...6)
                    .focused($focused)

                if let errorText {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(errorText).lineLimit(3)
                    }
                    .font(.yxCaption)
                    .foregroundStyle(YXColor.danger)
                }

                HStack(spacing: 10) {
                    if let parsed {
                        HStack(spacing: 6) {
                            YXIconTile(symbol: parsed.platform.symbol,
                                       tint: parsed.platform.tint,
                                       size: 22)
                            Text(parsed.platform.shortName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(YXColor.secondaryLabel)
                            if let pwd = parsed.pwd, !pwd.isEmpty {
                                YXBadge(text: "码 \(pwd)", tint: YXColor.warning)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        resolve()
                    } label: {
                        HStack(spacing: 6) {
                            if isResolving {
                                ProgressView().tint(.white).scaleEffect(0.8)
                            } else {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(isResolving ? "解析中" : "开始解析")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Capsule().fill(YXColor.brandGradient))
                    }
                    .yxPressable()
                    .disabled(isResolving || parsed == nil)
                    .opacity(parsed == nil ? 0.45 : 1)
                }
            }
            .padding(YXMetric.cardPadding)
        }
    }

    private var parsed: ParsedShare? {
        ShareLinkParser.parse(input)
    }

    // MARK: 平台

    private var platformCard: some View {
        YXSection("支持的平台", footnote: "夸克 / UC 已打通全链路下载；其余平台陆续接入") {
            VStack(spacing: 0) {
                let supported: [SharePlatform] = [.quark, .uc]
                let pending: [SharePlatform] = [.xunlei, .baidu, .pan123, .pan115, .c139, .guangya, .lanzou, .ilanzou, .github]
                ForEach(Array(supported.enumerated()), id: \.offset) { idx, p in
                    YXRow(symbol: p.symbol, tint: p.tint, title: p.displayName,
                          subtitle: "已支持", isLast: false) {
                        YXBadge(text: "可用", tint: YXColor.success)
                    }
                    .opacity(1)
                    .id("sup-\(idx)")
                }
                HStack(spacing: 6) {
                    ForEach(pending, id: \.self) { p in
                        Text(p.shortName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(YXColor.tertiaryLabel)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(YXColor.surfaceRaised))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, YXMetric.cardPadding)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: 历史

    private var historyCard: some View {
        YXSection("最近解析") {
            VStack(spacing: 0) {
                ForEach(Array(history.prefix(6).enumerated()), id: \.offset) { idx, item in
                    Button {
                        input = item.url
                        resolve()
                    } label: {
                        YXRow(symbol: item.platform.symbol,
                              tint: item.platform.tint,
                              title: item.title,
                              subtitle: item.url,
                              isLast: idx == min(history.count, 6) - 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 动作

    private func resolve() {
        guard let share = parsed else {
            errorText = "没识别出分享链接"
            return
        }
        guard PanConfigs.config(for: share.platform) != nil else {
            errorText = "\(share.platform.displayName) 暂未接入，先支持夸克与 UC"
            return
        }
        focused = false
        isResolving = true
        errorText = nil

        Task {
            do {
                let s = try await ResolveService.createSession(platform: share.platform,
                                                               shareId: share.shareId,
                                                               pwd: share.pwd)
                await MainActor.run {
                    session = s
                    isResolving = false
                    showBrowser = true
                    ResolveHistoryItem.push(url: input,
                                            title: s.title,
                                            platform: share.platform)
                    history = ResolveHistoryItem.load()
                }
            } catch {
                await MainActor.run {
                    isResolving = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 解析历史

struct ResolveHistoryItem: Codable, Identifiable {
    var id = UUID()
    var url: String
    var title: String
    var platform: SharePlatform
    var at: Date = Date()

    private static let key = "yunx.resolveHistory"

    static func load() -> [ResolveHistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ResolveHistoryItem].self, from: data) else {
            return []
        }
        return list
    }

    static func push(url: String, title: String, platform: SharePlatform) {
        var list = load()
        list.removeAll { $0.url == url }
        list.insert(ResolveHistoryItem(url: url, title: title, platform: platform), at: 0)
        if list.count > 30 { list = Array(list.prefix(30)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
