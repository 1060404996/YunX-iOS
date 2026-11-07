//
//  DriveView.swift
//  YunX · 网盘账号（登录状态 / 昵称 / 容量）
//

import SwiftUI

struct DriveView: View {
    @State private var accounts: [SharePlatform: AccountStatus] = [:]
    @State private var loginTarget: SharePlatform?
    @State private var isLoading = false

    struct AccountStatus: Equatable {
        var loggedIn: Bool
        var nickname: String?
        var used: Int64 = 0
        var total: Int64 = 0
    }

    private let loginPlatforms: [SharePlatform] = [.quark, .uc, .baidu, .pan115, .lanzou, .ilanzou]
    private let guestPlatforms: [SharePlatform] = [.pan123, .c139, .guangya, .xunlei, .github]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YXMetric.sectionGap) {
                    summaryCard
                    accountsCard
                    guestCard
                }
                .padding(.horizontal, YXMetric.pagePadding)
                .padding(.bottom, 28)
            }
            .yxPageBackground()
            .navigationTitle("网盘")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refresh()
                    } label: {
                        if isLoading {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .sheet(item: $loginTarget) { platform in
                LoginView(platform: platform) { cookie in
                    CookieStore.shared.setCookie(cookie, for: platform)
                    refresh()
                }
            }
            .task { refresh() }
        }
    }

    // MARK: 概览

    private var summaryCard: some View {
        YXGroupCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(YXColor.brandGradient)
                            .frame(width: 46, height: 46)
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("云析")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(YXColor.label)
                        Text("粘贴分享链接，直接高速下载")
                            .font(.yxCaption)
                            .foregroundStyle(YXColor.secondaryLabel)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    statPill(title: "已登录", value: "\(loggedCount)", tint: YXColor.success)
                    statPill(title: "总容量", value: totalCapacityText, tint: YXColor.brand)
                    statPill(title: "已使用", value: usedCapacityText, tint: YXColor.warning)
                }
            }
            .padding(YXMetric.cardPadding)
        }
    }

    private func statPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.yxFootnote)
                .foregroundStyle(YXColor.secondaryLabel)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(YXColor.surfaceRaised)
        )
    }

    private var loggedCount: Int {
        loginPlatforms.filter { accounts[$0]?.loggedIn == true }.count
    }

    private var totalCapacityText: String {
        let total = accounts.values.reduce(Int64(0)) { $0 + $1.total }
        return total > 0 ? YXFormat.bytes(total) : "—"
    }

    private var usedCapacityText: String {
        let used = accounts.values.reduce(Int64(0)) { $0 + $1.used }
        return used > 0 ? YXFormat.bytes(used) : "—"
    }

    // MARK: 账号

    private var accountsCard: some View {
        YXSection("账号", footnote: "凭证加密存 Keychain，退出登录即从本机清除") {
            VStack(spacing: 0) {
                ForEach(Array(loginPlatforms.enumerated()), id: \.offset) { idx, platform in
                    accountRow(platform, isLast: idx == loginPlatforms.count - 1)
                }
            }
        }
    }

    private func accountRow(_ platform: SharePlatform, isLast: Bool) -> some View {
        let status = accounts[platform]
        return YXRow(symbol: platform.symbol,
                     tint: platform.tint,
                     title: platform.displayName,
                     subtitle: subtitle(for: status),
                     isLast: isLast) {
            if status?.loggedIn == true {
                HStack(spacing: 6) {
                    YXBadge(text: "已登录", tint: YXColor.success)
                    Button {
                        CookieStore.shared.removeCookie(for: platform)
                        refresh()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(YXColor.tertiaryLabel)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                YXPillButton(title: "登录", symbol: "person.badge.key") {
                    loginTarget = platform
                }
            }
        }
    }

    private func subtitle(for status: AccountStatus?) -> String {
        guard let status else { return "未登录" }
        if !status.loggedIn { return "游客态：小文件可直接下载" }
        var parts: [String] = []
        if let nick = status.nickname, !nick.isEmpty { parts.append(nick) }
        if status.total > 0 {
            parts.append("\(YXFormat.bytes(status.used)) / \(YXFormat.bytes(status.total))")
        } else {
            parts.append("登录态有效")
        }
        return parts.joined(separator: " · ")
    }

    private var guestCard: some View {
        YXSection("免登录即可解析", footnote: "这些平台的分享链接不需要账号，可直接浏览与下载") {
            VStack(spacing: 0) {
                ForEach(Array(guestPlatforms.enumerated()), id: \.offset) { idx, p in
                    YXRow(symbol: p.symbol,
                          tint: p.tint,
                          title: p.displayName,
                          subtitle: guestSubtitle(p),
                          isLast: idx == guestPlatforms.count - 1) {
                        YXBadge(text: "免登录", tint: YXColor.success)
                    }
                }
            }
        }
    }

    private func guestSubtitle(_ p: SharePlatform) -> String {
        switch p {
        case .pan123:  return "分享列表与直链都是匿名接口"
        case .c139:    return "分享通道无需 Authorization"
        case .guangya: return "匿名请求需带设备标识"
        case .xunlei:  return "游客态解析，部分分享需提取码"
        case .github:  return "公开仓库可直连，Token 仅提升限额"
        default:       return "免登录"
        }
    }

    // MARK: 数据

    private func refresh() {
        isLoading = true
        var next: [SharePlatform: AccountStatus] = [:]
        for platform in loginPlatforms {
            next[platform] = AccountStatus(loggedIn: PanTool.hasCredential(platform), nickname: nil)
        }
        accounts = next

        Task {
            for platform in loginPlatforms {
                let cookie = PanTool.cookie(platform)
                guard PanTool.hasCredential(platform) else { continue }
                let nick = await ResolveService.nickname(platform: platform, cookie: cookie)
                let quota = await ResolveService.quota(platform: platform)
                await MainActor.run {
                    var status = accounts[platform] ?? AccountStatus(loggedIn: true)
                    status.nickname = nick
                    if let quota {
                        status.used = quota.used
                        status.total = quota.total
                    }
                    accounts[platform] = status
                }
            }
            await MainActor.run { isLoading = false }
        }
    }
}
