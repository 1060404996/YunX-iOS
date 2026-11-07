//
//  YXTheme.swift
//  YunX · 设计系统（色彩 / 排版 / 尺寸 / 动效）
//
//  视觉方向：原生 iOS 18 大标题 + inset grouped 分组卡片。
//  取色继承桌面版 Material 3 seed（#415F91 蓝），在 iOS 上提亮一档作为品牌色。
//

import SwiftUI

// MARK: - 基础颜色工具

extension UIColor {
    convenience init(yxHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

extension Color {
    /// 按浅色 / 深色两套 hex 生成动态颜色。
    init(yxLight light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            UIColor(yxHex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

// MARK: - 色彩

enum YXColor {
    /// 页面底色
    static let background = Color(yxLight: 0xF2F2F7, dark: 0x000000)
    /// 卡片 / 分组容器
    static let surface = Color(yxLight: 0xFFFFFF, dark: 0x1C1C1E)
    /// 卡片上的浮起元素（输入框、次级块）
    static let surfaceRaised = Color(yxLight: 0xF7F7FA, dark: 0x2C2C2E)
    /// 分隔线 / 描边
    static let hairline = Color(yxLight: 0xE3E3E8, dark: 0x38383A)
    /// 主文字
    static let label = Color(yxLight: 0x111114, dark: 0xF5F5F7)
    /// 次级文字
    static let secondaryLabel = Color(yxLight: 0x6B6B70, dark: 0x9A9AA0)
    /// 三级文字 / 占位符
    static let tertiaryLabel = Color(yxLight: 0xA5A5AC, dark: 0x6C6C72)

    /// 品牌主色
    static let brand = Color(yxLight: 0x3A6DF0, dark: 0x7FA3FF)
    /// 品牌浅底（用于 tag / 选中态）
    static let brandSoft = Color(yxLight: 0xE9EFFF, dark: 0x16233D)
    /// 品牌深色文字（浅底上的字）
    static let brandOnSoft = Color(yxLight: 0x2149B8, dark: 0xA9C2FF)

    static let success = Color(yxLight: 0x1FA84E, dark: 0x32D74B)
    static let warning = Color(yxLight: 0xD97706, dark: 0xFF9F0A)
    static let danger = Color(yxLight: 0xD92D20, dark: 0xFF453A)

    /// 品牌渐变（主按钮 / 强调块）
    static let brandGradient = LinearGradient(
        colors: [Color(yxLight: 0x4C7DF5, dark: 0x6F97FF),
                 Color(yxLight: 0x2E5BD8, dark: 0x4B78F0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 各网盘品牌色（图标方块底色）
    static func platform(_ id: String) -> Color {
        switch id {
        case "quark":    return Color(yxLight: 0x2F6BFF, dark: 0x5A8BFF)
        case "uc":       return Color(yxLight: 0xFF7A1A, dark: 0xFF9A45)
        case "xunlei":   return Color(yxLight: 0x3D8BFF, dark: 0x6BA6FF)
        case "baidu":    return Color(yxLight: 0x2B62F5, dark: 0x5C87FF)
        case "c139":     return Color(yxLight: 0x00A0E9, dark: 0x3FBDFF)
        case "pan123":   return Color(yxLight: 0xF04E4E, dark: 0xFF6B6B)
        case "pan115":   return Color(yxLight: 0x27A567, dark: 0x3FCB85)
        case "guangya":  return Color(yxLight: 0x6C5CE7, dark: 0x9589FF)
        case "lanzou":   return Color(yxLight: 0x1FA37A, dark: 0x3FCBA0)
        case "ilanzou":  return Color(yxLight: 0x0E9F6E, dark: 0x2FC894)
        case "github":   return Color(yxLight: 0x24292F, dark: 0x8B949E)
        case "magnet":   return Color(yxLight: 0x8E44AD, dark: 0xB07CD6)
        default:         return Color(yxLight: 0x6B7280, dark: 0x8B93A1)
        }
    }
}

// MARK: - 尺寸

enum YXMetric {
    /// 卡片圆角
    static let cardRadius: CGFloat = 16
    /// 控件圆角
    static let controlRadius: CGFloat = 12
    /// 图标方块圆角
    static let iconRadius: CGFloat = 10
    /// 页面左右留白（与系统 insetGrouped 对齐）
    static let pagePadding: CGFloat = 16
    /// 卡片内边距
    static let cardPadding: CGFloat = 14
    /// 卡片间距
    static let sectionGap: CGFloat = 18
    /// 图标方块边长
    static let iconSize: CGFloat = 30
    /// 行高
    static let rowMinHeight: CGFloat = 48
}

// MARK: - 排版

extension Font {
    /// 页面大标题（配合 NavigationStack 的 large title 使用）
    static let yxLargeTitle = Font.system(size: 32, weight: .bold, design: .default)
    /// 卡片区标题
    static let yxSectionTitle = Font.system(size: 13, weight: .semibold, design: .default)
    /// 行主文字
    static let yxRowTitle = Font.system(size: 16, weight: .regular, design: .default)
    /// 行主文字（强调）
    static let yxRowTitleStrong = Font.system(size: 16, weight: .semibold, design: .default)
    /// 次级说明
    static let yxCaption = Font.system(size: 13, weight: .regular, design: .default)
    /// 极小标注
    static let yxFootnote = Font.system(size: 11.5, weight: .regular, design: .default)
    /// 数字（等宽，用于速度 / 大小）
    static let yxMono = Font.system(size: 13, weight: .medium, design: .monospaced)
    /// 大号数字
    static let yxMonoLarge = Font.system(size: 20, weight: .semibold, design: .monospaced)
}

// MARK: - 动效

enum YXMotion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let gentle = Animation.easeInOut(duration: 0.22)
    static let pop = Animation.spring(response: 0.42, dampingFraction: 0.7)
}

// MARK: - 通用修饰

extension View {
    /// 页面底色铺满（含安全区）
    func yxPageBackground() -> some View {
        self.background(YXColor.background.ignoresSafeArea())
    }

    /// 卡片外观
    func yxCardSurface(radius: CGFloat = YXMetric.cardRadius) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(YXColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(YXColor.hairline, lineWidth: 0.5)
            )
    }

    /// 轻触反馈
    func yxPressable() -> some View {
        self.buttonStyle(YXPressableStyle())
    }
}

struct YXPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(YXMotion.snappy, value: configuration.isPressed)
    }
}
