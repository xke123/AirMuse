# PD — 最新源码基线与耦合台账

- 仓库 https://github.com/xke123/AirMuse，main，`3daa253b227e8905927e2c61e5009099e98c6ac1`，2026-11-27 06:05:07 UTC。
- 提交 `feat(playback-origin): implement playback origin, pure navigation, radio session & dual-glass dock`。
- 仓库 `docs/playback-origin/PO_PROGRESS.md` 自报 `swift build && swift test` 180 tests / 33 suites，8 组实机仍待验收；本规范编写时未独立运行。先在实际 HEAD 重建基线。下述行号为该提交的定位，不视为未来源码事实。
- 源码链接前缀 `https://github.com/xke123/AirMuse/blob/3daa253b227e8905927e2c61e5009099e98c6ac1/AirMuse_macOS/`。

| ID | 位置（Sources 除 Package） | 观察/风险 | 必须关闭的条件 |
|---|---|---|---|
| B01 | Package.swift 83–95 | UI 直接依赖 Providers | UI 直接/传递依赖无具体 Adapter；无 Apple Music 构建验证 |
| B02 | App/CompositionRoot.swift 26–101 | WebRuntime/AppleMusicWebEngine/SessionCoordinator/AppleMusicProvider 启动时固定创建 | App 注册 factory；按需激活且可无平台启动 |
| B03 | App/AppLifecycleCoordinator.swift 122、199–226 | WebRuntime 附加播放器视图；生命周期直接同步 AMP Token 与 storefront | 专有运行时宿主、凭证与准备逻辑收敛到 Adapter；浏览切换不影响音频 |
| B04 | UI/Library/LibraryWindowController.swift 75–130、969、2535–2544 | 具体 Provider、AmpCategory、TrackPage、分页与集合播放在 UI | 改为通用 DTO/route/cursor 与服务；删除旧生产路径 |
| B05 | 同文件 3180–3288，特别 3197 | 来源路由忽略 providerID；栏目按标题/默认索引回退；电台详情仅提示 | 路由按平台/账户/地区解析；未知目标明确失败，不随意跳页 |
| B06 | Domain/Models/MediaActions.swift 247–252 | 页面身份裸 ID；导航去重有跨平台碰撞风险 | 页面和导航使用 ResourceIdentity，可信别名才去重 |
| B07 | Domain/Models/PlaybackOrigin.swift 37–43、77、162、230–269 | 默认 Apple Music；多个 route case 无作用域 | 所有 route 均有作用域，旧数据只在迁移器推定 |
| B08 | Domain/Models/MusicTrack.swift 50、67、81、111、143–162；MediaActions.swift 139；UI Dock 1858 | i. 等专有前缀推断资料库，来源资料库标记被用来推断歌曲身份 | 专有规则仅 Adapter/受限旧数据迁移；源与曲目身份独立 |
| B09 | Playback/PlaybackCoordinatorV2.swift 64、110–142 | 固定 engine 实例及单活动会话 | 通用 Router 可切换、底层事件身份保留，音频权事务验证 |
| B10 | 同文件 307–380 | 暂存切换跨 await 后无重验；发布 idle 后 try? stop | 复现竞态与 stop 失败；无法确认静音不得假装交接成功 |
| B11 | 同文件 384–455 | kind 决定 owner，按 stationType 固定能力；stationID 构造路径重复 | 显式目标、owner 与能力；实际引擎证据；唯一电台目标身份 |
| B12 | Domain/Models/QueueCapabilities.swift 73–129 | algorithmic 固定 canSeek/skip，unknown 默认 canPause | 明确未知与已验证能力；按会话及引擎证据保守合成 |
| B13 | Domain/Protocols/MusicLibraryProvider.swift 19–26；MusicCatalogProvider.swift 19–27 | 默认空写/false/空数组掩盖不支持 | 不支持显式错误；已知空集合区分 unsupported |
| B14 | Providers/AppleMusic/AppleMusicProvider.swift 318–430、658；Playback/QueuePaginationLoader.swift 9–14、68–70 | AMP DTO/URL 游标泄漏 | 统一 opaque cursor，保留批次/取消/重试 |
| B15 | Providers/MediaActions/MediaResourceStateStore.swift 12–17、57、74、495；Controller 440 | 单 provider 配置及固定作用域；现有缓存虽有 provider key，但跨浏览操作未路由 | 按真实资源上下文隔离；scope 变化与注销安全 |
| B16 | UI/Auth/AppleMusicAuthWindowController.swift 5–47；App 生命周期 88 | 通用 UI 依赖平台授权对象 | 通用账户状态与命令；专用登录 UI 移出通用 Target |
| B17 | Providers/Spotify/SpotifyProvider.swift；Providers/QQMusic/QQMusicProvider.swift | 使用旧 MusicPlaybackProvider；未接入当前 Engine 生产路径 | 明确未接入，避免第二调度路径；Fixture 验证新契约 |
| B18 | Playback/PlaybackSnapshotStore.swift 129–169 | 单文件、按 provider/account 读取，需验证地区、恢复及切换写入 | 本期单活动快照原子持久化且作用域严格；旧数据迁移不泄漏 |
| B19 | Lyrics/LyricsRepositoryV2.swift 55、100–104；AppleMusicProvider.swift 1022 之后 | 歌词 Provider 注册可复用，但第三方检索耦合在 Apple Music | 独立歌词来源与真实身份匹配，移除 Apple Music 不破坏通用歌词 |
| B20 | UI/Library/PlaybackQueue/LiquidFusionQueueDockView.swift 990–1097 | 来源动画签名无 provider，异步完成回调未见代数校验；关系缓存按 trackKey | 统一完整身份与动画 token，旧结果不覆盖当前显示 |
| B21 | Playback/PlaybackCoordinatorV2.swift 1359–1385；Domain/CoreV2/PlaybackContracts.swift | sessionScope 已含会话代数，但 provider fallback 固定；PlaybackTarget 仅裸 providerResourceID | 活动/待处理目标绑定 provider/account/session，未知无伪平台 |

B01–B09、B11–B21 的观察为静态证据，跨平台故障是可推导风险而非已在真实双平台复现。B10/B20 须用受控挂起点测试确认。不得为关闭台账修改无关代码。PD00 补充全仓扫描、实际依赖和未发现调用者，不能仅依赖本表。
