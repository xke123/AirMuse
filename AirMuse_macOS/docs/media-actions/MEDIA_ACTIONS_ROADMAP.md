# 实施路线与状态
初始全部 TODO，执行时逐项更新；不以文档勾选代替证据。

| ID | 阶段 | 交付 | 依赖 | 状态 |
|---|---|---|---|---|
| MA00 | 基线 | HEAD、调用链、SDK、测试、能力证据 | 无 | VERIFIED |
| MA01 | 模型 | 类型化资源/位置/权限/动作描述，纯 Resolver | MA00 | TESTED |
| MA02 | 播放 | 复用 submitIntent 四意图、原子随机替换扩展、明确顺序模式、分页与竞态回归 | MA01 | TESTED |
| MA03 | 菜单 | 卡片、曲目、搜索、艺人、队列统一 NSMenu | MA01–02 | TESTED |
| MA04 | 导航 | 内部专辑/歌手/歌单/可用电台路径 | MA01 | IMPLEMENTED |
| MA05 | 平台读 | 真实状态查询与资源映射、共享缓存 | MA00–01 | TESTED |
| MA06 | 资料库 | 安全添加/移除、归属保护、联动核对 | MA05 | PENDING_INTEGRATION |
| MA07 | 收藏 | 复用 setArtistRating，修复失败状态；扩展其他资源收藏/取消、串行与异常核对 | MA05 | PENDING_INTEGRATION |
| MA08 | UI | 播放胶囊、一级按钮、反馈、双模式/辅助功能 | MA02–07（可独立推进） | TESTED |
| MA09 | 验证 | 全量测试、实际运行、性能、独立审查 | 前述 | PENDING_INTEGRATION |

各阶段必须有代码、接入路径和对应 TESTS；构建和相关测试通过后推进。平台真实写能力阻塞仅影响对应任务，不妨碍播放/导航/菜单。禁止以模拟实现代替真实 provider。状态：TODO 未开始；IN_PROGRESS 开发中；IMPLEMENTED 已接生产；TESTED 自动化通过；PENDING_INTEGRATION 真机/账号待验证；VERIFIED 所有相关验收有证据；BLOCKED 明确原因及复现/解除条件。最终 DoD：功能矩阵逐项完成或明确不可用与原因，核心四种平台写操作未验证不得称全量完成；无新增队列回归、无越界功能、无假成功；保留现有外观与生命周期。记录全部证据。
