//
//  DownloadView.swift
//  YunX · 下载列表
//

import SwiftUI
import QuickLook

struct DownloadView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var filter: Filter = .active
    @State private var previewURL: URL?

    enum Filter: Hashable, CaseIterable {
        case active, done
        var title: String { self == .active ? "进行中" : "已完成" }
    }

    private var visibleItems: [DownloadItem] {
        switch filter {
        case .active:
            return downloads.items.filter { $0.state != .completed }
        case .done:
            return downloads.items.filter { $0.state == .completed }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YXMetric.sectionGap) {
                    YXSegmented(items: Filter.allCases, title: { $0.title }, selection: $filter)

                    if filter == .active {
                        speedCard
                    }

                    if visibleItems.isEmpty {
                        YXEmptyState(symbol: filter == .active ? "tray" : "checkmark.circle",
                                     title: filter == .active ? "没有进行中的任务" : "还没有完成的任务",
                                     message: filter == .active ? "去解析页粘贴一个分享链接试试" : nil)
                    } else {
                        ForEach(visibleItems) { item in
                            card(item)
                        }
                    }
                }
                .padding(.horizontal, YXMetric.pagePadding)
                .padding(.bottom, 28)
            }
            .yxPageBackground()
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("清空已完成", systemImage: "trash") {
                            downloads.clearCompleted()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .quickLookPreview($previewURL)
        }
    }

    // MARK: 速度条

    private var speedCard: some View {
        YXGroupCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(YXColor.hairline, lineWidth: 5)
                        .frame(width: 46, height: 46)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(YXColor.brand)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(YXFormat.speed(downloads.totalSpeed))
                        .font(.yxMonoLarge)
                        .foregroundStyle(YXColor.label)
                    Text("实时总速度")
                        .font(.yxFootnote)
                        .foregroundStyle(YXColor.secondaryLabel)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(downloads.items.filter { $0.state == .running }.count)")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(YXColor.label)
                    Text("进行中")
                        .font(.yxFootnote)
                        .foregroundStyle(YXColor.secondaryLabel)
                }
            }
            .padding(YXMetric.cardPadding)
        }
    }

    // MARK: 任务卡

    private func card(_ item: DownloadItem) -> some View {
        YXGroupCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    YXIconTile(symbol: item.state.symbol,
                               tint: item.state.tint,
                               size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.filename)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(YXColor.label)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(item.platform.shortName)
                                .font(.yxFootnote)
                                .foregroundStyle(YXColor.tertiaryLabel)
                            Text("·")
                                .foregroundStyle(YXColor.tertiaryLabel)
                            Text(item.state.label)
                                .font(.yxFootnote)
                                .foregroundStyle(item.state.tint)
                        }
                    }
                    Spacer(minLength: 0)
                    menu(item)
                }

                if item.state != .completed {
                    YXProgressBar(value: item.progress, tint: item.state.tint)
                    HStack(spacing: 6) {
                        Text("\(YXFormat.bytes(item.downloadedBytes)) / \(item.totalBytes > 0 ? YXFormat.bytes(item.totalBytes) : "未知")")
                            .font(.yxMono)
                            .foregroundStyle(YXColor.secondaryLabel)
                        Spacer(minLength: 0)
                        if item.state == .running {
                            Text(YXFormat.speed(item.avgSpeed))
                                .font(.yxMono)
                                .foregroundStyle(YXColor.brand)
                        } else {
                            Text("\(Int(item.progress * 100))%")
                                .font(.yxMono)
                                .foregroundStyle(YXColor.tertiaryLabel)
                        }
                    }
                }

                if let error = item.errorMessage, item.state == .failed {
                    Text(error)
                        .font(.yxFootnote)
                        .foregroundStyle(YXColor.danger)
                        .lineLimit(3)
                }

                actionRow(item)
            }
            .padding(YXMetric.cardPadding)
        }
    }

    private func menu(_ item: DownloadItem) -> some View {
        Menu {
            if item.state == .running {
                Button("暂停", systemImage: "pause") { downloads.pause(item.id) }
            }
            if item.state == .paused || item.state == .failed {
                Button("继续", systemImage: "play") { downloads.start(item.id) }
            }
            if item.state == .failed {
                Button("重新下载", systemImage: "arrow.clockwise") { downloads.retry(item.id) }
            }
            Button("删除任务", systemImage: "trash", role: .destructive) {
                downloads.remove(item.id, deleteFile: item.state != .completed)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(YXColor.tertiaryLabel)
                .frame(width: 30, height: 30)
                .background(Circle().fill(YXColor.surfaceRaised))
        }
    }

    @ViewBuilder
    private func actionRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 8) {
            if item.state == .running {
                YXPillButton(title: "暂停", symbol: "pause.fill", tint: YXColor.warning) {
                    downloads.pause(item.id)
                }
            } else if item.state == .paused {
                YXPillButton(title: "继续", symbol: "play.fill", tint: YXColor.brand) {
                    downloads.start(item.id)
                }
            } else if item.state == .failed {
                YXPillButton(title: "重试", symbol: "arrow.clockwise", tint: YXColor.danger) {
                    downloads.retry(item.id)
                }
            }
            if item.state == .completed, let path = item.localPath {
                YXPillButton(title: "预览", symbol: "eye", tint: YXColor.brand) {
                    previewURL = URL(fileURLWithPath: path)
                }
                ShareLink(item: URL(fileURLWithPath: path)) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                        Text("分享")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(YXColor.brand)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(YXColor.brand.opacity(0.12)))
                }
            }
            Spacer(minLength: 0)
            if item.state != .completed && item.state == .running {
                Text("\(Int(item.progress * 100))%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(YXColor.label)
            }
        }
    }
}
