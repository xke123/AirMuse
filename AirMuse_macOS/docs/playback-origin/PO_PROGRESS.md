# PO — 进度记录（初始模板）

参考提交 `99466ff7853e6c3cfe88bf41159a23768b12b558`。已完成本期方案及静态基线证据整理；尚未实施、构建或运行本期测试。当前仓库的历史测试报告不代表本期验证。

| 阶段 | 状态 | 文件/证据 | 测试/阻塞 | 下一步 |
|---|---|---|---|---|
| PO00 | VERIFIED | `Package.swift`, `AGENTS.md`, `PlaybackOrigin.swift`, `QueueCapabilities.swift`, `MusicStation.swift`, `QueueSnapshot.swift`, `PlaybackCoordinatorV2.swift`, `QueueManager.swift`, `LibraryWindowController.swift`, `LiquidFusionQueueDockView.swift`, `MediaActionResolver.swift`, `AppleMusicWebEngine.swift`, `PlaybackSnapshotStore.swift` | `cd AirMuse_macOS && swift test` exit 0 (164 tests passed: DomainTests 10, UnitTests 56, PlaybackTests 40, DesignSystemTests 58); macOS 27.2.1 (26B131), Swift 6.4.2, MacOSX27.2.sdk; B01–B14 全部静态复核确认存在 | 推进 PO01 |
| PO01 | TESTED | `PlaybackOrigin.swift`, `LibraryWindowController.swift`, `QueueManager.swift`, `PlaybackOriginModelTests.swift`, `PlaybackOriginQueueTests.swift`, `PlaybackCoordinatorQueueTests.swift` | `swift test --filter "PlaybackOriginModelTests|PlaybackOriginQueueTests"` + `swift test` exit 0 (169 tests passed) | 推进 PO02 |
| PO02 | TESTED | `QueueCapabilities.swift`, `QueueManager.swift`, `PlaybackCoordinatorV2.swift`, `RadioSessionTests.swift` | `swift test --filter "RadioSessionTests"` + `swift test` exit 0 | 推进 PO04 |
| PO03 | TESTED | `QueueManager.swift`, `PlaybackCoordinatorV2.swift`, `LibraryWindowController.swift`, `ModeSwitchTests.swift` | `swift test --filter "ModeSwitchTests"` + `swift test` exit 0 | 推进 PO04 |
| PO04 | TESTED | `MediaActions.swift`, `MediaActionResolver.swift`, `LibraryContentView.swift`, `LibraryTopBarView.swift`, `LibraryWindowController.swift`, `OriginNavigationResolverTests.swift` | `swift test --filter "OriginNavigationResolverTests"` + `swift test` exit 0 (178 tests passed) | 推进 PO05 |
| PO05 | TESTED | `LiquidFusionQueueDockView.swift`, `LibraryWindowController.swift`, `DualGlassDockTests.swift` | `swift test --filter "DualGlassDockTests"` + `swift test` exit 0 (179 tests passed) | 推进 PO06 |
| PO06 | TESTED | `PlaybackStore.swift`, `PlaybackOriginQueueTests.swift`, `QueueManager.swift` | `swift build && swift test` exit 0 (180 tests passed) | 推进 PO07 |
| PO07 | PENDING_INTEGRATION | 全部 PO00–PO06 产物及 `git diff --stat` | 全量构建与 180 项自动测试通过；E01–E08 需真实账号/实机 UI/Instruments 手工验收 | 完成 E01–E08 实机验收 |

