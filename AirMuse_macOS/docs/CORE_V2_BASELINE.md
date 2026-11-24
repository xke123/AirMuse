# AirMuse Core V2 — 初步源码基线

审计范围：https://github.com/xke123/AirMuse/tree/main/AirMuse_macOS
依据：重构讨论中对 main 分支实际源码的静态读取，日期 2026-11-24。未固定 commit SHA，未运行构建、测试、真实登录、实际音频及性能测量。以下源码观察需 P0-01 在当前 HEAD 复核；风险为静态推导，不代表已复现故障。

## 1. 启动及依赖
`Sources/App/main.swift` → `AppDelegate.applicationDidFinishLaunching` → `AppLifecycleCoordinator.launch`。设置 accessory 模式，展示 Logo，构建 Player/Library/Auth/Lyrics/Log/UnifiedStage，将 WebPlayer 关联 playerSlotView。独立 Task 执行 restoreSessionFromStorage，另一 Task 预解码皮肤、注册媒体控制和状态观察，初始化核心服务，至少等待两秒再展示主界面。两个任务在 MainActor 上；同步资源解码可能阻塞。网络恢复不直接阻塞 Logo，但核心服务初始化会延后展示。

## 2. 账户及凭据
`Providers/AppleMusic/Session/AppleMusicSessionModels.swift` 区分 WebSessionState 与 APIAuthorizationState。`AppleMusicSessionAdapter.swift` 实际 Web Adapter 调用 Manager/Player；MusicKit Adapter 多处返回空值或 false，不能据此声称完整原生支持。`AppleMusicProvider` 另有原生 MusicKit 尝试路径，真实能力待验证。

`AppleMusicSessionManager.restoreSessionFromStorage` 优先读 AppPrivateStore 的 developer_token/media_user_token/storefront_id，缺用户凭据时读取持久化 WebKit Cookie，再迁移旧 UserDefaults。双凭据存在时乐观构建 MusicAccount，随机 UUID、individual 订阅类型，向 AmpClient 与 WebPlayer 同步后发布 loggedIn，再静默验证。只有用户凭据时进入 verifying 并尝试获取客户端凭据；无用户凭据返回 loggedOut。账户身份及订阅类型未由服务端可靠确认。

首次登录：`UI/Auth/AppleMusicAuthWindowController` → `startLogin` → 官方 login WebView → Cookie Observer/网页授权结果 → `verifyAndApplyToken` → AmpClient `/v1/me/storefront` 验证 → 保存凭据 → 同步播放器 → 通知 UI。该接口验证 storefront，不等同于个人昵称或付费订阅确认；attributes.name 被用作 accountName，存在语义错误。使用持久 WebKit 数据域；来源校验、回调生命周期须复核。

`Infrastructure/AppPrivateStore.swift` 默认 `~/Library/Application Support/AirMuse/Security/session_vault.json`，JSON+NSLock+内存缓存+原子写入，尝试目录 0700、文件 0600 和系统保护选项。不是 Keychain 等价加密；同用户进程威胁须评估。存在 KeychainStore 但 Manager 默认注入 AppPrivateStore。AmpClient 和 WebKit 另持凭据副本。

## 3. 退出、过期、切换
`signOut` 递增 generation、设置 AmpClient active generation、取消验证任务、清用户凭据及账户/地区、reset WebPlayer、清理 Apple 相关网站数据、发布 loggedOut。`switchAccount` 先 signOut 后 startLogin；`resetSession` 额外清客户端凭据及登录 WebView。`handleTokenExpiration` 清账户与部分凭据并发布 expired，但方法中无 generation 递增、WebPlayer reset 或网站数据清理，且未明确清 AmpClient developerToken。Cookie 观察者仍可能读取旧凭据；恢复及探针回调中存在完成时读取当前 generation 的路径。退出与失效逻辑不一致，须进行可控乱序测试。域名 contains 判断非严格来源校验。

## 4. 音乐数据、网络与缓存
`UI/Library/LibraryWindowController.loadCurrentCategory` → `fetchItems` → `AppleMusicProvider` → `AppleMusicAmpClient.execute` → URLSession → Domain 模型 → `displayItems`。分类任务取消并核对 tab/category；失败时显示空列表和错误标题。AmpClient 提供公开目录/搜索、个人库、推荐、收藏、歌词、ID 映射等接口；有部分 generation 校验及重试逻辑。客户端凭据存在即复用，完整失效更新策略待审计。部分方法存在错误/空结果回退到无关数据（个人歌曲→排行榜，收藏→普通库）。有 limit 参数，分页完整性尚未验证。网页内部接口长期稳定性不确定。

