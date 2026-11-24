# AirMuse Core V2 核心架构重构说明

> **文档状态**：已归档（对应重构交付基线 commit `bc47732`）  
> **适用范围**：`AirMuse_macOS`（Swift 6 严格并发 · AppKit · WebKit · URLSession · SQLite）

---

## 1. 重构背景与目标

本次 Core V2 重构面向 `AirMuse_macOS` 的全量核心业务层，在不改变原生 AppKit 皮肤、Liquid Glass 视效、MiniPlayer、窗口交互与系统媒体控制的前提下，系统性解决旧架构中存在的以下结构性问题：

1. **会话与凭据状态多义性**：旧版依赖分散的 `.shared` 单例与隐式状态判断，退出/切号/过期时易出现旧异步回调复活、跨账户缓存污染或误判退出。
2. **播放命令竞态与状态失真**：快速切歌、缓冲期暂停、拖动进度条（seek）与电台切歌场景下，旧版缺乏统一的命令串行化与事件归属隔离，容易出现状态覆盖、丢事件或底层实际播放曲目与 UI 不一致。
3. **缓存、网络与启动阻塞**：旧版存在主线程同步读缓存、启动阶段阻塞等待、图片解码与网络请求缺少并发合并和容量预算、私有库缓存未按账号/店面隔离等问题。

---

## 2. 总体架构与依赖装配

Core V2 采用 **单向依赖 + 显式依赖注入**，由 `CompositionRoot`（[CompositionRoot.swift](../../../Sources/App/CompositionRoot.swift)）作为唯一装配入口，替代分散的业务单例：

```text
AppLifecycleCoordinator (@MainActor)
  └─ CompositionRoot
       ├─ Presentation / UI (Player, Library, Auth, Log, Lyrics)
       ├─ SessionCoordinator (actor) ── CredentialVault / AmpSessionAuthBackend
       ├─ PlaybackCoordinatorV2 (actor) ── PlaybackStore / PlaybackSnapshotStore
       ├─ AppleMusicWebEngine (actor) ── WebRuntime (@MainActor) / WebBridgeParser
       ├─ LibraryRepositoryV2 (actor) ── SQLiteCacheStore / AppleMusicProvider
       ├─ LyricsRepositoryV2 (actor) ── SQLiteDatabase (lyrics_v2.sqlite)
       └─ Infrastructure: HTTPClient / ImageCacheV2 / AppLogger / LogSanitizer / AppSignpost
```

### 核心不变量
- **0ms 首屏可交互**：启动阶段不阻塞于网络请求、全量缓存读取或 WebKit 就绪，移除强制等待逻辑。
- **单一权威写入者**：会话状态由 `SessionCoordinator` 唯一持有；播放队列与状态由 `PlaybackCoordinatorV2` 唯一调度并写入 `PlaybackStore`；UI 仅订阅快照并发送意图。
- **显式上下文隔离**：个人数据操作绑定不可变 `SessionContext(providerID, accountID, storefront, sessionID, generation)`；播放事件绑定 `(sessionID, engineInstanceID, operationID, trackID)`。

---

## 3. 核心模块详解

### 3.1 会话与鉴权治理
- **`SessionCoordinator`**（[SessionCoordinator.swift](../../../Sources/Providers/AppleMusic/Session/SessionCoordinator.swift)）
  - 独立建模会话状态（`SessionState`）、客户端/用户凭据状态、订阅状态、目录状态与引擎状态。
  - 管理登录尝试生命周期（`beginLoginAttempt` / `cancelLoginAttempt`），取消后的旧登录回调无法重新激活会话。
  - 按 `(sessionID, CredentialKind)` 实现 **single-flight** 凭据刷新，多个并发等待者共享同一刷新任务且互不污染取消语义。
  - 通过 `invalidate(reason:)` 执行原子失效事务（递增 `generation`、关闭旧会话入口、隔离 Web 引擎与数据域、区分离线/403 与真实凭据失效）。
  - 提供 `validate(context:)` 原子提交校验，防止跨 `await` 的过时写入。
- **`CredentialVault`**（[CredentialVault.swift](../../../Sources/Infrastructure/Security/CredentialVault.swift)）
  - 使用 `v2.cred.<providerID>.<accountID|_global_>.<kind>` 键空间，隔离 `.client`（Developer Token）与 `.user`（Media User Token）凭据，并支持从旧版扁平键无损迁移（`migrateLegacyKeyIfNeeded`）。
- **`OriginValidator` & `AccountNamespaceResolver`**（[OriginValidator.swift](../../../Sources/Providers/AppleMusic/Session/OriginValidator.swift)）
  - 严格校验 HTTPS、精确主机白名单及 `.music.apple.com` / `.apple.com` 子域与 Cookie 域边界，杜绝宽松子串匹配。
  - 基于服务端账号标识或令牌摘要生成稳定的 SHA-256 本地账号命名空间（`srv_*` / `tok_*`）。
