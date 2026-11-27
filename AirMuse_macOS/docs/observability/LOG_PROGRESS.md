# LOG — 初始进度及证据台账
源码基线：`791ae679d8e1c7fc03252f57dc4cef09c13a7005`（main，2026-11-28 06:24:47 北京时间）。实施前复核 HEAD。本文为实施规范，不是已完成的生产功能或实测结果。

当前仅制定规范，未改生产代码、未运行构建/测试。旧任务报告不可当本期实测。所有阶段/缺陷/验收初始 TODO。

| 阶段 | 状态 | 生产文件 / commit | 构建/测试证据 | 阻塞 / 下一步 |
|---|---|---|---|---|
| LOG00 | VERIFIED | HEAD `791ae679d8e1c7fc03252f57dc4cef09c13a7005`, `LOG_EVENT_INDEX.json` (309 events) | `swift build --product FixtureHost` + `swift run FixtureHost` (exit 0); `swift build --product AirMuse` (exit 0); `swift test`: 199 tests in 39 suites passed (65+50+25+59); V02 P50=0.206ms ActiveP95=0.494ms | LOG01 类型化 Schema 与 Trace 上下文 |
| LOG01 | TESTED | `DiagnosticContracts.swift`, `AppLogger.swift`, `AppEnvironmentInfo.swift`, `AppSignpost.swift` | `FixtureHost`/`AirMuse` build exit 0; `VaultDatabaseLogTests` (4 passed); `ObservabilityPipelineTests` (9 passed) | LOG03 平台/会话/网络/应用服务全出口 |
| LOG02 | TESTED | `LogSanitizer.swift`, `DiagnosticWriter.swift`, `AppLogger.swift` | `ObservabilityPipelineTests` T10–T23, T57 passed (9/9) | 纳入 LOG08 导出与 UI 接线 |
| LOG03 | TESTED | `HTTPClient.swift`, `ProviderSessionRegistry.swift`, `ApplicationServices.swift`, `MediaResourceStateStore.swift`, `AppleMusicAmpClient.swift`, `SessionCoordinator.swift` | `FixtureHost`/`AirMuse` build exit 0; 43 tests in 5 suites passed | LOG04 引擎路由、协调器与可重放队列 |
| LOG04 | TESTED | `EngineRouter.swift`, `PlaybackCoordinatorV2.swift`, `QueuePaginationLoader.swift` | `FixtureHost`/`AirMuse` build exit 0; 24 tests in 6 suites passed (`PlaybackTests`) + `EngineRouterTests` | LOG05 歌词、缓存、数据库与快照持久化 |
| LOG05 | TESTED | `LyricsRepositoryV2.swift`, `SQLiteCacheStore.swift`, `PlaybackSnapshotStore.swift` | 10 tests in 3 suites passed (`LyricsParserTests`, `CacheRepositoryTests`, `SnapshotScopeTests`) | LOG06 UI/Motion/性能聚合 |
| LOG06 | TESTED | `DiagnosticPerformanceAggregator.swift`, `PlayerWindowController.swift` | 59 tests in 10 suites passed (`DesignSystemTests`); V02 P50=0.201ms ActiveP95=0.521ms | LOG07 只读状态快照与不变量检查 |
| LOG07 | TESTED | `DiagnosticSnapshotCoordinator.swift`, `EngineRouter.swift`, `ProviderSessionRegistry.swift`, `PlaybackCoordinatorV2.swift`, `HTTPClient.swift` | `ObservabilityEndToEndTests` T53/T54 passed | B12 已修复，剩余模块可继续扩展 `DiagnosticSnapshotProvider` |
| LOG08 | TESTED | `LogWindowController.swift`, `DiagnosticBundleExporter.swift`, `AppLifecycleCoordinator.swift`, `FixtureHost/main.swift` | `ObservabilityEndToEndTests` T05/T56 passed; `FixtureHost` booted cleanly (`snapshots=3`) | 实机 UI/辅助功能验证 E06 待验 |
| LOG09 | PENDING_INTEGRATION | `ObservabilityPipelineTests.swift`, `ObservabilityEndToEndTests.swift`, `LOG_EVENT_INDEX.json` | `swift test --no-parallel`: 211 tests in 41 suites passed (77+50+25+59); T58: normal p50=0.0953ms p95=0.2561ms, full p50=0.0908ms p95=0.2051ms | 事件覆盖 101/309 已接线；208 项待补全；E01–E08 实机待验 |

