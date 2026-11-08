//
//  ShareBrowserView.swift
//  YunX · 分享文件浏览与下载
//

import SwiftUI

struct ShareBrowserView: View {
    let session: ShareSession

    @EnvironmentObject private var downloads: DownloadManager
    @State private var dirStack: [String] = ["0"]
    @State private var files: [ShareFileItem] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var busyFid: String?
    @State private var toast: String?

    private var currentDir: String { dirStack.last ?? "0" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YXMetric.sectionGap) {
                headerCard

                if let errorText {
                    YXGroupCard {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(YXColor.danger)
                            Text(errorText)
                                .font(.yxCaption)
                                .foregroundStyle(YXColor.label)
                            Spacer(minLength: 0)
                            YXPillButton(title: "重试", symbol: "arrow.clockwise") { load() }
                        }
                        .padding(YXMetric.cardPadding)
                    }
                }

                if isLoading && files.isEmpty {
                    YXGroupCard {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取目录…")
                                .font(.yxCaption)
                                .foregroundStyle(YXColor.secondaryLabel)
                        }
                        .padding(YXMetric.cardPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if files.isEmpty && !isLoading {
                    YXEmptyState(symbol: "folder",
                                 title: "这个文件夹是空的",
                                 message: "换个目录，或确认分享链接是否仍然有效")
                } else {
                    fileList
                }
            }
            .padding(.horizontal, YXMetric.pagePadding)
            .padding(.bottom, 28)
        }
        .yxPageBackground()
        .navigationTitle(session.title.isEmpty ? "分享内容" : session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if dirStack.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dirStack.removeLast()
                        load()
                    } label: {
                        Label("上一级", systemImage: "chevron.left")
                    }
                }
            }
        }
        .task { load() }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(.black.opacity(0.78)))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: 头部

    private var headerCard: some View {
        YXGroupCard {
            HStack(spacing: 12) {
                YXIconTile(symbol: session.platform.symbol,
                           tint: session.platform.tint,
                           size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.platform.displayName)
                        .font(.yxRowTitleStrong)
                        .foregroundStyle(YXColor.label)
                    Text(PanTool.hasCredential(session.platform)
                         ? "登录态 · 免转存直取"
                         : "游客态 · 大文件需登录")
                        .font(.yxFootnote)
                        .foregroundStyle(YXColor.secondaryLabel)
                }
                Spacer(minLength: 0)
                Text("\(files.count) 项")
                    .font(.yxMono)
                    .foregroundStyle(YXColor.tertiaryLabel)
            }
            .padding(YXMetric.cardPadding)
        }
    }

    // MARK: 列表

    private var fileList: some View {
        YXGroupCard {
            VStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.element.id) { idx, file in
                    row(file, isLast: idx == files.count - 1)
                }
            }
        }
    }

    private func row(_ file: ShareFileItem, isLast: Bool) -> some View {
        // 此前整行是 Button，label 内又嵌了「下载」Button，SwiftUI 的外层
        // hit-test 会吞掉内层点击，导致文件行的下载按钮点不动。
        // 改成普通容器 + onTapGesture 只负责进目录，下载 pill 是唯一的 Button。
        YXRow(symbol: iconName(for: file),
              tint: file.isDir ? YXColor.brand : colorFor(file.name),
              title: file.name,
              subtitle: file.isDir ? "文件夹" : YXFormat.bytes(file.size),
              isLast: isLast) {
            if file.isDir {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YXColor.tertiaryLabel)
            } else if busyFid == file.fid {
                ProgressView().scaleEffect(0.8)
            } else {
                YXPillButton(title: "下载", symbol: "arrow.down") {
                    enqueue(file)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard file.isDir else { return }
            dirStack.append(file.fid)
            load()
        }
    }

    private func iconName(for file: ShareFileItem) -> String {
        if file.isDir { return "folder.fill" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "ts", "flv", "m4v": return "play.rectangle.fill"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp": return "photo.fill"
        case "mp3", "flac", "wav", "aac", "m4a", "ogg": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        case "apk", "ipa", "exe", "dmg": return "shippingbox.fill"
        case "txt", "md", "json", "xml", "csv": return "doc.text.fill"
        default: return "doc.fill"
        }
    }

    private func colorFor(_ name: String) -> Color {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "ts", "flv": return Color(yxLight: 0xE0554B, dark: 0xFF7A70)
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return Color(yxLight: 0x2FA36B, dark: 0x4FD39A)
        case "mp3", "flac", "wav", "aac", "m4a": return Color(yxLight: 0xB560D0, dark: 0xD48DF0)
        case "zip", "rar", "7z", "tar", "gz": return Color(yxLight: 0xD99325, dark: 0xF0B44C)
        default: return YXColor.brand
        }
    }

    // MARK: 动作

    private func load() {
        isLoading = true
        errorText = nil
        let session = self.session
        let dir = currentDir
        Task {
            do {
                let list = try await ResolveService.listFiles(session: session, dirFid: dir)
                await MainActor.run {
                    files = list.sorted { a, b in
                        if a.isDir != b.isDir { return a.isDir }
                        return a.name.localizedStandardCompare(b.name) == .orderedAscending
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func enqueue(_ file: ShareFileItem) {
        guard busyFid == nil else { return }
        busyFid = file.fid
        let session = self.session
        Task {
            do {
                let resolved = try await ResolveService.resolveDownload(session: session, file: file)
                await MainActor.run {
                    downloads.enqueue(resolved)
                    busyFid = nil
                    withAnimation(YXMotion.snappy) { toast = "已加入下载队列" }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation(YXMotion.gentle) { toast = nil }
                    }
                }
            } catch {
                await MainActor.run {
                    busyFid = nil
                    withAnimation(YXMotion.snappy) { toast = error.localizedDescription }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        withAnimation(YXMotion.gentle) { toast = nil }
                    }
                }
            }
        }
    }
}
