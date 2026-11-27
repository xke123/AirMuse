# 执行进度（初始模板）

参考提交 `ccd3102a5ddaa86785a645b1e000b9afce47a38c`。已完成静态审查与本期规范编写，尚未进行本 Patch 源码修改、编译、测试或实际账户验证。所有任务初始 TODO；不是对现有 Media Actions 已实现部分的否定。先核对实际 HEAD、工作区及测试，按证据更新。

| 阶段 | 状态 | 实际文件/调用链 | 测试与证据 | 阻塞/下一步 |
|---|---|---|---|---|
| MAS00 | VERIFIED | `Package.swift`, `MediaActions.swift`, `MediaActionResolver.swift`, `MediaResourceStateStore.swift`, `AppleMusicProvider.swift`, `LibraryWindowController.swift`, `MediaPlayCapsuleMenu.swift`, `AppDelegate.swift` | HEAD `ccd3102a5ddaa86785a645b1e000b9afce47a38c`, Swift 6.4.2, Xcode 27.2 (27B52), `swift test` 149 tests passed | 已完成基线复核 |
| MAS01 | TESTED | `MusicTrack.swift`, `MusicPlaylist.swift`, `MediaActions.swift`, `MediaActionResolver.swift`, `AppleMusicAmpClient.swift`, `AppleMusicProvider.swift`, `MediaResourceStateStore.swift`, `LibraryContentView.swift`, `LibraryWindowController.swift` | `MediaActionResolverTests` (7/7), `MAS-R03/R04/R34/R44` pass | 实机账号 ID 映射 E03 待联调 |
| MAS02 | TESTED | `MediaActions.swift`, `MediaResourceStateStore.swift`, `AppleMusicProvider.swift`, `LibraryWindowController.swift` | `MediaResourceStateStoreTests` (10/10), `MAS-R06/R07/R08/R10/R11/R13/R14/R15/R17` pass | 完成字段级补丁与并发隔离 |
| MAS03 | TESTED | `LibraryWindowController.swift`, `PlaybackCoordinatorV2.swift` | `MediaActionPlaybackTests` (7/7), `MAS-R19/R20/R26/R27/R28` pass | 真实 350+ 歌单分页 E04 待实机联调 |
| MAS04 | VERIFIED | `MusicArtistDetail.swift`, `AppleMusicAmpClient.swift`, `AppleMusicProvider.swift`, `LibraryWindowController.swift` | 实机已登录会话验证通过：`relate=library`（song/album/platform playlist）、`POST /v1/me/library` (202)、`DELETE /v1/me/library/*` (204)、`GET/PUT/DELETE /v1/me/ratings/*` (404=unrated/200/204)、歌曲电台 (200)；`LiveAppleMusicVerificationTests` pass | 已接入生产路径 |
| MAS05 | TESTED | `MediaPlayCapsuleMenu.swift`, `LibraryWindowController.swift` | `MediaActionsUITests` (3/3), `MAS-R37` pass | 实机界面/VoiceOver E05 待验收 |
| MAS06 | TESTED | `MediaPlayCapsuleMenu.swift`, `LiquidFusionQueueDockView.swift`, `AppLifecycleCoordinator.swift`, `AppDelegate.swift` | `DesignSystemTests` (56/56), `V02_BENCHMARK` pass | 多屏/Instruments E06–E07 待实测 |
| MAS07 | PENDING_INTEGRATION | 全仓构建与测试、`MAS-R46` 禁用项检索 | `cd AirMuse_macOS && swift test` exit 0 (161 tests passed, 0 failures)；`NO_FORBIDDEN_FEATURES_FOUND` | 待真实账号与 macOS 实机/Instruments 验收 E01–E07 |