## 覆盖台账
每个事件登记 eventName、owner、生产文件:行、必填字段/trace、成功/失败/取消/过期分支、自动测试、状态；适用性 N/A 需要理由，不从分母静默剔除。LOG00 生成机器可读索引（CSV/JSON 均可）；每次报告适用总数、已接线数、已验证数、未覆盖数、N/A 数。

| 基线ID | 状态 | 复核/修复证据 |
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
| B22 | TODO | — |
| B23 | TODO | — |
| B24 | TODO | — |
| B25 | TODO | — |
| B26 | TODO | — |
| B27 | TODO | — |

| 验收ID | 状态 | 结果/命令/证据 |
|---|---|---|
| T01 | TODO | — |
| T02 | TODO | — |
| T03 | TODO | — |
| T04 | TODO | — |
| T05 | TODO | — |
| T06 | TODO | — |
| T07 | TODO | — |
| T08 | TODO | — |
| T09 | TODO | — |
| T10 | TODO | — |
| T11 | TODO | — |
| T12 | TODO | — |
| T13 | TODO | — |
| T14 | TODO | — |
| T15 | TODO | — |
| T16 | TODO | — |
| T17 | TODO | — |
| T18 | TODO | — |
| T19 | TODO | — |
| T20 | TODO | — |
| T21 | TODO | — |
| T22 | TODO | — |
| T23 | TODO | — |
| T24 | TODO | — |
| T25 | TODO | — |
| T26 | TODO | — |
| T27 | TODO | — |
| T28 | TODO | — |
| T29 | TODO | — |
| T30 | TODO | — |
| T31 | TODO | — |
| T32 | TODO | — |
| T33 | TODO | — |
| T34 | TODO | — |
| T35 | TODO | — |
| T36 | TODO | — |
| T37 | TODO | — |
| T38 | TODO | — |
| T39 | TODO | — |
| T40 | TODO | — |
| T41 | TODO | — |
| T42 | TODO | — |
| T43 | TODO | — |
| T44 | TODO | — |
| T45 | TODO | — |
| T46 | TODO | — |
| T47 | TODO | — |
| T48 | TODO | — |
| T49 | TODO | — |
| T50 | TODO | — |
| T51 | TODO | — |
| T52 | TODO | — |
| T53 | TODO | — |
| T54 | TODO | — |
| T55 | TODO | — |
| T56 | TODO | — |
| T57 | TODO | — |
| T58 | TODO | — |
| E01 | TODO | — |
| E02 | TODO | — |
| E03 | TODO | — |
| E04 | TODO | — |
| E05 | TODO | — |
| E06 | TODO | — |
| E07 | TODO | — |
| E08 | TODO | — |

## 会话交接模板
- 日期、实际 HEAD/分支、工作区、SDK/macOS/设备。
- 当前阶段、G/B/T/E、修改文件、真实调用链、已接线事件及未覆盖分支。
- 执行命令、退出码、测试统计及实际测量（样本数、p50/p95、内存/磁盘、丢弃率）。
- 脱敏诊断包证据、已验证范围、缺口及风险。
- 当前阻塞、解除条件、下一步。

状态：TODO / IN_PROGRESS / IMPLEMENTED（真实接线）/ TESTED（相关自动化实测）/ PENDING_INTEGRATION（真实环境待验）/ VERIFIED（全部适用验收有证据）/ BLOCKED（原因明确）。不得以单一测试关闭全部阶段。
