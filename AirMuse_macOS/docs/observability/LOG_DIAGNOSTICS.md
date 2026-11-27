# LOG — 状态快照、不变量、诊断中心及导出
源码基线：`791ae679d8e1c7fc03252f57dc4cef09c13a7005`（main，2026-11-28 06:24:47 北京时间）。实施前复核 HEAD。本文为实施规范，不是已完成的生产功能或实测结果。

## 快照
模块通过只读 `DiagnosticSnapshotProvider`（示意）注册；快照包含 component、capturedAt、monotonic、ownerRevision、scopeRef、availability(available/unavailable/timeout/partial)、data。并发有界、每组件超时、总超时与容量上限，禁止跨 actor 伪造全局原子状态；关键快照可从同一 owner 原子读。无音频/网络写入/额外 WebKit，不激活未用平台。按需触发、FAULT 合并去重，不每条日志快照。

| Owner | 必须字段 |
|---|---|
| App | 实际版本/commit/运行时/SDK（构建注入，否则未知）、模式/运行时间 |
| ProviderSessionRegistry | 注册、激活、浏览平台、会话状态/代数、订阅数量 |
| EngineRouter | 活动/候选引擎、handoffState、routingGeneration、lease 证据、事件过滤计数 |
| PlaybackCoordinatorV2 / PlaybackStore | desired/actual、确认级别、目标、operation/generation/revision、低频 transport |
| QueueManager | 完整脱敏检查点，confirmed/pending/upcoming/history/baseline/batches/owner/caps |
| Station / Origin | station/seed/current item 三身份、来源与真实导航目标、未知待播 |
| ApplicationServices | 活动 route/search/navigation/intent、代数与取消统计 |
| MediaResourceStateStore | scope、confirmed/desired/revisions、pending/read/write/observer 与缓存预算 |
| HTTPClient / AMP | 活动请求及尝试、并发、重试、限流与聚合耗时 |
| QueuePaginationLoader | 活动批次、失败游标引用、页数/边界/重试 |
| Lyrics/cache/database | 命中/容量/源/事务/失败，缺失明确 unavailable |
| UI / Motion | 窗口/布局/交互模式/动画代数/材质/可访问性 |
| Logger | 策略、sequence 范围、采集/过滤/采样/丢弃/写入/轮转/导出统计 |

## 不变量（只观察，不改业务）
INV01 单音频 lease；INV02 播放资源匹配活动引擎及会话；INV03 来源属于已确认条目；INV04 单平台队列一致；INV05 私人资源作用域；INV06 旧会话/路由事件不得提交；INV07 队列 UUID 唯一；INV08 旧分页不得填充新/已清空队列；INV09 旧写/读不覆盖新 Pending；INV10 远端未知不伪造本地队列；INV11 电台恢复目标不是当前 item；INV12 导航不主动改变播放；INV13 未授权不可写；INV14 过期动画不得操作销毁窗口；INV15 非活动引擎资源有界。基于真实 owner/因果 evidence，不用不同时间的快照硬比；无法验证标 unknown；FAULT 合并并附快照，Release 不因诊断误报崩溃，不将 lease 当实机音频测量。禁止静默修复业务。

## UI
保留现有 LogWindowController 注入式入口，不重新 import Providers。通用列表按时间/等级/category/provider/trace/eventName/资源引用筛选，虚拟化/有界批量、选择详情、Trace timeline、实时跟随开关、暂停显示（仍采集）、恢复按 cursor 补齐、清空视图与删除历史分开。隐藏或销毁取消渲染订阅，恢复时读取一致快照。三个页签：事件/状态快照/性能，支持键盘/VoiceOver、原皮肤、窄窗。诊断默认本地只读；现有 diagnosticFetch 榜单网络自检迁移成显式主动网络探测、用户确认、独立 Trace、按当前平台能力；FixtureHost 无音源也能使用。性能图标示来源、样本、时间区间、缺失状态，不构造模拟数字。

## 导出目录
```text
AirMuse_Diagnostics_<runRef>/
  manifest.json
  summary.md
  environment.json
  events/events-0001.jsonl ...
  snapshots/<component>.json
  traces/trace-index.json
  performance/<metric>.json
  faults/invariant-violations.jsonl
```
manifest 必含 schemaVersion、build/commit、captureMode/policy、runIDs、requested/retained/exported sequence & time ranges、highWatermark、per-level/category counters、gap/evicted/excluded/sampled ranges、快照组件状态、重放可用范围、脱敏规则版本、文件清单/sha256、exportOutcome（completeWithinRetention/partial/failed）。完整是指保留范围内且明确缺口，不承诺全部历史。summary.md 给 AI 的首读入口：环境、故障时间、最近失败 trace、因果链、状态、待核对证据、缺失原因；不能自动猜根因。支持复制摘要、选中 Trace（包含必要 parent/link 与检查点）、完整 ZIP。所有导出路径受 PRIVACY，取消/磁盘满/打包失败可见，临时文件清理，不伪造成功。
