# 云析 iOS · YunX-iOS

**粘贴分享链接，直接高速下载 —— [YunX-Desktop](https://github.com/tidain/YunX-Desktop) 的 iOS 原生移植版**

用 SwiftUI 重写了桌面版（Kotlin / Compose Desktop）的界面层与网络层。不是套壳、不是 WebView 包装，是原生 App。

<p align="left">
  <img alt="iOS" src="https://img.shields.io/badge/iOS-17.0%2B-000000?style=flat-square&logo=apple&logoColor=white" />
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-原生-0A84FF?style=flat-square" />
  <img alt="Build" src="https://img.shields.io/badge/GitHub_Actions-自动打包-2088FF?style=flat-square&logo=githubactions&logoColor=white" />
  <img alt="License" src="https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square" />
</p>

---

## 这是什么

[YunX-Desktop](https://github.com/tidain/YunX-Desktop) 是云析的 Windows 桌面端，用 Kotlin + Compose Multiplatform 写的。
iOS 跑不了 JVM，所以这个仓库把它的**协议层逐条翻成 Swift**，把**界面层按 iOS 18 的原生规范重做**。

协议细节（端点、请求头、Cookie 语义、直链判定、412/403 处理）不是猜的，是从桌面版源码逐行对齐的，
包括那几个踩过的坑：

- 分享列表的 `data.list` 与 `data.detail_info.list` 两种形态都要兼容
- `share_fid_token` ≠ `fid_token`，取链 body 里的键名是 `fids_token`
- 转存 body 里 `pdir_fid`（源父目录）和 `to_pdir_fid`（目标目录）不能对调
- 夸克转存后必须用 `save_as_top_fids[0]` 这个新 fid 去取链
- `__puus` 约 3 小时有效，90 分钟惰性刷新一次；取链和下载必须是同一份 Cookie
- 游客态靠 `__pugs`：夸克缺它 CDN 返 **412**，UC 缺它 OSS 返 **403**
- 分片请求返回 **200** 说明服务器忽略了 Range —— 绝不能当分片写盘，整任务回退单流

## 现在能做什么

| 平台 | 解析 | 浏览 | 下载 | 登录 |
|---|---|---|---|---|
| 夸克网盘 | ✅ | ✅ | ✅ 免转存 + 转存兜底 + 游客 | Cookie |
| UC 网盘 | ✅ | ✅ | ✅ 免转存 + 游客 | Cookie |
| 123 云盘 | ✅ | ✅ | ✅ 匿名链路 | 免登录 |
| 百度网盘 | ✅ | ✅ | ✅ locatedownload 选链 | Cookie（BDUSS/BDCLND） |
| 蓝奏云 | ✅ | ✅ | ✅ HTML 抓取 + acw_sc__v2 | 免登录 |
| 蓝奏云优享版 | ✅ | ✅ | ✅ AES-ECB 签名 | 免登录 |
| 光鸭云盘 | ✅ | ✅ | ✅ 设备头 + accessToken | 免登录 |
| 139 网盘 | ✅ | ✅ | ✅ AES-CBC 双层通道 | 免登录 |
| 115 网盘 | ✅ | ✅ | ✅ share/downurl + CDN Cookie | Cookie |
| 迅雷网盘 | ✅ | ✅ | ✅ 设备指纹 + captcha | 游客 / Token |
| GitHub | ✅ | ✅ | ✅ 仓库浏览 + raw 直链 | 可选 Token |

通用能力：

| 能力 | 状态 |
|---|---|
| 分享链接识别（11 个平台的域名规则） | ✅ |
| Range 分片并发 + 断点续传 + 稀疏文件直写 | ✅ |
| 两段式 Range 探测 / HTML 防盗链判定 / 412·403 语义 | ✅ |
| 全局限速、并发数可调、多任务列表 | ✅ |
| WKWebView 登录抓 Cookie / 手动粘贴 Cookie | ✅ |
| 多账号、容量显示、会话刷新 | ✅ |
| P2P（磁力/BT）、视频平台解析、DASH 合轨 | ⏳ 需独立模块 |

> 桌面版的 ffmpeg 预览、Gopeed P2P 引擎、JCEF 内嵌浏览器在 iOS 上都没有对应物。
> 替代路线已在代码注释里标注：预览走 `AVPlayer`，DASH 合轨走 `AVMutableComposition`，登录走 `WKWebView`。

## 界面

原生 iOS 18 观感：大标题导航、inset grouped 分组卡片、SF Symbols、系统级触感。
配色继承桌面版的 Material 3 种子色（`#415F91` 蓝），在 iOS 上提亮一档作为品牌色。
深色 / 浅色全量适配，两套色值都写在 `YXTheme.swift` 里。

## 构建

**不需要 Mac。** 推送到 main 或打 tag，GitHub Actions 会在 macOS runner 上跑完构建并产出 ipa。

```
Actions → Build iOS IPA → Artifacts → YunX-unsigned-ipa
```

打 `v*` tag 会自动创建 Release 并把 ipa 挂上去。

本地构建（需要 macOS + Xcode）：

```bash
brew install xcodegen
xcodegen generate
open YunX.xcodeproj
```

## 安装

Actions 产出 `YunX.ipa`，**已经做过 ad-hoc 签名**（`codesign -s -`）。

这一步不能省：零签名的 Mach-O 会被 iOS 内核直接 `SIGKILL`，表现就是「能装上但点开闪退」。ad-hoc 签名后：

1. **TrollStore** —— 直接装，能跑（最省事，但只支持特定系统版本）
2. **Sideloadly / AltStore / SideStore** —— 用你自己的 Apple ID 重签，免费账号 7 天续签一次
3. **爱思助手等自签工具** —— 同上，选「重签名后安装」

如果你有付费开发者账号，把 `project.yml` 里的 `CODE_SIGN_STYLE` 改成 `Automatic`、
填上 `DEVELOPMENT_TEAM`，再把证书和描述文件传进仓库 Secrets，就能出正式签名包。

### 装上了但闪退？

按顺序排查：

1. **确认是自签安装**。直接把 ipa 拖进爱思助手「安装」而不重签名，几乎必然闪退。
2. **确认设备 iOS ≥ 16.0**（`MinimumOSVersion` 是 16.0）。
3. **抓崩溃日志**：`设置 → 隐私与安全性 → 分析与改进 → 分析数据`，找 `YunX-2026-xx-xx.ips` 开头的条目。
   日志里 `Exception Type` 与 `Termination Reason` 会直接指出原因：
   - `EXC_CRASH (SIGKILL)` + `Code Signature Invalid` → 签名问题，重新自签
   - `EXC_BAD_ACCESS` + 具体栈帧 → 代码问题，把栈贴到 Issue
   - `Killed: 9` 且无栈 → 同样多半是签名或 entitlement

## 项目结构

```
YunX/
├── App/                    应用入口、Info.plist
├── DesignSystem/           色彩 / 排版 / 尺寸 + 通用组件
│   ├── YXTheme.swift
│   └── YXComponents.swift
├── Core/
│   ├── Models/             SharePlatform 等模型
│   ├── Network/            HTTPClient、Cookie（Keychain）、ShareLinkParser
│   ├── Pan/                PanClient（夸克/UC 同构客户端）、ResolveService（编排）
│   ├── Download/           DownloadEngine（分片引擎）、DownloadManager（任务状态机）
│   └── Support/            Keychain 封装
└── Features/
    ├── Resolve/            解析页 + 分享文件浏览
    ├── Drive/              网盘账号
    ├── Download/           下载列表
    ├── Login/              WKWebView 登录
    └── Settings/           设置
```

### 关键设计

**分片引擎**（`DownloadEngine.swift`）
目标文件先 `truncate` 到总长度生成稀疏文件，各分片 `seek` 到自己的偏移直接写 —— 不产生中间副本、
不需要合并、磁盘占用只有一份。每片完成即把 manifest 落盘，强杀进程也能续传。

**写盘串行化**（`ChunkWriter`）
`FileHandle` 的 `seek` + `write` 不是原子操作，多分片并发写同一文件必须串行。所有写盘过一个串行队列，
句柄按 key 缓存，避免每片开关文件的开销。

**Cookie 语义**（`ResolveService.downloadHeaders`）
直链签名绑死「取链那一刻的那份 Cookie」。多账号场景下拿 A 账号的直链配 B 账号的 Cookie，服务端直接 412。

## 与桌面版的关系

协议逻辑源自 [tidain/YunX-Desktop](https://github.com/tidain/YunX-Desktop)（AGPL-3.0），
本项目同样以 AGPL-3.0 开源。两端代码、发布节奏各自独立。

## 免责声明

本项目仅用于**学习与研究**，不提供任何网盘内容，不破解任何付费能力。
所有下载行为都需要用户自己的账号凭证，且受各网盘服务条款约束。
请勿用于商业用途或大规模分发他人分享的内容。

## 开源协议

[GNU AGPL-3.0](LICENSE)
