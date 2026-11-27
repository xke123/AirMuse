# LOG — 执行路线
源码基线：`791ae679d8e1c7fc03252f57dc4cef09c13a7005`（main，2026-11-28 06:24:47 北京时间）。实施前复核 HEAD。本文为实施规范，不是已完成的生产功能或实测结果。

| 阶段 | 依赖 | 实施与退出门槛 | 状态 |
|---|---|---|---|
| LOG00 | 无 | 复核HEAD/SDK/工作区；全仓 log/print/OSLog/JS/try? 与生产调用点清单、事件覆盖分母、现有构建及性能基线 | VERIFIED |
| LOG01 | 00 | 类型化 schema、上下文、Trace 传播、错误、兼容入口；Domain/Infrastructure 无环 | TESTED |
| LOG02 | 01 | 白名单脱敏、有界 ring、单 writer、轮转、gap、订阅、删除及退出 | TESTED |
| LOG03 | 02 | Registry、Session、Auth、Adapter、HTTP/AMP、Application browse/search/actions、StateStore 全出口 | TESTED |
| LOG04 | 02,03 | EngineRouter lease、Coordinator、QueueManager、pagination、station、事件接收/拒绝、检查点差量 | TESTED |
| LOG05 | 03,04 | Origin/Navigation、Lyrics、Artwork/Cache/DB、snapshot 持久化、账户/来源安全 | TESTED |
| LOG06 | 02,04 | UI/Motion/Window/Glass、OSSignpost 与真实性能聚合，关闭高频噪音 | TESTED |
| LOG07 | 03–06 | owner 快照与不变量、超时/部分/失败、不影响业务 | TESTED |
| LOG08 | 02,07 | 通用 Diagnostics Center、过滤/Trace、导出一致性及安全、主动探测隔离 | TESTED |
| LOG09 | 全部 | 全量回归、独立 FixtureHost、真实账户及实机、压力/泄漏/隐私/性能证据 | PENDING_INTEGRATION |

每阶段更新本表及 PROGRESS，写出实际改动、生产调用链、事件覆盖和验证证据。阶段门禁：可构建、定向测试、全量测试、独立审查；涉及真实环境不具备时标 PENDING_INTEGRATION，不阻塞独立任务。禁止改业务仅为让日志看起来成功。基线已存在缺陷单独列台账；无关修复另开任务。
