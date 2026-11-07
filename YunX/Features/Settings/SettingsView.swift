//
//  SettingsView.swift
//  YunX · 设置
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("download_threads") private var threads: Int = 16
    @AppStorage("download_speed_limit") private var speedLimitKB: Int = 0
    @AppStorage("auto_clean_parts") private var autoCleanParts: Bool = true

    @State private var cacheSize: Int64 = 0
    @State private var showCleanDone = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YXMetric.sectionGap) {
                    downloadCard
                    storageCard
                    aboutCard
                }
                .padding(.horizontal, YXMetric.pagePadding)
                .padding(.bottom, 28)
            }
            .yxPageBackground()
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .task { cacheSize = Self.partsSize() }
        }
    }

    // MARK: 下载

    private var downloadCard: some View {
        YXSection("下载",
                  footnote: "迅雷类 CDN 会把单文件并发超过 8 的请求降级成整包返回，接入迅雷时会自动限到 8 路") {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("并发线程数")
                            .font(.yxRowTitle)
                            .foregroundStyle(YXColor.label)
                        Spacer()
                        Text("\(threads)")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(YXColor.brand)
                    }
                    Slider(value: Binding(
                        get: { Double(threads) },
                        set: { threads = Int($0.rounded()) }
                    ), in: 1...32, step: 1)
                    .tint(YXColor.brand)
                    Text("分片并发上限，越大越快也越吃内存与服务器限流")
                        .font(.yxFootnote)
                        .foregroundStyle(YXColor.tertiaryLabel)
                }
                .padding(.horizontal, YXMetric.cardPadding)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(YXColor.hairline).frame(height: 0.5)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("全局限速")
                            .font(.yxRowTitle)
                            .foregroundStyle(YXColor.label)
                        Spacer()
                        Text(speedLimitText)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(speedLimitKB == 0 ? YXColor.secondaryLabel : YXColor.brand)
                    }
                    Slider(value: Binding(
                        get: { Double(speedLimitKB) },
                        set: { speedLimitKB = Int($0) }
                    ), in: 0...20480, step: 256)
                    .tint(YXColor.brand)
                }
                .padding(.horizontal, YXMetric.cardPadding)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(YXColor.hairline).frame(height: 0.5)
                }

                YXRow(symbol: "trash.slash", tint: YXColor.warning,
                      title: "完成后清理分片",
                      subtitle: "自动删除临时分片文件",
                      isLast: true) {
                    Toggle("", isOn: $autoCleanParts)
                        .labelsHidden()
                        .tint(YXColor.brand)
                }
            }
        }
    }

    // MARK: 存储

    private var storageCard: some View {
        YXSection("存储", footnote: "文件保存在「文件」App → 我的 iPhone → 云析 → Downloads") {
            VStack(spacing: 0) {
                YXRow(symbol: "internaldrive", tint: YXColor.brand,
                      title: "分片缓存",
                      subtitle: YXFormat.bytes(cacheSize),
                      isLast: false) {
                    YXPillButton(title: showCleanDone ? "已清理" : "清理",
                                 symbol: "trash",
                                 tint: showCleanDone ? YXColor.success : YXColor.danger) {
                        cleanCache()
                    }
                }
                YXRow(symbol: "folder", tint: YXColor.success,
                      title: "下载目录",
                      subtitle: "Documents/Downloads",
                      isLast: true) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(YXColor.tertiaryLabel)
                }
            }
        }
    }

    // MARK: 关于

    private var aboutCard: some View {
        YXSection("关于") {
            VStack(spacing: 0) {
                YXRow(symbol: "info.circle", tint: YXColor.brand,
                      title: "版本",
                      subtitle: Self.version,
                      isLast: false) {
                    EmptyView()
                }
                Link(destination: URL(string: "https://github.com/tidain/YunX-Desktop")!) {
                    YXRow(symbol: "chevron.left.forwardslash.chevron.right",
                          tint: Color(yxLight: 0x24292F, dark: 0x8B949E),
                          title: "桌面版源码",
                          subtitle: "tidain/YunX-Desktop",
                          showsChevron: true,
                          isLast: false)
                }
                .buttonStyle(.plain)
                YXRow(symbol: "doc.text", tint: YXColor.tertiaryLabel,
                      title: "开源协议",
                      subtitle: "AGPL-3.0",
                      isLast: true) {
                    EmptyView()
                }
            }
        }
    }

    // MARK: 动作

    private var speedLimitText: String {
        if speedLimitKB <= 0 { return "不限速" }
        if speedLimitKB >= 1024 {
            return String(format: "%.1f MB/s", Double(speedLimitKB) / 1024)
        }
        return "\(speedLimitKB) KB/s"
    }

    private static func partsSize() -> Int64 {
        let dir = YXPaths.parts
        guard let enumerator = FileManager.default.enumerator(at: dir,
                                                              includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    private func cleanCache() {
        let dir = YXPaths.parts
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheSize = Self.partsSize()
        withAnimation(YXMotion.snappy) { showCleanDone = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(YXMotion.gentle) { showCleanDone = false }
        }
    }

    private static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
