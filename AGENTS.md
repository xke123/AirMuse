# AirMuse — Platform & Presentation Decoupling

## 当前唯一活动任务
音源平台与播放器前端解耦。以 `3daa253b227e8905927e2c61e5009099e98c6ac1`（北京时间 2026-11-27 14:05:07）为参考基线，实际 HEAD 必须复核。保留单一播放器、队列、状态、资源操作、来源导航及双玻璃 Dock；把 Apple Music 封装成可注册、可按需激活和替换的适配器。通过 Apple Music + 独立测试音源验证整个链路。不是重写播放器、视觉升级或新增真实平台接入任务。

## 执行入口
每次会话先读本文件及 `AirMuse_macOS/docs/platform-decoupling/` 下全部十份 PD 文档：GOALS（范围）、BASELINE（证据）、CONTRACTS（身份与协议）、ARCHITECTURE（依赖及服务）、RUNTIME（生命周期及音频权）、MIGRATION（迁移与兼容）、UI_PERFORMANCE（前端及性能）、ROADMAP（实施）、TESTS（验收）、PROGRESS（实际记录）。其他文档不构成本期活动指令；不得回退已有功能。

1. 先检查 git status、HEAD、分支、diff、Package.swift、实际 SDK、构建与测试；保护用户改动。复核每条基线证据，已解决项只验证不重复修改。
2. 按 PD00–PD09 依赖实施，每阶段先建立确定性失败用例，再最小生产修改，运行定向与全量测试并独立审查。不得仅写计划、空协议、适配器外壳或演示 UI 代替真实接线。
3. 每阶段更新 PD_ROADMAP 与 PD_PROGRESS，记录文件、调用链、命令、退出码、测试、性能和阻塞。真实环境不可用时继续独立任务。不得弱化既有测试，不把仓库报告或 mock 当作本机实测。
4. 保持可构建、可回滚，不擅自提交、推送或改远程，不覆盖用户工作区，不篡改历史文档。若设计必须变化，先记录依据并同步本期规范。

## 强制架构和业务不变量
- Domain / Playback / Application / UI 不认识具体 Apple Music、AMP、Spotify、QQ API、Token、WebKit 脚本或 ID 前缀。App 组合根可以显式注册具体适配器；通用 UI 不依赖具体平台 Target（含传递依赖），平台专用授权 UI 由独立集成层注入。通过 SPM 依赖图与源码检查双重验收。平台差异通过类型化资源、协议和能力快照表达，不以平台名称分支驱动通用 UI。
- 保留 `PlaybackCoordinatorV2`、`PlaybackStore`、`QueueManager`、`QueuePaginationLoader`、`MediaActionResolver`、`PlaybackOrigin`、`QueueEntry`、`PlaybackSnapshotStore` 等有效生产机制。Application 为薄的业务编排，PlatformRuntime 为通用注册、会话和引擎路由；禁止第二播放器、第二队列、第二播放状态或并行缓存体系。依赖图无环，Playback 通过 Domain 协议调用 Router，Router 不反向依赖 Playback。
- 平台身份显式；资源身份由 provider + kind + opaque ID + scope 组成，私人身份绑定账户，目录绑定必要地区；QueueEntry UUID 独立。来源入队时冻结，分页、历史、随机、循环均保留；未知来源不默认 Apple Music。旧数据仅由可信作用域迁移。禁止根据名称、ID 前缀猜测平台、资源映射或删除目标。
- 浏览上下文、活动播放上下文、资源操作上下文和来源导航上下文独立。切换浏览不触发音频、队列、播放会话重建；播放按目标平台路由，收藏/资料库按资源所属平台路由，来源按原始平台及作用域跳转。注销一个平台不影响其他平台的独立播放/浏览/账户。
- 本期队列仅单平台、单可用账户作用域。普通播放替换可跨平台；跨平台追加/插播/队首/队尾默认明确拒绝，且不修改任何状态；不得静默换平台、混队列或发送其他平台 ID。远端电台退出暂存仅在同平台且满足确认契约时执行。不增加隐藏恢复队列或混合队列。实际播放权任一时刻只有一个引擎；旧引擎停止/隔离不能确认时，不启动新引擎。切换代数、会话代数、底层 engineInstanceID、operationID 均校验；禁止 `try? stop` 后假装交接成功。准备失败可保留仍真实发声的旧会话，停止后失败如实显示，不自动恢复旧音频。
- 电台资源 ID、种子资源、当前动态歌曲三者分离；内容类型与队列所有权独立；能力由平台、资源、会话、引擎证据共同决定。未知保守，待播未知不是 0，禁止虚构列表、混入其他电台、把动态歌曲 ID 用于电台恢复。普通队列与远端面板保留，所有控制入口复用能力校验。
- 五种已有播放意图及完整集合语义保留。游标由适配器生成/解析，绑定请求和作用域，UI 不解释 URL/offset。全量随机不截断，分页失效、去重、重试、批次边界保留。命令接受不等于音频确认；准备、暂停、失败、待连接真实投影。所有异步跨 await 后重验，最终状态修改在所有者隔离域中完成。
- Provider 能力唯一来源，明确 unsupported / authorization / subscription / unknown / failed；禁止空写成功、将未知返回 false 或空数组冒充成功。收藏及资料库的字段级合并、确认/意图/版本、超时核对、任务清理保留。自建/协作/未知歌单容器严格只读；不扩展写入、分享、外部打开、编辑歌单。不得绕过鉴权、DRM 或存储/输出凭证。

## 前端与效率
保留经典水晶皮肤、Original/Enhanced、Normal/Mini、歌词、UnifiedStageController 单宿主、双玻璃 Dock、既有动画及页面交互。平台提供内容与能力，AirMuse 决定布局和材质；不引入任意 Server-Driven UI。Swift 6 严格并发，AppKit MainActor，I/O/解析/解码不阻塞主线程。未激活平台不创建 WebKit、引擎、连接或常驻任务；活动引擎宿主与窗口可见性解耦。保留低频状态流、差量渲染、可中断动画及键盘/VoiceOver/Reduce Motion/Transparency。无无界缓存、事件监听、动画或任务；无新运行时、无不必要依赖，不用 unchecked Sendable/unsafe/detached 掩盖错误。性能指标为目标，实测需附设备、构建配置及原始结果。

## 完成定义
PD00–PD09 逐项生产接线、回归及审查；R01–R52 自动验收，E01–E08 实机验收如实记录。独立测试平台必须真实通过通用应用链路，且无 Apple Music Adapter 的独立构建/启动验证必须成功，不能以隐藏入口替代。真实 Apple Music、音频交接、WebKit、原生材质、Instruments 的证据不能由 mock 替代。状态 TODO / IN_PROGRESS / IMPLEMENTED / TESTED / PENDING_INTEGRATION / VERIFIED / BLOCKED。未完成项列明解除条件；最终报告逐项说明目标、缺陷、测试、性能、剩余风险及工作区状态。
