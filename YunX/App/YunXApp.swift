//
//  YunXApp.swift
//  YunX · 应用入口
//

import SwiftUI

@main
struct YunXApp: App {
    @StateObject private var downloads = DownloadManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(downloads)
                .tint(YXColor.brand)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var tab: Int = 0

    var body: some View {
        TabView(selection: $tab) {
            ResolveView()
                .tabItem { Label("解析", systemImage: tab == 0 ? "link.circle.fill" : "link.circle") }
                .tag(0)

            DriveView()
                .tabItem { Label("网盘", systemImage: tab == 1 ? "cloud.fill" : "cloud") }
                .tag(1)

            DownloadView()
                .tabItem { Label("下载", systemImage: tab == 2 ? "arrow.down.circle.fill" : "arrow.down.circle") }
                .badge(downloads.items.filter { $0.state == .running }.count)
                .tag(2)

            SettingsView()
                .tabItem { Label("设置", systemImage: tab == 3 ? "gearshape.fill" : "gearshape") }
                .tag(3)
        }
    }
}