- **`AmpSessionAuthBackend` & `CoreV2SessionAdapter`**（[AmpSessionAuthBackend.swift](../../../Sources/Providers/AppleMusic/Session/AmpSessionAuthBackend.swift)）
  - 通过 `CoreV2SessionAdapter` 将 `SessionCoordinator` 桥接至 `AppleMusicProvider`，替代旧会话单例。

### 3.2 网络、缓存与仓储体系
- **`HTTPClient`**（[HTTPClient.swift](../../../Sources/Infrastructure/Networking/HTTPClient.swift)）
  - Actor 隔离传输调度，支持同键 GET 请求去重（单等待者取消不影响其他等待者）、优先级感知有界并发（默认 `maxConcurrentRequests = 6`）、端到端总超时预算、429 `Retry-After` 退避（有副作用请求禁止盲目重试）以及类型化 `CoreError` 映射。
- **`SQLiteCacheStore`**（[SQLiteCacheStore.swift](../../../Sources/Infrastructure/Cache/SQLiteCacheStore.swift)）
  - 基于 `CacheKey(providerID, scope, accountID, storefront, resource, normalizedParameters, schemaVersion)` 实现公私缓存分区与跨账号/店面隔离。
  - 支持 `expires_at`（新鲜期）、`max_stale_at`（最大容忍陈旧期）以及磁盘容量上限（默认 100MB）的 LRU 淘汰；私有写入前强制通过 `sessionValidator` 原子校验。
- **`ImageCacheV2`**（[ImageCacheV2.swift](../../../Sources/Infrastructure/Cache/ImageCacheV2.swift)）
  - 按 `(URL, pixelSize)` 合并并发图片请求，在非主线程使用 `CGImageSource` 降采样解码；设置 **50MB 内存缓存上限** 与 **300MB 磁盘 LRU 上限**。
- **`LibraryRepositoryV2`**（[LibraryRepositoryV2.swift](../../../Sources/Providers/AppleMusic/Library/LibraryRepositoryV2.swift)）
  - 统一实现 SWR（Stale-While-Revalidate）加载策略（公开目录 1h/7d、个人库 5m/24h、推荐 15m/24h、单曲详情 24h/7d）。
  - 提供循环游标检测的分页加载器（`fetchAllPages`）、搜索代际隔离（`searchGeneration`）与明确的四态返回模型 `LibraryLoadOutcome`（`loaded` / `empty` / `unauthorized` / `error`），移除假数据回退。

### 3.3 Web 播放引擎与播放调度器
- **`WebRuntime` & `WebBridgeParser`**（[WebRuntime.swift](../../../Sources/Providers/AppleMusic/Playback/WebRuntime.swift)、[WebBridge.swift](../../../Sources/Providers/AppleMusic/Playback/WebBridge.swift)）
  - `@MainActor` 托管单实例 `WKWebView`（`engineInstanceID`），负责视图保活挂载、严格导航/脚本来源校验、类型化参数 `callAsyncJavaScript` 注入以及一键隔离销毁（`isolateAndReset`）。
  - `WebBridgeParser` 校验 `engineInstanceID` 与 `operationID`，并完整透传 `ready`、`playbackStateDidChange`、`playbackTimeDidChange`、`nowPlayingItemDidChange`（含曲目 ID、标题、艺人、专辑、封面 URL）与 `playbackEnded` 事件。
- **`AppleMusicWebEngine`**（[AppleMusicWebEngine.swift](../../../Sources/Providers/AppleMusic/Playback/AppleMusicWebEngine.swift)）
  - 通过 `activePlayContext` 绑定当前播放指令上下文，严格校验 Web 授权（未授权返回 `WEB_NOT_AUTHORIZED`，不降级为 30 秒试听）。
  - 针对 WebContent 进程崩溃实施有界恢复（`maxCrashRecoveries = 2`，退避重建）。
  - 输出去重后的 `[ENGINE]` 关键状态日志（请求加载、缓冲音频流、音频播放开始、播放已暂停、曲目信息更新、曲目播放结束）。
