# LOG — 事件、Trace 与状态契约
源码基线：`791ae679d8e1c7fc03252f57dc4cef09c13a7005`（main，2026-11-28 06:24:47 北京时间）。实施前复核 HEAD。本文为实施规范，不是已完成的生产功能或实测结果。

## Schema v1
`DiagnosticEvent` 为 Sendable/Codable；禁止 `[String: Any]`。Domain 可定义诊断协议/数据类型，Infrastructure 提供实现。事件名称采用 `domain.object.verb` 小写稳定命名，兼容事件映射保留旧 category；不以中文 message 做查询主键。

| 字段 | 类型与约束 |
|---|---|
| schemaVersion,eventName,category,level | Int、稳定字符串、枚举；未知版本安全读取/明确不支持 |
| runID,eventID,sequence | 每进程运行 UUID、事件 UUID、入口分配单调序列；跨运行不比较 sequence |
| timestamp,monotonicTimeNs | UTC ISO8601 含小数秒；运行内单调时钟偏移（非 Unix 时间） |
| traceID,spanID,parentSpanID,links | 操作根 UUID、区间 UUID、可选父、关联的原 trace/event；后台任务独立根或继承明确上下文 |
| phase,outcome,durationMs | begin/end/instant；accepted/confirmed/succeeded/failed/rejected/cancelled/superseded/discarded/unknown/unsupported/partial；耗时只用单调时钟 |
| context,fields | 下表类型化白名单；可选值缺失不是 false/0；限大小和嵌套 |
| error | domain,code,stage,retryable,underlyingCode,safeSummary；无原始 NSError userInfo/URL/response |
| source | module/component/function，必要时编译期 fileID/line（不记录绝对路径） |
| message | 由结构化字段生成的本地化简述；旧文本只经过适配及脱敏 |

上下文按实际所有者捕获，使用真实业务 ID（不得新造假 ID）：providerID、browsingProviderID、playingProviderID、operationProviderID；accountRef/storefront、sessionID/sessionGeneration；engineInstanceID、candidateEngineID、routingGeneration、leaseRef、switchRef；playbackGeneration、transportRevision、operationID、intentID；queueID/revision/destructiveEpoch、entryID/batchID；stationRef/seedRef/currentItemRef/itemSequence；resourceRef/resourceKind/scopeRef；navigationGeneration/browseGeneration、mutationID/fieldRevision；requestID/attempt、animationID/windowRef。真实尚无某个 ID 时标 absent，诊断可生成 trace/span 但不能称为业务 ID。稳定引用由 PRIVACY 统一。

## 因果传播
- UI 用户入口建立根 Trace；同一个点击经 ApplicationServices → Registry → Adapter/HTTP → EngineRouter/Coordinator → Store → UI 反馈传递显式上下文。TaskLocal 可辅助结构化调用，跨非结构化 Task、actor、回调、队列、JS bridge、AsyncStream 时必须显式捕获并重新绑定；禁止依赖线程局部变量。
- 一个请求重试使用同 requestID、新 attempt/span；批次分页保持 batchID/根 trace，新 page span；合并请求记录 consumer trace links 和 owner requestID，不能伪造多次 HTTP 传输。
- 自动切歌、系统媒体键、恢复、后台刷新各自建立真实 root，关联前置播放 operation/queue；不要把无限长播放会话当一个 trace。
- begin 必须有一个 terminal outcome（defer/结构化 helper），取消与过期也结束；崩溃或截断时 manifest 标 incomplete。记录发生时上下文、入口 sequence、写入顺序和 timestamp；sequence 缺口需计数。跨 actor 无全局事务时只声明各自时点，不用墙钟顺序替代因果。
- 权威状态 owner 在真实提交后记录 before/after revision；UI 只记录接收与渲染，不重复伪造业务成功。记录 accepted != confirmed != audible；引擎报告 playing 只能叫 engine-confirmed。
- 每个 guard 拒绝记录 reasonCode 与 expected/actual（脱敏），包括 session、scope、provider、queue、epoch、intent、engine、route、mutation revision。正常 superseded/cancelled 不升 ERROR；重复高频丢弃可聚合数量、首尾和原因。

## 等级与模式
TRACE 细粒度，DEBUG 内部决策，INFO 业务转换，NOTICE 生命周期/恢复，WARN 可恢复异常，ERROR 失败，FAULT 不变量。模式 Normal/Debug/FullTrace/Performance；Release 默认 Normal，开发默认 FullTrace（可关）；Performance 主要区间聚合并保留核心事件。禁止在 disabled level 计算昂贵 payload；所有模式遵守隐私。关键业务终态/权限拒绝/状态转换/lease/错误高优先级，不静默采样；高频进度/帧/桥接噪音按区间聚合，报告采样策略。

## 可重放队列
队列 checkpoint 记录 owner、scope、queueID、revision、epoch、activeTarget、confirmed/pending、ordered upcoming、baseline、history、batch anchors/loading、shuffle requested/effective、repeat、entryID->resourceRef/originRef。diff 必须含 from/to revision、变更条目顺序及插入锚点、移除位置、状态差量；随机记录实际结果顺序，不只 RNG seed。大批量分片含 partIndex/partCount/commitID+完整性校验；在有界预算内只在 FullTrace 及显式快照做完整检查点。轮转覆盖检查点时保留后续检查点或标 replayUnavailable。遇 gap 不声称能重建任意区间。敏感信息以引用表示，不重放网络或写入业务。
