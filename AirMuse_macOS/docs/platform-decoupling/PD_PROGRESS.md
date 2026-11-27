# PD — 实际进度（初始化）

参考 HEAD `3daa253b227e8905927e2c61e5009099e98c6ac1`，已完成静态方案与规范编写；本次未修改生产源码、未编译、未运行测试或实机验证。所有本期工作初始 TODO。实际 HEAD 先复核，若已有实现以证据关闭，不重复开发。

| 阶段 | 状态 | 实际文件及调用链 | 命令/结果/证据 | 阻塞或下一步 |
|---|---|---|---|---|
| PD00 | VERIFIED | `Package.swift`, `Sources/{Domain,Playback,UI,App,Infrastructure}` 全仓扫描 | `swift build && swift test` 退出码 0 (33 suites / 180 tests)；Swift 6.4.2 / Xcode 27.2 / macOS 27.2.1 | 额外发现 `LogWindowController` 与 `PlayerView`/`PlayerWindowController` 耦合；推进 PD01 |
| PD01 | TESTED | `ResourceIdentity.swift`, `MusicTrack.swift`, `MediaActions.swift`, `MediaActionResolver.swift`, `PlaybackOrigin.swift`, `PlaybackContracts.swift`, `ResourceIdentityTests.swift` | `swift test` 退出码 0 (34 suites / 185 tests，新增 5 条 PD01 用例通过) | 推进 PD02 |
| PD02 | TESTED | `PageContracts.swift`, `PlatformAdapterContracts.swift`, `CoreError.swift`, `QueueCapabilities.swift`, `MusicCatalogProvider.swift`, `MusicLibraryProvider.swift`, `ContractsTests.swift` | `swift test --filter DomainTests` 退出码 0 (6 suites / 25 tests) | 推进 PD03 |
| PD03 | TESTED | `PublicSyncedLyricsProvider.swift`, `AppleMusicProvider.swift`, `AppleMusicAdapter.swift`, `AppleMusicAdapterTests.swift` | `swift test --filter AppleMusicAdapterTests` 退出码 0 (1 suite / 2 tests) | 推进 PD04 |
| PD04 | TESTED | `ProviderSessionRegistry.swift`, `ApplicationServices.swift`, `ApplicationServicesTests.swift` | `swift test --filter ApplicationServicesTests` 退出码 0 (1 suite / 2 tests) | 推进 PD05 |
| PD05 | TESTED | `Package.swift`, `AppleMusicIntegrationUI/*`, `LogWindowController.swift`, `PlayerView.swift`, `PlayerWindowController.swift`, `LibraryWindowController.swift`, `FixtureHost/main.swift` | `FixtureHost` 无 Apple Music 构建并启动通过；`AirMuse` 构建及全量 `swift test` 退出码 0 | 推进 PD07 |
| PD06 | TESTED | `ProviderSessionRegistry.swift`, `CompositionRoot.swift`, `AppLifecycleCoordinator.swift`, `ApplicationServicesTests.swift` | 惰性注册、按需激活、浏览/播放隔离验证通过 | 推进 PD07 |
| PD07 | TESTED | `EngineRouter.swift`, `PlaybackCoordinatorV2.swift`, `CompositionRoot.swift`, `EngineRouterTests.swift` | `swift test --filter EngineRouterTests` 退出码 0 (1 suite / 3 tests)；`AirMuse` 编译通过 | 推进 PD08 |
| PD08 | TESTED | `PlaybackSnapshotStore.swift`, `LiquidFusionQueueDockView.swift`, `LibraryWindowController.swift`, `SnapshotScopeTests.swift` | `swift test` 退出码 0 (39 suites / 197 tests) | 推进 PD09 |
| PD09 | PENDING_INTEGRATION | `Package.swift`, `FixtureHost`, 全仓源码与依赖闭包 | `FixtureHost` 构建并启动；`AirMuse` 构建；`swift test` 39 suites / 197 tests 通过；R01/R03 扫描通过 | E01–E08 需实机 Apple Music 账户与 GUI/Instruments 独立验收 |

## 缺陷台账
| ID | 状态 | 复现与关闭证据 |
|---|---|---|
| B01 | TODO | — |
| B02 | TODO | — |
| B03 | TODO | — |
| B04 | TODO | — |
| B05 | TODO | — |
| B06 | TODO | — |
| B07 | TODO | — |
| B08 | TODO | — |
| B09 | TODO | — |
| B10 | TODO | — |
| B11 | TODO | — |
| B12 | TODO | — |
| B13 | TODO | — |
| B14 | TODO | — |
| B15 | TODO | — |
| B16 | TODO | — |
| B17 | TODO | — |
| B18 | TODO | — |
| B19 | TODO | — |
| B20 | TODO | — |
| B21 | TODO | — |

