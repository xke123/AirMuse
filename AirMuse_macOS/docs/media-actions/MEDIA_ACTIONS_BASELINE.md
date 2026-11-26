# 基线与源码复核
本规格基于已达成的产品决策和最新静态审计提交 [`d794fc2`](https://github.com/xke123/AirMuse/commit/d794fc2c0cf3ebb092b59de8d6a7c58158574595)，main，2026-11-27 04:29:29（北京时间）。执行前重新记录真实 HEAD；若已迁移以实际源码为准。本次只读源码，未独立编译、播放或验证平台写操作。提交标题宣称队列稳定性修复完成，不作为测试通过证据。

| 路径（Sources 下） | 复核重点 |
|---|---|
| UI/Library/LibraryContentView.swift | LibraryQueueAction、makeQueueContextMenu、卡片/歌曲行、详情播放按钮、回调 |
| UI/Library/LibraryWindowController.swift | 歌曲、专辑、歌单、搜索、艺人入口；资源上下文捕获、异步请求、导航 |
| UI/Library/PlaybackQueue/LiquidFusionQueueDockView.swift | NSMenuDelegate、现有单按钮、条目 UUID、错误反馈 |
| Playback/QueueManager.swift | 五种意图所需队列语义、历史、reservation、随机、循环、批次 |
| Playback/PlaybackCoordinatorV2.swift | 唯一写入者、命令与实际确认、账户作用域 |
| Playback/QueuePaginationLoader.swift | 全量加载、重试、取消、批次边界 |
| Playback/PlaybackStore.swift / PlaybackSnapshotStore.swift | 状态订阅、持久化与隔离 |
| Domain/Models/PlaybackQueue.swift / PlaybackOrigin.swift / MusicTrack.swift | 资源身份、来源、重复条目 |
| Providers/AppleMusic/AppleMusicAmpClient.swift / AppleMusicProvider.swift | 目录及个人资源映射、现有读写能力、分页 |
| Providers/AppleMusic/Library/LibraryRepositoryV2.swift | 缓存及账户作用域、资料库列表刷新 |
| App/CompositionRoot.swift | 依赖复用、服务生命周期 |

Phase 0 输出：每类入口的现有实际路径、已有五种意图支持状况、真实接口能力表、现有测试基线、SDK API 可用性、待修缺口。现有队列稳定性缺陷仅在阻塞本期契约时修复并回归，不开启独立重构。未经本次运行的测试不得标记通过。

## 已确认的现有能力及缺口
| 源码定位 | 事实与本期处理 |
|---|---|
| Playback/PlaybackCoordinatorV2.swift:200–280 | submitIntent 接收 QueueInsertionIntent、entries、startIndex、kind、loadingState、batchID、expectedQueueID、expectedDestructiveEpoch，返回 QueueCommandResult。四种意图已实现；仅补原子随机替换及顺序模式契约。检查异步接受结果与实际播放确认区别。 |
| Playback/QueueManager.swift:315、419–421、791、825 | replaceQueue、interruptAndPlay、insertNext、append 已有；不重建。 |
| UI/Library/LibraryContentView.swift:6–73 | LibraryQueueAction 映射四种意图；makeQueueContextMenu 为基础菜单，artist 返回 nil，radio 只播放。迁移到统一 resolver。 |
| UI/Library/LibraryWindowController.swift:1986–2240 附近 | 已有详情来源、playIntentGeneration、批量加载及电台切换入口；保留现有作用域、分页及反馈，核对所有入口。 |
| UI/Library/LibraryWindowController.swift:1846–1862 | toggleArtistFavorite 乐观更新 artistStack 与 header，失败仅日志；修复真实回滚/读回、共享状态、会话及意图隔离。 |
| Providers/AppleMusic/AppleMusicAmpClient.swift:879–915 / AppleMusicProvider.swift:420 | setArtistRating 已有 PUT/DELETE 实现及封装；复用并实测，不另建艺人写接口。 |
| AppleMusicAmpClient.swift:591、643–795、814–833、916 / AppleMusicProvider.swift:351–425 | 已有目录歌曲 ID 解析、收藏歌曲/歌单读取、资料库读取、曲目分页、艺人详情及电台。未见通用资料库添加/移除及歌曲、专辑、平台歌单收藏写接口；需验证。 |
| 根 AGENTS.md | 当前仓库仍要求旧任务；本包 AGENTS.md 替换为本期唯一任务。 |

以上行号仅用于该提交。真实账号、平台权限和 SDK 视觉仍待实测。