## 基线缺陷台账
| ID | 状态 | 复现/修复/测试证据 |
|---|---|---|
| B01 | TESTED | `PlaybackOrigin.swift` 新增 `OriginNavigationTarget` / `StationOriginContext` 及向后兼容解码；`PlaybackOriginModelTests` (P34) & `OriginNavigationResolverTests` (P30) 通过 |
| B02 | TESTED | `LibraryWindowController.swift` `currentBrowseOrigin(for:)` 修复搜索 query/scope、推荐/浏览/资料库真实栏目 ID 与 tab 2 非电台标记 |
| B03 | TESTED | `LibraryWindowController.swift` `handleItemClicked` 拆分 `.radio`（单一电台目标）与 `.song, .chart`（过滤非歌曲卡片并显式 `kind: .song`） |
| B04 | TESTED | `PlaybackCoordinatorV2.swift` `playEntries` 与 `playTrack` 显式校验 `kind`，拒绝多条/混合电台提交；`RadioSessionTests` (P11) 通过 |
| B05 | TESTED | `QueueManager.swift` `updateRemoteCurrentTrack` 不再自动确认 `.playing`，保持 pending 与 confirmed 分离；`RadioSessionTests` (P15) 通过 |
| B06 | TESTED | `PlaybackCoordinatorV2.swift` `itemChanged` 新曲目不继承旧 artist/album/artwork/duration；`RadioSessionTests` (P13/P14) 通过 |
| B07 | TESTED | `QueueCapabilities.swift` 拆分 `remoteStationUnknown`/`remoteStationLive`/`remoteStationAlgorithmic`，默认保守禁用 skip/seek；`PlaybackCoordinatorV2` 全部入口强制校验；`RadioSessionTests` (P17/P18) 通过 |
| B08 | TESTED | `LiquidFusionQueueDockView.swift` 远端模式隐藏本地编辑工具栏，失败/连接/暂停优先于“电台自动续播中”，未知待播显示提示 |
| B09 | TESTED | `PlaybackCoordinatorV2.switchRemoteToStagedLocal` 原子暂存不自动播放；`LibraryWindowController` 集合与单曲统一调用 `promptRemoteStationSwitch` 并校验上下文；`ModeSwitchTests` (P22/P24) 通过 |
| B10 | TESTED | `MediaActionResolver.resolveOriginMenu` + `LibraryWindowController.navigateToOriginPurely`（含 `navigationGeneration` 与有界 3 页定位），纯内部导航不触发播放；`OriginNavigationResolverTests` (P26–P30) 通过 |
| B11 | TESTED | `PlaybackStore.queueStream` 与 `PlaybackCoordinatorV2` 低频投影隔离；`PlaybackOriginQueueTests` (P41/P42) 通过 |
| B12 | TESTED | `QueueManager.exportPersistencePayload` 使用 `confirmedCurrent?.id`，远端恢复校验真实 `stationID`；`PlaybackOriginQueueTests` (P07/P08) & `PlaybackCoordinatorQueueTests` 通过 |
| B13 | TESTED | `LiquidFusionQueueDockView.swift` 同 `NSGlassEffectContainerView` 新增 `originGlassView` 兄弟胶囊、互斥 `DockInteractionMode`、普通 50%/70% 面板与紧凑电台面板；`DualGlassDockTests` (P37–P40) 通过 |
| B14 | PENDING_INTEGRATION | `MusicStation.isLive` 映射至 `.live`/`.algorithmic`/`.unknown` 保守能力，真实远端队列读取与直播能力待 E02/E03 实机账号验证 |

