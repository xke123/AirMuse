# 执行进度

当前状态：已完成 P0–P7 全部可执行开发、集成、单元测试与性能基准；真机 Apple Music 账户、远端电台与 macOS 原生玻璃材质视觉效果已明确列为待人工验收项。

| 阶段 | 状态 | 提交/证据 | 阻塞 |
|---|---|---|---|
| P0 | VERIFIED | `f494b09` + `swift test` 基线全量通过 | — |
| P1 | VERIFIED | `PlaybackOrigin`, `QueueEntry`, `QueueSnapshot`, `QueueCapabilities`, `QueueManagerTests` (T01, T02, T11) | — |
| P2 | VERIFIED | `QueueManager` + `PlaybackCoordinatorV2` + `QueueManagerTests` / `PlaybackCoordinatorQueueTests` (T01–T06, T11, T12) | — |
| P3 | VERIFIED | `QueueManager` + `PlaybackCoordinatorV2` + `QueueManagerTests` (T04, T07, T08, T10, T13, T24) | — |
| P4 | IMPLEMENTED | `AppleMusicAmpClient.TrackPage`, `QueuePaginationLoader`, `LibraryContentView` 右键入口, `LibraryWindowController` 来源绑定; `QueuePaginationTests` (T14–T16) 通过 | 真实 AMP 350+ 歌单联调待人工 |
| P5 | IMPLEMENTED | `PlaybackStore.queueStream`, `PlaybackSnapshotStore` v2 + v1迁移, `AppLifecycleCoordinator` 恢复/落盘接入; `PlaybackCoordinatorQueueTests` (T17–T20) 通过 | 真实 Apple Music 账户/电台实测待人工 |
| P6 | IMPLEMENTED | `LiquidFusionQueueDockView` (`NSGlassEffectContainerView` + `NSGlassEffectView`), 接入 `LibraryWindowController`; `LiquidFusionQueueDockTests` (T21–T23) 通过 | macOS 26+ 原生玻璃视觉/拖拽实机手感待人工 |
| P7 | VERIFIED | 全量 `swift test` 全绿；`QueuePerformanceTests` (100/1k/10k) 通过 | 真实设备/账户/Instruments 实测待人工 |

## 任务状态
- [x] Q01 — VERIFIED (自动化) / 实机待验 (`PlaybackOrigin`, `QueueEntry`, `QueueSnapshot`, `PlaybackStore.queueStream`)
- [x] Q02 — VERIFIED (`QueueManager` + `PlaybackCoordinatorV2` 顺序推进)
- [x] Q03 — VERIFIED (`QueueManager` Fisher–Yates 单轮不重复随机 + 关闭恢复基础相对顺序)
- [x] Q04 — VERIFIED (`QueueManager` 单曲循环：自然结束重播当前，手动 Next 消费待播)
- [x] Q05 — VERIFIED (`QueueManager` 列表循环：基于 `baselineOrder` 生成下轮，不复活已删/已清空项)
- [x] Q06 — VERIFIED (`clearUpcoming` 清空待播与循环成员、失效分页批次，保留当前音频与历史)
- [x] Q07 — VERIFIED (`playEntry(id:)` 指定条目播放并保留其他待播顺序)
- [x] Q08 — VERIFIED (`removeEntries(ids:)` 仅删待播与循环成员，不删当前与历史)
- [x] Q09 — VERIFIED (`moveEntries(ids:before:)` + `LiquidFusionQueueDockView` AppKit 拖拽重排)
- [x] Q10 — VERIFIED (右键“移到下一首” + `moveEntries(ids:before: firstID)`)
- [x] Q11 — VERIFIED (右键“移到末尾” + `moveEntries(ids:before: nil)`)
- [x] Q12 — IMPLEMENTED (音乐库单曲/专辑/歌单右键“添加到队列” + `coordinator.append`)
- [x] Q13 — IMPLEMENTED (音乐库单曲/专辑/歌单右键“下一首播放” + `coordinator.insertNext`)
- [x] Q14 — IMPLEMENTED (专辑/歌单整批加载后原子提交 `insertNext`/`append` 与 `playEntries`)
- [x] Q15 — VERIFIED (多选删除、多选拖拽、批量插入/追加原子提交)
- [x] Q16 — VERIFIED (`history` 游标与前进候选、3 秒阈值 `skipToPrevious`、无历史归零)
- [x] Q17 — IMPLEMENTED (`PlaybackSnapshotStore` schema v2 + v1 迁移、暂停恢复、账户隔离、`AppLifecycleCoordinator` 接入)
- [x] Q18 — IMPLEMENTED (`AppleMusicAmpClient.TrackPage` + `QueuePaginationLoader` 有界分页、游标去环、批次锚点)
- [x] Q19 — IMPLEMENTED (`QueueOwner.remoteEngine` + `QueueCapabilities.remoteStationDefault` + 电台切本地确认弹窗)
- [x] Q20 — VERIFIED (`UndoRecord` 单步安全撤销移除/清空，校验 `queueID`/`sessionScope`/`revision`)

