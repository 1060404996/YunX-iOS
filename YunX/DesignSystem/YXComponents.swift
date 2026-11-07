//
//  YXComponents.swift
//  YunX · 通用 UI 组件
//

import SwiftUI

// MARK: - 分组卡片

/// 白色圆角容器，内部放 YXRow。
struct YXGroupCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .yxCardSurface()
    }
}

// MARK: - 区段（标题 + 卡片）

struct YXSection<Content: View>: View {
    private let title: String?
    private let footnote: String?
    private let content: Content

    init(_ title: String? = nil, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.yxSectionTitle)
                    .foregroundStyle(YXColor.secondaryLabel)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
            }
            YXGroupCard { content }
            if let footnote {
                Text(footnote)
                    .font(.yxFootnote)
                    .foregroundStyle(YXColor.tertiaryLabel)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - 图标方块

struct YXIconTile: View {
    let symbol: String
    var tint: Color = YXColor.brand
    var size: CGFloat = YXMetric.iconSize

    var body: some View {
        RoundedRectangle(cornerRadius: YXMetric.iconRadius, style: .continuous)
            .fill(tint.opacity(0.14))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(tint)
            )
    }
}

// MARK: - 行

struct YXRow<Trailing: View>: View {
    private let symbol: String?
    private let tint: Color
    private let title: String
    private let subtitle: String?
    private let showsChevron: Bool
    private let isLast: Bool
    private let trailingBuilder: () -> Trailing

    init(symbol: String? = nil,
         tint: Color = YXColor.brand,
         title: String,
         subtitle: String? = nil,
         showsChevron: Bool = false,
         isLast: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.showsChevron = showsChevron
        self.isLast = isLast
        self.trailingBuilder = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                YXIconTile(symbol: symbol, tint: tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.yxRowTitle)
                    .foregroundStyle(YXColor.label)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.yxCaption)
                        .foregroundStyle(YXColor.secondaryLabel)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailingBuilder()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YXColor.tertiaryLabel)
            }
        }
        .padding(.horizontal, YXMetric.cardPadding)
        .frame(minHeight: YXMetric.rowMinHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(YXColor.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, symbol == nil ? YXMetric.cardPadding : YXMetric.cardPadding + YXMetric.iconSize + 12)
            }
        }
    }
}

extension YXRow where Trailing == EmptyView {
    init(symbol: String? = nil,
         tint: Color = YXColor.brand,
         title: String,
         subtitle: String? = nil,
         showsChevron: Bool = false,
         isLast: Bool = false) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle,
                  showsChevron: showsChevron, isLast: isLast, trailing: { EmptyView() })
    }
}

// MARK: - 按钮

struct YXPrimaryButton: View {
    let title: String
    var symbol: String?
    var isLoading: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.85)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(YXColor.brandGradient)
            )
            .opacity(enabled ? 1 : 0.45)
        }
        .yxPressable()
        .disabled(!enabled || isLoading)
    }
}

struct YXSecondaryButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(YXColor.brand)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(YXColor.brandSoft)
            )
        }
        .yxPressable()
    }
}

/// 小圆片按钮（行内操作）
struct YXPillButton: View {
    let title: String
    var symbol: String?
    var tint: Color = YXColor.brand
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.12)))
        }
        .yxPressable()
    }
}

// MARK: - 标签

struct YXBadge: View {
    let text: String
    var tint: Color = YXColor.brand

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.13)))
    }
}

// MARK: - 空状态

struct YXEmptyState: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(YXColor.tertiaryLabel)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(YXColor.secondaryLabel)
            if let message {
                Text(message)
                    .font(.yxCaption)
                    .foregroundStyle(YXColor.tertiaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 进度条

struct YXProgressBar: View {
    var value: Double          // 0...1
    var tint: Color = YXColor.brand
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(YXColor.hairline)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 顶部胶囊分段

struct YXSegmented<T: Hashable>: View {
    let items: [T]
    let title: (T) -> String
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    withAnimation(YXMotion.snappy) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? YXColor.label : YXColor.secondaryLabel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(YXColor.surface)
                                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(YXColor.surfaceRaised)
        )
    }
}

// MARK: - 输入框

struct YXTextField: View {
    let placeholder: String
    @Binding var text: String
    var symbol: String? = "link"
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int> = 1...4

    var body: some View {
        HStack(alignment: axis == .vertical ? .top : .center, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(YXColor.tertiaryLabel)
                    .padding(.top, axis == .vertical ? 3 : 0)
            }
            TextField(placeholder, text: $text, axis: axis)
                .font(.system(size: 16))
                .foregroundStyle(YXColor.label)
                .lineLimit(lineLimit)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(YXColor.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(YXColor.hairline, lineWidth: 0.5)
        )
    }
}

// MARK: - 格式化

enum YXFormat {
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        return String(format: i == 0 ? "%.0f %@" : "%.2f %@", v, units[i])
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < 86400 * 9 else { return "—" }
        let s = Int(seconds)
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 小时 \((s % 3600) / 60) 分"
    }
}
