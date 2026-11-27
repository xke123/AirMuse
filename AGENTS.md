# AirMuse — Observability & Diagnostics

## 唯一活动任务
实现平台无关、全链路、可重建业务因果的本地诊断系统。基线 `791ae679d8e1c7fc03252f57dc4cef09c13a7005`。禁止重做已存在的播放器、平台适配器、应用服务、队列、来源、视觉系统；其他任务不构成本期指令，既有功能不得回退。

## 执行方式
先读 `AirMuse_macOS/docs/observability/` 全部十份 LOG 文档。GOALS 定范围，BASELINE 定证据，CONTRACTS 定事件格式与因果，EVENTS 定全量覆盖，PIPELINE 定采集存储，PRIVACY 定隐私，DIAGNOSTICS 定快照/窗口/导出，ROADMAP 定依赖，TESTS 定验收，PROGRESS 定实际状态。隐私规则优先于详细度；业务真实状态优先于展示。

1. 检查分支、HEAD、git status、SPM 依赖、SDK，扫描全部 Swift/JS 日志、print、OSLog、try?、catch、guard、任务和事件出口。保留用户修改，复核基线，不重复实现。执行原有构建及测试，记录真实证据。
2. 按 LOG00–LOG09 实施，每阶段生产接线、定向及全量回归、独立代码审查、更新 ROADMAP/PROGRESS。不能仅生成空协议、测试 fixture 或打印成功。不能以模拟播放替代真实音频、以快照采集替代实际状态机测试。
3. 新日志须使用稳定事件名、类型化字段、run/sequence、trace/span/parent、操作及会话代数、明确 outcome；从 UI 点击追踪真实提交/拒绝/引擎确认/反馈。所有异步出口都有可辨识原因，尤其取消、过期、超时未知、失败及重试。不能仅靠文本猜测因果；不能重新生成业务 ID 伪装真实上下文。
4. 复用 `AppLogger` 单入口、`AppSignpost`、现有 `EngineRouter`、`ProviderSessionRegistry`、`ApplicationServices`、`MediaResourceStateStore`、`PlaybackCoordinatorV2`、`PlaybackStore`、`QueueManager`、`QueuePaginationLoader`、`PlaybackOrigin` 等。诊断依赖只向 Domain 契约和 Infrastructure，不反向依赖 UI/Providers；FixtureHost 不链接 Apple Music 仍可诊断。具体平台字段由 Adapter 产生。
5. 严格区分命令接受、网络接受、状态确认、引擎报告播放、实机音频输出证据。记录音频 lease、候选引擎、routingGeneration、停止/隔离证据；不能假称实际听到声音。电台 station ID/seed/current item 分离；远端未知队列非零；来源导航无播放副作用；所有状态事件由权威所有者发布。
6. 日志只观察，不改变调度、业务状态、权限或音频；不得为诊断发起自动平台写入、播放、WebKit 初始化。实有缺陷单独记录；仅修复与诊断接线直接相关的问题，不隐蔽改变产品行为。自检默认只读本地；主动网络探测单独确认、独立 trace。
7. 任何模式都禁止凭证、Cookie、认证回调参数、原始请求响应、网页/JS 注入原文、Keychain、私人路径进入缓冲/磁盘/控制台/OSLog。使用类型化白名单、引用映射，默认可分享导出脱敏；无上传、无自动联网。原始敏感字段不可通过用户开启 Full Trace 解锁。
8. 日志入口不进行磁盘 I/O、网络、MainActor 布局或等待写入；不一条日志创建一个 Task；有界环形缓冲、单写入者、批量刷盘/通知、优先保留业务状态与错误、显式丢弃/覆盖计数。禁用类别时不构造昂贵载荷；不可为了诊断复制万条队列或每帧日志。Swift 6 严格并发，不新增 unchecked Sendable/unsafe/detached 掩盖问题。
9. 保留原水晶皮肤、Original/Enhanced、Normal/Mini、歌词、来源与自适应队列。诊断 UI 不依赖具体平台；隐藏后停止渲染，暂停显示不暂停采集；过滤/导出不得阻塞播放。无新商业 SDK、远程采集、其他平台接入、混合队列或无关重构。
10. 不擅自提交、推送或覆盖工作区。测试与实际指标必须真实，未取得数据标 unavailable。状态 TODO / IN_PROGRESS / IMPLEMENTED / TESTED / PENDING_INTEGRATION / VERIFIED / BLOCKED。最终按 G/B/T/E 报告证据、覆盖率分母、丢失情况、剩余阻塞及工作区状态。
