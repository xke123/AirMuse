# LOG — 目标与范围
源码基线：`791ae679d8e1c7fc03252f57dc4cef09c13a7005`（main，2026-11-28 06:24:47 北京时间）。实施前复核 HEAD。本文为实施规范，不是已完成的生产功能或实测结果。

## G01–G08
| ID | 目标 | 完成门槛 |
|---|---|---|
| G01 | 统一事件与因果 | 一次操作在 UI/Application/Runtime/Adapter/Engine/Store 共享 trace，异步边界有父子关系或显式 link |
| G02 | 全业务覆盖 | LOG_EVENTS 中适用事件有真实生产调用点，未实现能力标 N/A 与理由；不存在只写成功分支 |
| G03 | 可重建队列与状态 | 任意完整保留区间可由检查点+连续差量恢复顺序、来源、历史、pending 与 batch；缺口明确 |
| G04 | 多平台诊断 | Registry、Application、EngineRouter、账户、权限、音频权与平台操作可追踪；FixtureHost 独立运行 |
| G05 | 安全与可靠 | 全 sink 预脱敏、限制容量、记录丢弃与 I/O 失败、清理语义一致 |
| G06 | 可定位故障 | 有界只读模块快照、不变量、错误链、性能聚合与时间线 |
| G07 | 调试体验 | 筛选、暂停、跟随、Trace、详情、快照、摘要及完整 ZIP；不干扰播放 |
| G08 | 性能与兼容 | 现有 API 渐进迁移、原功能无回归、量化关闭/Normal/Full Trace 三档开销 |

Full Trace = 保留预算内尽量完整的关键业务决策、状态与差量，并提供完整性证明；不是全网络原文、逐帧或无限留存。未知、取消、拒绝、过期、未采集、已脱敏、失败、成功必须区分。不可从日志推断音频实际可听，除非有实际设备测量。

## 范围
生产 App、FixtureHost、Domain/Infrastructure/PlatformRuntime/Application/Playback/Lyrics/DesignSystem/UI、AppleMusicAdapter 及其专用运行环境。现有 Spotify/QQ 实现只审计实际生产接入路径，不要求接入或猜测能力。只读诊断无额外平台 API；显式主动网络探测可选且不可写。保留用户视觉体系；不重建业务架构、不接入云遥测、不自动上传。当前提交已完成解耦的主要模块迁移，不按旧路径重新迁移。
