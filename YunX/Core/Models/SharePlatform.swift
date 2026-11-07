//
//  SharePlatform.swift
//  YunX · 网盘平台枚举与展示元数据
//

import SwiftUI

enum SharePlatform: String, CaseIterable, Identifiable, Codable {
    case quark
    case uc
    case xunlei
    case baidu
    case c139
    case pan123
    case pan115
    case guangya
    case ilanzou
    case lanzou
    case github

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quark:   return "夸克网盘"
        case .uc:      return "UC 网盘"
        case .xunlei:  return "迅雷网盘"
        case .baidu:   return "百度网盘"
        case .c139:    return "139 网盘"
        case .pan123:  return "123 云盘"
        case .pan115:  return "115 网盘"
        case .guangya: return "光鸭云盘"
        case .ilanzou: return "蓝奏云优享版"
        case .lanzou:  return "蓝奏云"
        case .github:  return "GitHub"
        }
    }

    var shortName: String {
        switch self {
        case .quark:   return "夸克"
        case .uc:      return "UC"
        case .xunlei:  return "迅雷"
        case .baidu:   return "百度"
        case .c139:    return "139"
        case .pan123:  return "123"
        case .pan115:  return "115"
        case .guangya: return "光鸭"
        case .ilanzou: return "蓝奏优享"
        case .lanzou:  return "蓝奏"
        case .github:  return "GitHub"
        }
    }

    /// 列表左上的图标方块用色
    var tint: Color { YXColor.platform(rawValue) }

    var symbol: String {
        switch self {
        case .quark:   return "cloud.fill"
        case .uc:      return "cloud.circle.fill"
        case .xunlei:  return "bolt.horizontal.fill"
        case .baidu:   return "cloud.sun.fill"
        case .c139:    return "antenna.radiowaves.left.and.right"
        case .pan123:  return "number.square.fill"
        case .pan115:  return "1.circle.fill"
        case .guangya: return "drop.fill"
        case .ilanzou: return "shippingbox.fill"
        case .lanzou:  return "shippingbox"
        case .github:  return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// 分享链接的 Cookie 域（登录态判定用）
    var cookieDomain: String {
        switch self {
        case .quark:   return ".quark.cn"
        case .uc:      return ".uc.cn"
        case .xunlei:  return ".xunlei.com"
        case .baidu:   return ".baidu.com"
        case .c139:    return ".139.com"
        case .pan123:  return ".123pan.com"
        case .pan115:  return ".115.com"
        case .guangya: return ".guangyapan.com"
        case .ilanzou: return ".ilanzou.com"
        case .lanzou:  return ".lanzou.com"
        case .github:  return ".github.com"
        }
    }
}

/// 解析结果：平台 + shareId + 提取码
struct ParsedShare: Equatable {
    let shareId: String
    let pwd: String?
    let platform: SharePlatform
}
