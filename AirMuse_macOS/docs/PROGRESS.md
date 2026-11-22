# AirMuse macOS — 工程进度跟踪

> 最后更新：2026-11-21

## 编译与测试状态

| 指标 | 状态 |
|------|------|
| `swift build` | ✅ Build complete（0 errors） |
| `swift test` | ✅ 16/16 passed（0 failures） |
| Swift 版本 | Swift 6.4.2 (swiftlang-6.4.2.1.9) |
| 目标 SDK | MacOSX27.2 (macOS 26 Tahoe+) |
| 源文件总数 | 56 个 `.swift` 文件 |
| 源代码行数 | ~14,323 行 |

---

## 阶段里程碑

### ✅ 阶段 1 — 源码审计
- [x] 阅读 AirMuse_Remastered Windows 工程结构
- [x] 分析 airplay 交互规范（双击折叠、鼠标悬停、玻璃边框）
- [x] 生成 `docs/01-source-audit.md`

### ✅ 阶段 2 — 领域模型（Domain）
- [x] MusicTrack（含账户隔离 trackKey）
- [x] MusicAlbum / MusicArtist / MusicPlaylist / MusicStation
- [x] MusicLibrary / MusicAccount / MusicSource
- [x] MusicProviderCapabilities / MusicSearchResult
- [x] PlaybackSession / PlaybackState / PlaybackQueue
- [x] LyricsDocument / LyricsLine
- [x] 协议：MusicCatalogProvider / MusicLibraryProvider / MusicSearchProvider
- [x] 协议：MusicPlaybackProvider / MusicAuthenticationProvider / MusicLyricsProvider

### ✅ 阶段 3 — 播放核心（Playback）
- [x] PlaybackStore（Actor 隔离，AsyncStream 广播）
- [x] PlaybackCoordinator（提供商注册、会话管理、所有控制命令）
- [x] MediaArbitrator（优先级与活跃播放评分）

### ✅ 阶段 4 — 歌词引擎（Lyrics）
- [x] LyricsEngine（提供商注册、定时获取、偏移管理、SQLite 缓存）

### ✅ 阶段 5 — 设计系统（DesignSystem）
- [x] DesignTokens（尺寸 330×106/40/240/380、色彩、字体）
- [x] MotionCoordinator（snappy/bouncy/smooth/gentle 弹簧物理）
- [x] GlassSurface / GlassButton / GlassToolbar / GlassPanel / GlassSearchField
- [x] GlassMiniPlayer（40pt 胶囊悬浮控件）

### ✅ 阶段 6 — UI 层
- [x] PlayerView（330×106 主播放器，作品图、标题、滑块、控制按钮）
- [x] MiniPlayerView（330×40 胶囊微型播放器，跑马灯文字）
- [x] PlayerWindow / PlayerWindowController（双击折叠、弹簧动画）
- [x] LyricsView / LyricsWindow（逐行高亮、偏移控制）
- [x] LibrarySidebarView / LibraryContentView / SearchBarView
- [x] LibraryWindow / LibraryWindowController
- [x] DockManager（多窗口磁吸对接，16pt 阈值）

### ✅ 阶段 7 — 基础设施（Infrastructure）
- [x] SQLiteStore（WAL 模式，歌词缓存、历史、设置）
- [x] ImageCache（内存 ≤50MB + 磁盘缓存）
- [x] NetworkSession（URLSession Actor 包装，重试，超时）
- [x] KeychainStore（OAuth Token 安全存储）
- [x] WebKit/BridgeMessage & WebViewManager（安全 JS 消息桥）

### ✅ 阶段 8 — 音乐平台 Providers
- [x] AppleMusicProvider（MusicKit + Amp-API 官方 Web 直连引擎双驱动）
- [x] AppleMusicAmpClient（免开发者账号直连 Apple Amp-API，全球榜单/新发现/搜索/歌单）
- [x] SpotifyProvider（PKCE OAuth + WKWebView Web Playback SDK）
- [x] QQMusicProvider（WKWebView 页面桥接 + 兼容检测）

### ✅ 阶段 9 — 应用入口（App）
- [x] AppDelegate（初始化全部组件、连接 AsyncStream）
- [x] main.swift（NSApplication 入口）
- [x] 全局与局部退出控件（主播放器退出按钮、迷你播放器退出按钮、右键上下文菜单 ⌘Q）

### ✅ 阶段 10 — 测试
- [x] DomainTests（3 tests）：trackKey、queue advance、lyrics activeLine
- [x] PlaybackTests（2 tests）：store state update、artwork preservation
- [x] UnitTests/LyricsParserTests（4 tests）：LRC 时间戳解析
- [x] UnitTests/CacheKeyTests（7 tests）：账户隔离、provider 隔离

---

## 架构总览

```
Domain ──┬── Playback ──┬── Lyrics
         │              └── Providers
         └── Infrastructure
                 │
         DesignSystem ── UI ── App
```

- **单向状态流**：PlaybackStore → PlaybackCoordinator → UI
- **协议驱动**：每个 Provider 只声明其支持的能力（`MusicProviderCapabilities`）
- **并发安全**：全程 Swift 6 strict concurrency（actor isolation + Sendable）
- **窗口设计**：迷你悬浮体验（40pt）是产品核心，展开后才是完整客户端

---

## 已知限制

| 项目 | 说明 |
|------|------|
| Apple Music 歌词 | MusicKit 公开 API 暂不提供歌词，抛出 `LyricsError.notSupported` |
| Spotify 播放 | 受 Web Playback SDK DRM 限制，需用户提供 Client ID |
| QQ 音乐 DOM | 依赖 y.qq.com 页面结构，页面更新需更新 JS bridge 检测脚本 |
| Metal 渲染 | 当前未引入，NSVisualEffectView 覆盖 Liquid Glass 需求 |
| `xcodebuild` | 仅 CLT 环境，不支持 `.xcodeproj`；使用 SPM `swift build/test` |