## 每次会话记录
- 日期 / HEAD / 工作区状态：2026-11-27 / `f494b09` (main) / 已完成全部开发与测试，待用户审阅或提交
- 当前任务及依赖：Phase 0–7 全部完成
- 实际修改文件与设计决策：
  - Domain: `PlaybackOrigin.swift`, `QueueCapabilities.swift`, `QueueSnapshot.swift`, `PlaybackQueue.swift`, `PlaybackContracts.swift` (`QueueOwner: Codable`)
  - Playback: `QueueManager.swift`, `QueuePaginationLoader.swift`, `PlaybackCoordinatorV2.swift`, `PlaybackStore.swift`, `PlaybackSnapshotStore.swift`
  - Providers: `AppleMusicAmpClient.swift` (`TrackPage`), `AppleMusicProvider.swift`
  - App: `CompositionRoot.swift`, `AppLifecycleCoordinator.swift`
  - UI: `LibraryContentView.swift` (`LibraryQueueAction` 右键菜单), `LibraryWindowController.swift` (来源绑定、分页、电台切换确认、Dock 挂载), `UI/Library/PlaybackQueue/LiquidFusionQueueDockView.swift`
- 构建及测试命令、退出码、结果：
  - `swift test` (exit 0): DomainTests, PlaybackTests (24 tests in 5 suites), UnitTests, DesignSystemTests (53 tests in 8 suites) 全部通过
  - `swift test --filter QueuePerformanceTests` (exit 0): 100 entries (replace 0.36ms, shuffle 0.02ms, save 2.00ms); 1,000 entries (replace 1.86ms, shuffle 0.18ms, save 51.69ms); 10,000 entries (replace 17.26ms, shuffle 1.30ms, save 94.34ms) (Debug build, arm64 macOS 27.2.1)
- 性能基线与本次测量：见上 `QueuePerformanceTests` 实测数据；`PlaybackStore.queueStream()` 经 T20 验证不受进度/音量高频更新影响
- 未验证能力及原因（待人工实机验证）：
  1. 真实 Apple Music 登录账户下的 350+ 曲目歌单分页、连续切歌与网络失败重试
  2. 真实 Apple Music 电台 (`ra.*`) 播放时 `itemChanged` 继承来源及切回本地队列确认流程
  3. macOS 26+ 实机运行下 `NSGlassEffectContainerView` + `NSGlassEffectView` 的 Liquid Fusion 展开/收起形变与拖拽视觉效果
  4. Instruments 长时间运行下 App 与 WebKit 子进程的内存/帧率验证
- 下一步任务：人工在真实 macOS 26+ 环境启动 `AirMuse` 验证上述 4 项实机表现后即可最终收口提交。

## 完成门槛
源码接入、自动测试、实机验证分别记录；独立审查实际调用链而非文档勾选。真实账户/SDK 阻塞不得伪造通过，不影响其他独立任务推进。