## 目标与验收台账
| ID | 状态 | 实际证据及剩余问题 |
|---|---|---|
| G01 | TODO | — |
| G02 | TODO | — |
| G03 | TODO | — |
| G04 | TODO | — |
| G05 | TODO | — |
| G06 | TODO | — |
| G07 | TODO | — |
| G08 | TODO | — |
| R01 | TODO | — |
| R02 | TODO | — |
| R03 | TODO | — |
| R04 | TODO | — |
| R05 | TODO | — |
| R06 | TODO | — |
| R07 | TODO | — |
| R08 | TODO | — |
| R09 | TODO | — |
| R10 | TODO | — |
| R11 | TODO | — |
| R12 | TODO | — |
| R13 | TODO | — |
| R14 | TODO | — |
| R15 | TODO | — |
| R16 | TODO | — |
| R17 | TODO | — |
| R18 | TODO | — |
| R19 | TODO | — |
| R20 | TODO | — |
| R21 | TODO | — |
| R22 | TODO | — |
| R23 | TODO | — |
| R24 | TODO | — |
| R25 | TODO | — |
| R26 | TODO | — |
| R27 | TODO | — |
| R28 | TODO | — |
| R29 | TODO | — |
| R30 | TODO | — |
| R31 | TODO | — |
| R32 | TODO | — |
| R33 | TODO | — |
| R34 | TODO | — |
| R35 | TODO | — |
| R36 | TODO | — |
| R37 | TODO | — |
| R38 | TODO | — |
| R39 | TODO | — |
| R40 | TODO | — |
| R41 | TODO | — |
| R42 | TODO | — |
| R43 | TODO | — |
| R44 | TODO | — |
| R45 | TODO | — |
| R46 | TODO | — |
| R47 | TODO | — |
| R48 | TODO | — |
| R49 | TODO | — |
| R50 | TODO | — |
| R51 | TODO | — |
| R52 | TODO | — |
| E01 | TODO | — |
| E02 | TODO | — |
| E03 | TODO | — |
| E04 | TODO | — |
| E05 | TODO | — |
| E06 | TODO | — |
| E07 | TODO | — |
| E08 | TODO | — |

## 每次会话追加
- 日期、分支、HEAD、工作区、SDK、设备：2026-11-28，`main`，HEAD `3daa253b227e8905927e2c61e5009099e98c6ac1`，Swift 6.4.2 / Xcode 27.2 (27B52) / macOS 27.2.1 (arm64)。
- 任务 ID、状态、原始复现、实际调用链与改动文件：PD00 VERIFIED；PD01–PD08 TESTED；PD09 PENDING_INTEGRATION（自动化 R01–R52 相关回归已通过，E01–E08 待实机）。新增 `PlatformRuntime`（`ProviderSessionRegistry`、`EngineRouter`）、`Application`（`ApplicationServices`、`MediaResourceStateStore`）、`AppleMusicIntegrationUI`、`FixtureHost`、`AppleMusicAdapter`、`PublicSyncedLyricsProvider`、`ResourceIdentity`、`PageContracts`、`PlatformAdapterContracts`。
- 模块依赖图、移除的旧入口、设计选择及理由：`UI` 移除 `Providers` 依赖，改为 `UI -> Domain, Playback, Application, PlatformRuntime, Lyrics, DesignSystem, Infrastructure`；`FixtureHost` 不链接 `Providers` 或 `AppleMusicIntegrationUI`；`PlaybackCoordinatorV2.switchRemoteToStagedLocal` 修复为先确认停播再跨 `await` 重验代数后原子替换队列（B10）。
- 构建/测试命令、退出码、suite/test 实际数量、失败日志：`swift build --product FixtureHost && swift run FixtureHost`（退出码 0）；`swift build --product AirMuse`（退出码 0）；`swift test`（退出码 0，39 suites / 197 tests：UnitTests 11/63、PlaybackTests 12/50、DomainTests 6/25、DesignSystemTests 10/59）。
- 音频权测试证据、账户隔离、平台能力、原生 UI 实机证据（脱敏）：`EngineRouterTests` 验证候选准备失败保活旧音频、停播失败阻断新引擎、`maxConcurrentAudio <= 1`、B10 拒绝覆盖；`ApplicationServicesTests` 与 `SnapshotScopeTests` 验证跨平台浏览/收藏/导航隔离及快照作用域隔离；E01–E08 实机待验。
- 性能基线及本次采样、配置、原始记录：V02 benchmark（800 samples / 60Hz）：P50=0.208ms, ActiveP95=0.486ms, AllP95=10.702ms, P99=13.047ms（Debug）。
- 阻塞、解除条件、下一最早可执行任务：E01–E08 需真实 macOS 桌面环境与已登录 Apple Music 账号执行。

状态语义：TODO 未启动；IN_PROGRESS 实施中；IMPLEMENTED 已真实接线未完成测试；TESTED 已执行相关自动测试；PENDING_INTEGRATION 需要真实环境联调；VERIFIED 满足全部适用验收且有证据；BLOCKED 无法继续且原因明确。不能用一个通过用例关闭整个阶段的所有目标。最终逐项报告 G/B/R/E、构建与性能、剩余风险、实际工作区状态。