| 缓存 | 已观察实现 | 风险/待查 |
|---|---|---|
| LibraryCacheStore | `~/Library/Caches/AirMuse/catalog_categories_v1.json`，tab index 键，异步串行原子写，启动同步读 | 个人推荐与公开数据混存；账户/地区/TTL 缺失；旧写入竞态 |
| ImageCache | NSCache 约 50MB 成本配置，URL+尺寸键，磁盘 PNG | 磁盘容量、并发合并、解码隔离需核实 |
| LyricsEngine | 内存字典缓存、偏移及状态订阅 | 实际 SQLite 持久化接入需核实 |
| SQLiteStore | 歌词、历史、设置基础设施 | 文件存在不等于生产已接入 |
| Provider/AmpClient | 歌曲 ID 映射内存缓存 | 账户/地区隔离与失效策略需核实 |
| WebKit | 持久网站数据 | 退出、崩溃、跨会话隔离 |

LibraryWindowController 在 loggedOut/expired 通知中清分类缓存，在 loggedIn 后刷新。因为清理发生于 UI 观察者，并非统一会话事务，需核实旧任务能否再次写入。首屏同步读取磁盘可能影响启动。没有完整的音频离线缓存能力声明。

## 5. 播放与事件
`LibraryWindowController.handleItemClicked` → `PlaybackCoordinator.playTrack` → 递增 playGeneration、发布 optimistic loading → Provider → WebSessionAdapter → `AppleMusicWebPlayer.playSong`（或 station/playlist/album）→ WebKit JS MusicKit 实例 → setQueue/play → 事件桥接 → Provider AsyncStream → Coordinator → PlaybackStore → 原生 UI/歌词/媒体中心。

Provider 在 Web 已登录时走完整 Web 播放路径，失败不静默降级 30 秒试听；未登录尝试原生授权路径后可提示登录。个人资料库歌曲 ID 映射存在缓存；播放路径部分调用未明确携带 session generation。`AppleMusicWebPlayer` 约 949 行，负责 WebView、授权同步、桥接、播放、就绪和事件状态。WebView 100x100、alpha 0.01，挂载活动原生视图维持生命周期。实际运行资源包括 WebKit 子进程，不等于可执行文件体积。

播放等待：页面 readiness 等待约 4s；最多 24 次尝试、每次约 200ms 间隔；JS play Promise 竞速等待约 1.5s，不是统一端到端 deadline。指令返回成功与播放开始不同。hasStartedAudio、isBuffering、position 等字段用于推断有效播放事件，并非物理音频输出测量。Swift 和 JS 存在 operation/generation 防护，但旧 setQueue/play 副作用是否被完全串行化与校正需验证。系统媒体命令与自动结束回调通过 Coordinator；队列所有权、电台行为、暂停/seek 与旧命令竞态需深入验证。

## 6. 歌词与资源
LyricsEngine 观察 PlaybackStore 当前歌曲、查询内存缓存、Provider 获取 TTML 或公共/网易云来源回退、解析并更新歌词。生命周期管理器约 100ms 更新歌词位置。旧歌词、封面结果隔离和持久化实际接入待核实。`AppLifecycleCoordinator.shutdown` 取消启动任务并调用 Coordinator shutdown；全部观察者、WebKit、缓存和快照退出生命周期需运行验证。

## 7. 初步风险优先级
| 级别 | 风险 | 验证方式 |
|---|---|---|
| P0 | 退出与过期不统一；旧 Cookie/异步结果复活 | 延迟验证、退出、乱序 Cookie 回调 |
| P0 | Session generation 未覆盖最终写入与引擎 | A→B 切换同时旧请求/播放/缓存返回 |
| P0 | HTTP 授权、Web 授权与 UI 状态不一致 | 有效目录授权、引擎未授权、恢复场景 |
| P0 | 连续切歌真实副作用竞态 | 模拟 A/B/C setQueue 与 play 乱序完成 |
| P1 | 私有缓存无账户地区隔离 | A 缓存后 B 登录/离线启动 |
| P1 | 凭据更新机制、账户身份与订阅真实性 | 失效客户端凭据、并发刷新、未知订阅 |
| P1 | 个人数据错误回退/分页不完整 | 资料库错误/空、超过默认 limit |
| P1 | 敏感日志及凭据文件保护 | 日志/磁盘/桥接安全审计 |
| P2 | 主线程同步 I/O、强制 Logo 等待、资源预算 | Instruments、signpost、长时间使用 |

