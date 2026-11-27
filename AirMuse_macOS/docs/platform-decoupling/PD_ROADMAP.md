# PD — 实施路线与依赖

初始全部 TODO。每阶段满足出口后才推进依赖任务；可并行无依赖任务，但不得跳过门槛。状态以 PROGRESS 实证同步。

| 阶段 | 依赖 | 工作包与交付 | 出口门槛 | 状态 |
|---|---|---|---|---|
| PD00 Baseline | 无 | 实际 HEAD、工作区、SPM 图、全仓平台依赖扫描、生产调用链、测试/性能基线、B01–B21 复核 | 可复现记录；环境限制明确 | VERIFIED |
| PD01 Identity | PD00 | 统一资源/作用域/route/target/unknown、可信旧数据迁移；B05–B08/B21 | 同 ID 跨平台/账户、旧快照、来源保留测试 | TESTED |
| PD02 Contracts | PD01 | 能力、错误、PageCursor、细粒度协议、Fixture 契约；B11–B14/B17 | 不支持不假成功；类型无专有 DTO；游标隔离 | TESTED |
| PD03 Apple Adapter | PD02 | AMP 映射、资源接口、鉴权及引擎 factory、第三方歌词边界；B03/B08/B13–B14/B19 | Apple Music 生产等价路径；Adapter 测试；真实账户待实机独立记录 | TESTED |
| PD04 Application | PD03 | Browse/Search/Collection/MediaAction/Navigation/Account/PlaybackIntent，迁移状态 Store；B04–B06/B15 | Controller 不做平台业务；Fixture 通过同一应用服务 | TESTED |
| PD05 Presentation | PD04 | 通用页面模型，授权 presenter 隔离，SPM 拆分；B01/B16 | 无 Apple Adapter 的独立宿主构建与 UI 启动；现有视觉回归 | TESTED |
| PD06 Runtime | PD02、PD03、PD05 | Registry/lazy activation/session scope，组合根与生命周期；B02/B03/B15 | 无平台启动；浏览与播放隔离；独立注销；无常驻非活动引擎 | TESTED |
| PD07 Audio routing | PD06 | 单音频权 Router、事件路由、切换事务/失败屏障、修复暂存竞态；B09/B10/B21 | 两个测试引擎受控竞态、无双音频、真实失败状态 | TESTED |
| PD08 Origin/Queue | PD07 | 单平台队列校验、来源跨浏览导航、远端能力与适应面板、快照/动画；B05–B08/B11/B12/B18/B20 | 五意图、电台、队列、菜单、持久化及视觉无回退 | TESTED |
| PD09 Verification | PD01–PD08 | 全量测试、依赖闭包、Fixture host、实机 Apple Music 与性能、独立审查 | G01–G08、B01–B21、R01–R52、E01–E08 逐项证据；阻塞如实保留 | PENDING_INTEGRATION |

每个阶段：先验证实际文件与调用者 → 添加失败回归 → 最小生产接线 → 定向测试 → 全量测试/构建 → 审查依赖与副作用 → 更新状态。允许真实账户验证与其他可确定任务并行；未实测的授权/音频/SDK 不能宣称完成。PD07 不得因 Router 测试通过忽略 Apple Music 实际音频隔离；PD05 不能以 grep 无 import 代替依赖闭包和独立链接测试。

建议提交单元（仅用户授权后提交）：身份/协议、Apple Adapter、服务拆分、SPM 边界、运行时、音频权、来源队列、验证。默认仅工作区改动，不推送。