- **`PlaybackCoordinatorV2` & `PlaybackTimeAnchor`**（[PlaybackCoordinatorV2.swift](../../../Sources/Playback/PlaybackCoordinatorV2.swift)）
  - **Latest-Intent-Wins 串行调度**：通过 `drainCommands()` 串行排空 `playItem`、合并后的 `seek` 与 `transportSync`，保障快速切歌、缓冲期暂停及停止操作最终以最新用户意图为准。
  - **操作上下文分离**：将 `activePlayOperationID`（仅在 `playTrack` / `stop` 时刷新）与 `operationID`（随 `play` / `pause` / `seek` 递增）分离，防止暂停或拖动进度条后引擎上报的 `playbackEnded` 与 `nowPlayingItemDidChange` 被误判为旧事件丢弃。
  - **队列归属隔离**：本地歌单/专辑由 `.localCoordinator` 管理自动下一首（含单曲循环、列表循环、随机与结束事件去重，及曲尾状态兜底检测）；电台由 `.remoteEngine` 管理切歌，并在远端切歌时同步刷新 `desiredTrack`、更新 `PlaybackStore` 并触发歌词检索。
  - **单调时钟进度插值**：通过 `PlaybackTimeAnchor` 在本地平滑插值进度，避免高频 JS 轮询。

### 3.4 歌词仓储、启动编排与诊断
- **`LyricsRepositoryV2`**（[LyricsRepositoryV2.swift](../../../Sources/Lyrics/LyricsRepositoryV2.swift)）
  - 使用独立 SQLite 数据库（`lyrics_v2.sqlite`）持久化歌词内容（`lyrics_cache_v2`）与逐曲目时间偏移量（`lyrics_offsets_v2`），通过 `activeTrackKey` 隔离异步请求，确保歌词故障与旧曲目延迟响应不影响音频播放或覆盖当前歌词。
- **`AppLifecycleCoordinator`**（[AppLifecycleCoordinator.swift](../../../Sources/App/AppLifecycleCoordinator.swift)）
  - **Stage 0（0ms）**：立即构建窗口控制器并展示主界面，同时挂载 `WebRuntime` 保活视图。
  - **Stage 1（并行预热）**：后台预解码皮肤核心资源、恢复会话并同步回填 `CredentialVault` 中的 `.client` Developer Token 至 `AppleMusicAmpClient.shared`、初始化数据库与调度器、注册 `MPRemoteCommandCenter` 与歌词/NowPlaying 监听。
  - **Stage 2（有序退出）**：取消后台任务、解绑媒体控制与通知观察者、停止调度器、隔离引擎并关闭 SQLite 连接。
- **日志脱敏与可观测性**
  - `LogSanitizer`（[LogSanitizer.swift](../../../Sources/Infrastructure/Logging/LogSanitizer.swift)）对 Bearer Token、JWT、`media-user-token`、Cookie/Authorization 头与 JSON 敏感字段统一脱敏；`AppLogger` 支持容量上限轮转；`AppSignpost` 记录冷启动、会话恢复与核心服务初始化耗时；`LogWindowController` 实时展示 V2 子系统诊断快照。

---

## 4. 旧架构清理与实机联调修复清单

1. **旧架构移除与 UI 迁移**：删除旧版 `PlaybackCoordinator.swift` 与 `LibraryCacheStore.swift`，将 `PlayerWindowController`、`LibraryWindowController`、`AppleMusicAuthWindowController` 与 `LogWindowController` 全部切换至 Core V2 管线。
2. **Developer Token 回填与去重**：`AppleMusicAmpClient.ensureDeveloperToken()` 增加 `inFlightDevTokenTask` single-flight 合并，并在 `execute()` 中直接透传 `CancellationError`，消除冷启动并发取消引起的误报警；启动与会话同步时从 `CredentialVault` 自动回填 `.client` 凭据。
3. **电台切歌联动**：`WebBridge` / `WebRuntime` 补充透传曲目 ID、标题、艺人、专辑与封面 URL，`PlaybackCoordinatorV2` 实时刷新 `desiredTrack` 并触发 `LyricsRepositoryV2` 拉取新曲歌词。
4. **播完连播与 Seek 隔离**：通过 `activePlayOperationID` 与曲尾状态兜底检测修复暂停或 Seek 后无法自动连播的问题。
5. **封面缓存统一与接口修正**：`PlayerView.swift` 与 `LibraryContentView.swift` 封面加载统一接入 `ImageCacheV2.shared`；`AppleMusicProvider.fetchRecentlyAdded()` 的请求 `limit` 由 50 调整为 Apple Music API 上限 25，修复 HTTP 400。

---

## 5. 归档文档索引

本目录同时归档了 Core V2 重构过程文档：
- [CORE_V2_ARCHITECTURE.md](./CORE_V2_ARCHITECTURE.md) — Core V2 目标架构与契约设计规范
- [CORE_V2_BASELINE.md](./CORE_V2_BASELINE.md) — 重构前源码调用链审计与构建测试基线
- [CORE_V2_ROADMAP.md](./CORE_V2_ROADMAP.md) — P0–P8 分阶段实施路线图与验收标准
- [CORE_V2_PROGRESS.md](./CORE_V2_PROGRESS.md) — 各阶段任务状态、测试结果、设计决策（ADR）与人工集成验收清单