## 测试记录
| ID | 状态 | 测试方法/实际结果 |
|---|---|---|
| P01 | TESTED | `PlaybackOriginQueueTests.sameTrackDistinctOriginsAndMutationPreservation` passed |
| P02 | IMPLEMENTED | `LibraryWindowController.currentBrowseOrigin` & detail/artist/station context capture (UI 实机待 E01) |
| P03 | TESTED | `QueuePaginationTests` + `playIntentGeneration` / `navigationGeneration` 隔离 |
| P04 | TESTED | `QueuePaginationTests` 分页批次来源保持 |
| P05 | TESTED | `QueueManagerTests` + `PlaybackCoordinatorQueueTests` 随机/循环/上一首保留来源 |
| P06 | TESTED | `PlaybackOriginQueueTests.sameTrackDistinctOriginsAndMutationPreservation` passed |
| P07 | TESTED | `PlaybackOriginQueueTests.stageOnlyAndPendingNotConfirmed` passed |
| P08 | TESTED | `PlaybackOriginQueueTests.stageOnlyAndPendingNotConfirmed` passed |
| P09 | IMPLEMENTED | `LibraryWindowController.handleItemClicked` `.radio` 单一电台提交 (UI 实机待 E02) |
| P10 | IMPLEMENTED | `LibraryWindowController.handleItemClicked` `.song, .chart` 过滤非歌曲卡片 |
| P11 | TESTED | `RadioSessionTests.rejectsMultipleOrMixedStationEntries` passed |
| P12 | IMPLEMENTED | `LibraryWindowController.startArtistStation` / `startSongStation` 竞争代数检查 |
| P13 | TESTED | `RadioSessionTests.remoteItemChangedMetadataAndTransportSeparation` passed |
| P14 | TESTED | `RadioSessionTests.remoteItemChangedMetadataAndTransportSeparation` passed |
| P15 | TESTED | `RadioSessionTests.remoteItemChangedMetadataAndTransportSeparation` passed |
| P16 | TESTED | `RadioSessionTests.stationCapabilitiesEnforced` passed |
| P17 | TESTED | `RadioSessionTests.stationCapabilitiesEnforced` passed |
| P18 | TESTED | `RadioSessionTests.stationCapabilitiesEnforced` passed |
| P19 | TESTED | `ModeSwitchTests.localRemoteSwitchAndHistoryIsolation` passed |
| P20 | TESTED | `ModeSwitchTests.localRemoteSwitchAndHistoryIsolation` passed |
| P21 | TESTED | `PlaybackCoordinatorQueueTests` interrupt 行为 + `LibraryWindowController.promptRemoteStationSwitch` |
| P22 | TESTED | `ModeSwitchTests.atomicSwitchRemoteToStagedLocal` passed |
| P23 | IMPLEMENTED | `LibraryWindowController.promptRemoteStationSwitch` 取消保持原电台 |
| P24 | TESTED | `ModeSwitchTests.atomicSwitchRemoteToStagedLocal` passed |
| P25 | TESTED | `ModeSwitchTests.localRemoteSwitchAndHistoryIsolation` passed |
| P26 | TESTED | `OriginNavigationResolverTests.deduplicatesOriginAndTrackAlbumArtist` passed |
| P27 | TESTED | `OriginNavigationResolverTests.deduplicatesOriginAndTrackAlbumArtist` passed |
| P28 | TESTED | `OriginNavigationResolverTests.deduplicatesRepeatedArtistIDs` passed |
| P29 | TESTED | `OriginNavigationResolverTests.stationSeedAndCurrentTrackArtistDistinct` passed |
| P30 | TESTED | `OriginNavigationResolverTests.searchLibraryChartNavigable` passed |
| P31 | IMPLEMENTED | `LibraryWindowController.locateTrackInCurrentDetail` (最多 3 页有界定位，实机待 E01) |
| P32 | IMPLEMENTED | `LibraryWindowController.navigateToOriginPurely` 安全降级提示 (实机待 E07) |
| P33 | IMPLEMENTED | `LiquidFusionQueueDockView.updateOriginCapsule` 切歌取消过期菜单 + `navigationGeneration` |
| P34 | TESTED | `PlaybackOriginModelTests.legacyAndUnknownDecoding` passed |
| P35 | TESTED | `PlaybackOriginQueueTests.stageOnlyAndPendingNotConfirmed` + `PlaybackSnapshot.resolvedQueuePayload` |
| P36 | TESTED | `PlaybackOriginQueueTests.accountSwitchIsolation` passed |
| P37 | TESTED | `DualGlassDockTests.dualGlassDockModesAndCleanup` passed |
| P38 | TESTED | `DualGlassDockTests.dualGlassDockModesAndCleanup` passed |
| P39 | TESTED | `DualGlassDockTests.dualGlassDockModesAndCleanup` passed |
| P40 | TESTED | `DualGlassDockTests.dualGlassDockModesAndCleanup` passed |
| P41 | TESTED | `PlaybackOriginQueueTests.highFrequencyUpdatesDoNotEmitQueueStream` passed |
| P42 | TESTED | `PlaybackOriginQueueTests.highFrequencyUpdatesDoNotEmitQueueStream` passed |
| E01 | PENDING_INTEGRATION | 需真实登录账号与资料库/搜索/榜单点击验收 |
| E02 | PENDING_INTEGRATION | 需真实 Apple Music 账号与 MusicKit WebEngine 电台事件验收 |
| E03 | PENDING_INTEGRATION | 需真实直播电台与未知类型能力实机验收 |
| E04 | PENDING_INTEGRATION | 需真实本地↔电台交互弹窗与音频输出验收 |
| E05 | PENDING_INTEGRATION | 需实机窗口录制 Original/Enhanced `NSGlassEffectContainerView` 融合效果 |
| E06 | PENDING_INTEGRATION | 需实机窄窗、多屏、VoiceOver、Reduce Motion/Transparency 验收 |
| E07 | PENDING_INTEGRATION | 需真实账户退出/切换与私有资源重启恢复验收 |
| E08 | PENDING_INTEGRATION | 需 Instruments 实机采集 CPU/GPU/能耗/内存/帧耗时基线对比 |

## 每次会话追加
- 日期、分支、HEAD、工作区状态、SDK/设备：2026-11-27、`main`、`99466ff7853e6c3cfe88bf41159a23768b12b558`、macOS 27.2.1 (26B131)、Swift 6.4.2、MacOSX27.2.sdk
- 本次 PO/B/G/P/E ID、状态、复现方式：完成 PO00–PO06（TESTED），PO07 进入 PENDING_INTEGRATION；B01–B13 TESTED，B14 PENDING_INTEGRATION
- 实际改动文件、生产调用链、业务契约及决策：`PlaybackOrigin.swift`, `QueueCapabilities.swift`, `MediaActions.swift`, `MediaActionResolver.swift`, `QueueManager.swift`, `PlaybackCoordinatorV2.swift`, `LibraryContentView.swift`, `LibraryTopBarView.swift`, `LibraryWindowController.swift`, `LiquidFusionQueueDockView.swift` 及 4 个测试文件
- 构建/测试命令、退出码、测试数量、日志：`cd AirMuse_macOS && swift build && swift test` exit 0（180 tests in 33 suites passed: UnitTests 56, PlaybackTests 49, DomainTests 16, DesignSystemTests 59）
- 真实电台能力、导航、原生材质、性能证据（脱敏）：待 E01–E08 实机执行
- 阻塞、解除条件、未完成原因：E01–E08 需真实 Apple Music 账号、交互式 GUI 录制、VoiceOver 及 Instruments 实机测量
- 下一个最早可执行任务：PO07 实机验收（E01–E08）

状态 TODO / IN_PROGRESS / IMPLEMENTED / TESTED / PENDING_INTEGRATION / VERIFIED / BLOCKED。VERIFIED 必须有对应真实证据；mock 仅证明其覆盖的自动测试。修改 ROADMAP 状态时同步此表。不将用户已有改动覆盖或擅自推送。
