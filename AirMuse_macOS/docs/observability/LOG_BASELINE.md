# LOG — 最新源码基线与问题台账
源码基线：`791ae679d8e1c7fc03252f57dc4cef09c13a7005`（main，2026-11-28 06:24:47 北京时间）。实施前复核 HEAD。本文为实施规范，不是已完成的生产功能或实测结果。

提交：`feat(platform-decoupling): decouple music platforms from presentation and runtime`。相比 `3daa253`，最新变更包含 Application、PlatformRuntime、FixtureHost、AppleMusicIntegrationUI、ResourceIdentity、PageContracts、EngineRouter、ProviderSessionRegistry。PD_PROGRESS.md 自报 `swift build --product FixtureHost && swift run FixtureHost`、`swift build --product AirMuse`、`swift test` 成功（39 suites / 197 tests）；E01–E08 仍待实机。此处未独立运行。源链接统一为 `https://github.com/xke123/AirMuse/blob/791ae679d8e1c7fc03252f57dc4cef09c13a7005/AirMuse_macOS/` + 下列路径。

| ID | 证据（Sources/ 下路径） | 本期要求 |
|---|---|---|
| B01 | Infrastructure/Logging/AppLogger.swift:35–58，LogEntry 自由文本 | 稳定结构化 schema、受控字段、事件名、outcome |
| B02 | 同文件 132–163，lock 内 appendToRotatingLogFile | 入口无 I/O，单 writer，有界缓冲 |
| B03 | 同文件 97、106–107、207–247，5000 条、2MiB+2轮转 | 明确预算、跨文件索引、gap 记录、失败可见 |
| B04 | 同文件 177–203，exportMarkdown 仅内存 | 全保留区间、旋转段+未刷盘尾部一致导出 |
| B05 | 同文件 102、153–162，单 onNewEntry 可变回调 | 有界多订阅、生命周期、顺序与游标 |
| B06 | 同文件 171–175 clear 仅内存 | 清空视图与删除历史明确分开 |
| B07 | 同文件 123、188–192，硬编码环境与旧命名 | 真实 build/commit/OS/arch；无信息标 unknown |
| B08 | Infrastructure/Logging/LogSanitizer.swift:8–33，固定正则；LogEntry.correlationID 未脱敏 | 类型化白名单、覆盖所有 sink/字段/错误链 |
| B09 | UI/Log/LogWindowController.swift:46–54，已改注入 diagnosticFetch/diagnosticsProvider | 保留无平台直接依赖；替换为通用结构化采集器，不回退 |
| B10 | 同文件 169–195，逐条富文本追加+getEntries+滚动 | 虚拟化/有界列表、批量更新、隐藏取消订阅 |
| B11 | 同文件 279–334，复制内存日志；自检仍可主动请求榜单 | 导出全部保留段；只读本地快照与主动探测分离 |
| B12 | App/AppLifecycleCoordinator.swift:73–88，注入 Apple Music 榜单及文本快照，失败 cacheBytes 兜底0 | 快照由注册的 owner 提供；失败不是0 |
| B13 | PlatformRuntime/EngineRouter.swift:68–143，候选准备、激活、事件过滤，无 AppLogger 调用 | 记录 switch/lease/generation/accepted-discarded，跨 await 决策 |
| B14 | 同文件 147–179、205–235，停止、丢弃、执行、隔离 | 停播确认依据与异常、实际路由、释放证据；不假报 audible |
| B15 | PlatformRuntime/ProviderSessionRegistry.swift:60–120、127–164、196–217，无 AppLogger 调用 | 注册、激活、会话代数、发布、退出、释放全过程 |
| B16 | Application/ApplicationServices.swift:27–78、92–147，浏览/搜索/分页/关系 | route/资源作用域/代数、合并、失败与过期 |
| B17 | 同文件 162–215、239–288，意图、跨平台限制、资源写路由 | 记录源/目标平台、权限、接受与拒绝、最终结果 |
| B18 | 同文件 304–343，来源导航/账户 | 区分浏览和播放平台、账户入口与结果 |
| B19 | Application/MediaResourceStateStore.swift:194–247、271–351、386–471、586–650，无直接 AppLogger；部分 try? | 字段 revision、confirmed/desired、合并/丢弃/核对、scope、磁盘保存；失败不能静默 |
| B20 | Playback/PlaybackCoordinatorV2.swift:203–299、307–389、1001–1094，已有文本日志；快照保存 try? | 绑定真实 op/queue/lease；停止、保存结果及错误；区分 accepted/confirmed |
| B21 | Playback/QueuePaginationLoader.swift，已改通用 cursor | 页请求/返回/实际提交、cursorRef、retry、批次失效；不输出原游标 |
| B22 | Providers/AppleMusic/AppleMusicAdapter.swift:216–247，平台电台及 DTO mapping | Adapter 边界/映射统计、能力与授权，不泄漏平台 DTO |
| B23 | Infrastructure/Networking/HTTPClient.swift、Providers/AppleMusic/AppleMusicAmpClient.swift | 两条网络路径统一 request/attempt/trace，禁止重复计数与完整URL |
| B24 | Providers/AppleMusic/Session/SessionCoordinator.swift、Playback/WebRuntime.swift、Playback/WebBridge.swift | 登录/恢复/桥接拒绝、WebKit导航与生命周期全出口 |
| B25 | Lyrics/LyricsRepositoryV2.swift、Lyrics/PublicSyncedLyricsProvider.swift | 歌词源/匹配/取消/耗时，绝不记录歌词正文 |
| B26 | UI/Dock/UnifiedStageController.swift、UI/Library/PlaybackQueue/LiquidFusionQueueDockView.swift | 模式/菜单/动画代数、命中/释放/聚合帧耗时 |
| B27 | Infrastructure/Diagnostics/AppSignpost.swift:18–29 | 实际区间、失败/取消均闭合，与 trace 关联但不伪造 GPU 指标 |

B01–B20 基于本次查看的实际文件/函数；B21–B27 为前次审查与本次变更清单支持的覆盖审计入口，LOG00 必须逐文件复核现行实现及行号，不预先宣称全部为确定 bug。全面扫描未完成，不可用本表代替全仓调用点盘点。