## 缺陷台账（逐项更新，不合并关闭）
| ID | 状态 | 复现/修复证据及回归 ID |
|---|---|---|
| BUG01 | VERIFIED | 实机验证并接入 `AppleMusicAmpClient` 与 `AppleMusicProvider`：单曲/专辑/平台歌单资料库读写、收藏读写及歌曲电台（`LiveAppleMusicVerificationTests` 通过） |
| BUG02 | TESTED | 移除 `LibraryWindowController.mediaCapabilities` 硬编码，改由 `MediaResourceStateStore` 缓存 Provider 能力快照；`canReadLibraryMembership` 诚实置 false |
| BUG03 | TESTED | `MediaResourceStateStore.mergeMutationReceipt` 改为字段级补丁，保留另一字段与 pending；`MAS-R06/R07` 通过 |
| BUG04 | TESTED | 新增 `MediaToggleState.confirmedBool` 与 `MediaMutationOutcome`（含 `.superseded` / `.unknownOutcome`）；`MAS-R08/R10` 通过 |
| BUG05 | TESTED | 新增 `fieldRevisions` 与 `capturedRevisions` 校验，合并读共享结果，超时重验 `latestIntent`；`MAS-R11/R13/R14/R15` 通过 |
| BUG06 | TESTED | 抽取 `executeCollectionQueueAction` 与 `handleDetailTracksQueueAction`，统一详情与卡片完整分页；`MAS-R19/R20` 通过 |
| BUG07 | TESTED | `startArtistStation` 与艺人卡片/顶部播放均在点击时注册 `playIntentGeneration` 并跨 await 复核 |
| BUG08 | TESTED | `handleTracksQueueAction` 与 `executeCollectionQueueAction` 在 await 前捕获 `preSnap`，传入 `expectedQueueID`/`expectedDestructiveEpoch`；`MAS-R26/R28` 通过 |
| BUG09 | TESTED | 区分 `QueueCommandResult` 提交接受反馈与引擎状态；配合 `MediaMutationOutcome` 区分确认/未知/过期 |
| BUG10 | TESTED | `MusicTrack` 与 `MediaResourceReference.from(track:)` 分离 `catalogID`/`libraryID` 与 `hasTrustedLibraryDeleteIdentity`；`MAS-R03/R44` 通过 |
| BUG11 | TESTED | `MusicPlaylist` 新增 `ownership` 与 `catalogID`，未知/可编辑/协作默认只读；`MAS-R04` 通过 |
| BUG12 | TESTED | 导航传递 `isLibrary`，`MediaActionResolver` 对队列来源/专辑/艺人去重；`MAS-R34` 通过 |
| BUG13 | TESTED | `inFlightReads`/`activeWriteTasks` 按 `readID`/`writeID` 注销并清理意图，LRU 淘汰跳过 pending 项；`MAS-R17` 通过 |
| BUG14 | TESTED | `stateObserverID` 改用 `confirmedBool` 同步当前艺人头部状态，并在菜单打开时按需触发去重状态刷新 |
| BUG15 | TESTED | 检测 100 页上限或循环游标后终止并拒绝提交不完整随机集合，过期请求不取消新分页 |
| UX01 | TESTED | `playArtistTopSongs` 统一走 `handleTracksQueueAction`，移除 `try?` 吞错 |
| UX02 | TESTED | 新增 `prefetchResourceStateIfNeeded` 在菜单打开时按需去重刷新未知状态 |
| UX03 | VERIFIED | 已验证后全面开放单曲/专辑/平台歌单资料库与收藏能力及歌曲电台 |
| UX04 | TESTED | `queueDockView.onReportError` 接线至 `showFeedback` 可见反馈 |
| UX05 | TESTED | `MediaPlayCapsuleButton.toggleMenu` 移除空/nil 描述符兜底 `replaceAndPlay`；`MAS-R37` 通过 |
| UX06 | TESTED | `MediaPlayMenuPopoverController` 增加可见屏幕多屏夹紧、窗口关闭/最小化/失焦监听及单次选择守卫 |
| UX07 | TESTED | `LiquidFusionQueueDockView` 增加 180ms 视觉动画合并窗口、隐藏态跳过及 VoiceOver 播报 |
| UX08 | TESTED | `AppDelegate.activateApp` 改为调用 `AppLifecycleCoordinator.restoreStage()` 仅恢复主舞台 |

## 真实能力与环境记录
逐类型复制 PROVIDER 验证矩阵并追加结论，标明支持/不支持/未验证与证据；无账号环境不得猜测。E01–E07 实机验收单独记状态。用户未授权真实写入或当前环境缺账号/SDK 时记录具体解除条件，不把阻塞宣称完成。

## 每次会话追加
- 日期、分支、HEAD、工作区状态：
- 当前 MAS / BUG / UX ID、状态、复现方式：
- 实际改动文件、生产调用链、选择与理由：
- 命令、退出码、测试 ID/数量、日志：
- 性能基线/本次结果、设备、构建配置、证据：
- 真实账号/SDK 验证、安全限制、未完成原因：
- 下一最早可执行任务：

## 最终报告
按 G01–G06、BUG01–15、UX01–08、R01–46 与 E01–07 逐项对照；提供实际执行结果及剩余风险，不虚构百分比。工作区修改/提交状态明确说明，未经授权不推送。
