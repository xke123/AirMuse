# PO — 实施路线

| 阶段 | 状态 | 依赖 | 必须交付与完成门槛 |
|---|---|---|---|
| PO00 | VERIFIED | 无 | 复核实际 HEAD、B01–14、AGENTS 作用域、SDK、构建及测试基线；列所有播放/电台/导航/恢复入口与真实能力，记录已修复项 |
| PO01 | TESTED | PO00 | 向后兼容来源模型及 typed route，捕获点击上下文、分页、历史与重复歌曲；P01–P08、P34–P36 |
| PO02 | TESTED | PO01 | 单一远端电台目标、种子与实际 item 区分、事件/能力/transport 一致性，修复混合卡片列表；P09–P18 |
| PO03 | TESTED | PO02 | 统一确认及原子模式切换，stage-only、不自动恢复、旧 stop/分页无副作用；P19–P25 |
| PO04 | TESTED | PO01, PO02 | 纯内部 route、来源菜单、去重、目标冻结、定位和安全降级；P26–P33 |
| PO05 | TESTED | PO03, PO04 | 双玻璃宿主、普通/电台面板及所有入口能力联动，原生适配；P37–P40 |
| PO06 | TESTED | PO02–05 | 低频投影、持久化、取消、生命周期、性能及差量刷新；P34–P42 |
| PO07 | PENDING_INTEGRATION | PO01–06 | 全量构建、回归、独立审查及 E01–E08 真实验收，逐项关闭 B/G |

PO02/03 的业务正确性优先于新 UI。PO04 可并行实现纯路由。真实电台测试无法执行时，明确标 PENDING_INTEGRATION，按保守能力继续独立开发；不能以此跳过确定性测试。阶段完成后记录实际文件/调用链、测试命令/退出码、证据及下一任务。禁止仅改文档宣称完成。

## 测试执行建议
在真实项目工作区使用 `cd AirMuse_macOS && swift test`（先核对 Package.swift / SDK 实际要求），定向测试依据现有 test target 命名。新增测试覆盖真实生产入口及 mock engine/Provider/可控时钟；不得用固定 sleep 代替事件屏障。测试、实机及性能结论分开。无法运行 macOS/SDK 时记录阻塞，不虚构执行。
