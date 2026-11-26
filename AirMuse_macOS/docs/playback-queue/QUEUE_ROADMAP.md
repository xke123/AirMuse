# 实施路线图

状态 TODO / IN_PROGRESS / IMPLEMENTED / VERIFIED / BLOCKED；VERIFIED 必须记录实际测试证据。每个阶段完成后更新 PROGRESS。

| 阶段 | 任务 | 依赖 | 验收 |
|---|---|---|---|
| P0 | VERIFIED: 复核 HEAD (`f494b09`)、全部调用链与现有来源模型、构建基线 | 无 | 记录提交、差异、测试结果 |
| P1 | VERIFIED: Q01 队列条目模型、唯一 ID、快照；Q16 历史结构 | P0 | `QueueManagerTests` 通过 |
| P2 | VERIFIED: Q02 顺序、Q03 随机、Q04 单曲循环、Q05 列表循环、Q16 前后推进 | P1 | `QueueManagerTests` & `PlaybackCoordinatorQueueTests` 通过 |
| P3 | VERIFIED: Q06 清空、Q07 指定播放、Q08 删除、Q09 拖拽、Q10 头部移动、Q11 尾部移动、Q15 批量、Q20 安全撤销 | P2 | `QueueManagerTests` & `LiquidFusionQueueDockTests` 通过 |
| P4 | IMPLEMENTED (单元测试 VERIFIED / 真实 AMP 接口待人工): Q12 追加、Q13 下一首、Q14 整批加入、Q18 分页 | P3 | `QueuePaginationTests` 通过 |
| P5 | IMPLEMENTED (单元测试 VERIFIED / 真实账户与电台实测待人工): Q01 结构订阅接入、Q17 持久化、Q19 电台能力及账户隔离 | P2–P4 | `PlaybackCoordinatorQueueTests` 通过 |
| P6 | IMPLEMENTED (单元测试 VERIFIED / 实机玻璃视觉与交互待人工): Q01–Q15、Q19、Q20 的原生 UI 接入 | P5 | `LiquidFusionQueueDockTests` 通过 |
| P7 | VERIFIED (自动化回归与性能基准完成 / 实机人工验收项已列出): 全量 Q01–Q20 独立审查、性能及真实环境回归 | P6 | 全量 `swift test` & `QueuePerformanceTests` 通过 |

优先级：Q01–Q09、Q12–Q13、Q16、Q18–Q19 为 P0；Q10–Q11、Q14–Q15、Q17 为 P1；Q20 为 P2，安全撤销不可行时记录原因及确认降级。不要因 P2 阻塞核心功能。现有测试不得删弱。源码修改以现有目录和模块为准，建议 QueueManager.swift、QueueSnapshot.swift、QueueCapabilities.swift、UI/Library/PlaybackQueue/，避免机械建文件。

最终交付：实际改动路径、调用链、模式决策、测试命令和结果、截图/录像（如可获得）、性能前后对比、待人工验收项。
