# AirMuse — Playback Queue Stabilization Progress

**审查基线：** `3fb529ddc3a511a1c8ae9738edb8b6f45f243c3d` (`main`)  
**当前状态：** VERIFIED (自动化回归与性能基准全绿) / 实机与真实账户待人工验收

| 阶段 | 涵盖任务 | 状态 | 验证证据 | 阻塞/备注 |
|---|---|---|---|---|
| Stage A | P0-01 ～ P0-06 (R01–R13, R16, R25) | VERIFIED | `PlaybackCoordinatorQueueTests`, `QueueStabilizationRegressionTests` (R01–R03, R06–R08, R13) | 真实账户/电台待人工 |
| Stage B | 4 个统一意图 + P1-01 ～ P1-03 (R09–R18, R20, R30) | VERIFIED | `QueueStabilizationRegressionTests` (R11, R14, R17), `QueuePaginationTests` | 真实 350+ 歌单待人工 |
| Stage C | P1-04 ～ P1-06 (R19, R21–R24, R26, R28) | VERIFIED | `QueueManagerTests`, `QueueStabilizationRegressionTests` (R21), `LiquidFusionQueueDockTests` | 真实弹窗交互待人工 |
| Stage D | P2-01 ～ P2-02 (R27, R29 及全量回归) | VERIFIED | 全量 `swift test` (exit 0) + `QueuePerformanceTests` | 原生玻璃/Instruments 待人工 |

## 逐项跟踪
- [x] **P0-01** 会话失效与异步快照恢复：`invalidatePlaybackSession` 同步清空 `desiredTrack`/`activeTargetResource`/锚点/旧事件并先发布空态；`restoreSnapshotIfNeeded` 跨 `await` 复核 5 项不变量 (`sessionScope`/`playbackGeneration`/`destructiveEpoch`/`queueID`/`revision`)。
- [x] **P0-02** 预留、确认、失败、取消与历史：`QueueManager.ReservationRecord` 独立持有 `previousConfirmed` 与 `forwardCandidate`；仅确认后入历史；失败可重试/跳过；取消 `previous` 回滚历史。
- [x] **P0-03** 引擎命令身份与 Store 原子发布：`playbackGeneration` 与 `transportRevision`/`queue.revision` 隔离；`PlaybackStore.commitAtomic(state:queueSnapshot:publishSequence:)` 单次 actor 原子提交。
- [x] **P0-04** 电台播放资源身份：`PlaybackTarget` 固定持有电台资源 ID；`itemChanged` 仅更新展示曲目，重试/恢复使用 `activeTargetResource` 且不对电台 seek。
- [x] **P0-05** 异步播放/添加意图与串行提交：点击时捕获 `playIntentGeneration` 与 `(queueID, destructiveEpoch)`，`prepend`/`append` 经 `pendingQueueSubmissionChain` 串行提交并防重复点击。
- [x] **P0-06** 分页重试接线：`QueuePaginationLoader` actor 记录 `failedNextURL`/`visitedURLs`/`batchID`/`epoch`，`LiquidFusionQueueDockView` 重试按钮按状态分派分页重试或曲目重试。
- [x] **1.1–1.2** 统一意图：`PlaybackCoordinatorV2.submitIntent` 覆盖 `replaceAndPlay` / `interruptAndPlay` / `prepend` / `append`，保留单按钮与未来播放菜单契约。
- [x] **P1-01** 稳定批次边界：`QueueSlot.batchTail(batchID)` 逻辑哨兵独立于条目存在性，删除锚点不取消批次，到达未加载边界进入 `.waitingForPage` 并在新页到达后自动续播。
- [x] **P1-02** 全量随机：`requestedShuffle` 与 `effectiveShuffle` 分离，大集合加载中显示「正在准备随机...」，完成后一次 Fisher–Yates。
- [x] **P1-03** 全量集合路径一致性：详情页点击使用 `onTrackIndexSelected` 精确行索引；`QueuePaginationLoader` 改为 `actor` 消除 `@unchecked Sendable`。
- [x] **P1-04** 清空、循环边界与耗尽：`canClearUpcoming` 涵盖待播/循环成员/活跃批次；`QueuePlaybackPhase` 区分 `exhausted`/`stoppedByUser`/`waitingForPage`/`failed`。
- [x] **P1-05** 电台切换与平台能力：`QueueCapabilities.canPlayEntry` 独立校验；电台切换弹窗明确「继续收听电台 / 结束电台并播放所选歌曲」。
- [x] **P1-06** 操作反馈、撤销与键盘：`LiquidFusionQueueDockView.showFeedback` 展示轻量状态反馈；同位拖拽在随机模式下仍更新 `baselineSlots`。
- [x] **P2-01** 原生玻璃单按钮与动画/命中修复：保持单队列按钮；`setExpanded` 先校验 `committed` 再清 `isAnimatingMorph`；窄窗口 clamp 不溢出。
- [x] **P2-02** 差量刷新与性能：`CollectionDifference` 行级增量更新 `NSTableView`，保留选中与滚动锚点。

## 测试与性能证据
- `cd AirMuse_macOS && swift test`：退出码 `0`（`PlaybackTests` 33 tests in 7 suites、`DesignSystemTests` 53 tests in 8 suites、`UnitTests`、`DomainTests` 全绿）。
- `QueuePerformanceTests` (Debug, arm64 macOS 27.2.1)：10k 条目 `replace ≈ 66.8ms`（并行负载下）/ `17.3ms`（独立运行）、`shuffle ≈ 6.7ms` / `1.3ms`、`save ≈ 133.4ms` / `94.3ms`。

## 待人工实机验收项
1. 真实 Apple Music 账户登录态下验证 350+ 歌单分页、断网重试与跨账户切换。
2. 真实 Apple Music 电台（`ra.*`）`itemChanged` 元数据更新、重试与切回本地队列弹窗。
3. macOS 26+ 实机运行下 `NSGlassEffectView` 单按钮形变、拖拽手感及 Instruments 长时间内存/帧率。