## 8. P0 运行基线采集要求
实际记录 commit SHA、分支、未提交文件、macOS 与硬件、Swift/Xcode、构建入口。先检查 README/Package.swift/脚本，再执行适用命令（如 `cd AirMuse_macOS && swift build && swift test`，以实际目标为准）。保留失败输出摘要并区分环境问题。对启动、会话恢复、冷/热引擎首播、UI 反馈、缓存命中、网络请求、CPU、主进程及 WebKit 内存采样；建议每类延迟至少 20 次同条件样本并报告 P50/P95 与失败率。真实账户由用户在官方 UI 授权，不采集密码/Token。视觉回归保留主播放器、MiniPlayer、音乐库、歌词与 Liquid Glass 参考。所有结果写入 PROGRESS。

当前基线状态：静态观察已整理；构建、测试、运行、性能、视觉和真实账户验证均尚未完成。不得将本文件作为已通过测试的证明。

## 9. P0-01 / P0-02 / P0-03 实机源码与构建基线复核（2026-11-23）
- **Git 基线**：分支 `main`，HEAD `c01552d`（`fix(apple-music): persist account name in keychain and enhance web player playback diagnostics`）。工作区存在未提交文档变更（`AGENTS.md`、`CORE_V2_*.md`、`归档.zip` 及旧 docs 删除），已保护未覆盖。
- **工具链与环境**：macOS 27.2.1 (`26B131`) arm64；Apple Swift 6.4.2 (`arm64-apple-macosx27.2.0`)；Active Developer Directory 为 `/Library/Developer/CommandLineTools`（未安装完整 Xcode.app）。
- **构建基线**：`swift build --disable-sandbox` 成功（16.58s，Swift 6 严格并发开启）。
- **测试基线**：`swift test --disable-sandbox` 失败，原因：`Tests/DomainTests/DomainTests.swift` 与 `Tests/PlaybackTests/PlaybackStoreTests.swift` 使用 `import XCTest`，而 CommandLineTools 仅包含 `Testing.framework`（Swift Testing），不包含 `XCTest.framework`；`UnitTests` 与 `DesignSystemTests` 已使用 `import Testing`。
- **源码补充核实（BASELINE 遗漏项）**：
  1. `Sources/UI/Library/LibraryWindowController.swift` 存在 `sampleCardItems()` 与 `sampleAlbumTracks(albumTitle:)` 硬编码假数据回退（歌单为空、专辑/歌单/艺人曲目为空时伪造展示数据）。
  2. `LibraryWindowController.resolveUserDisplayName()` 在通用账户名时回退到 `NSFullUserName()` 或硬编码 `"小可"`。
  3. `Sources/Providers/AppleMusic/AppleMusicProvider.swift` 的 `fetchFavoriteSongs()` 在喜爱歌曲歌单为空时回退到 `fetchLibrarySongs(limit: 100)`，违反“拒绝以普通资料库冒充收藏”。
  4. `Sources/Providers/AppleMusic/Session/AppleMusicWebPlayer.swift` 直接反向依赖 `AppleMusicSessionManager.shared`（读取 `currentStorefront`、`webSessionState.isLoggedIn`）并发送 `.appleMusicRequiresAuthentication`。
  5. `Sources/Infrastructure/Logging/AppLogger.swift` 直接向 `/tmp/airmuse.log` 无上限追加写入，缺乏日志轮转、容量预算与凭据/Cookie 脱敏。
  6. `Sources/Playback/PlaybackCoordinator.swift` 与 `AppleMusicWebPlayer` 之间缺乏统一的底层命令串行队列与状态纠偏，缓冲/切歌/暂停/seek 并发时仍存在副作用竞争。
  7. 视觉回归参考已存在于 `Tests/VisualRegression/Baselines/`（`main_focused_1x`、`main_unfocused_1x`、`mini_40px_1x`）。
