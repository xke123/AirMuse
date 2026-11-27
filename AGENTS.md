# AirMuse — Playback Origin & Adaptive Queue

## 当前唯一活动任务
实现正在播放歌曲来源、纯内部来源跳转，以及普通队列与电台会话自适应的底部双玻璃控件。参考提交 `99466ff7853e6c3cfe88bf41159a23768b12b558`（2026-11-27 08:33:03 北京时间）；实际 HEAD 必须复核。任务以现有架构为基础，不重写播放器，不扩大产品范围。

## 执行入口
每次会话先读本文件及 `AirMuse_macOS/docs/playback-origin/` 下全部九份 PO 文档。GOALS 定义交付范围，BASELINE 定义复核证据，RULES 定义业务契约，ARCHITECTURE 定义状态与并发，RADIO 定义电台特殊规则，UI 定义布局与材质，ROADMAP 定义依赖，TESTS 定义验收，PROGRESS 为真实进度。其他历史任务不构成本期活动指令；已有功能及修复不得回退。

1. 检查 git status、HEAD、分支、diff、Package.swift、SDK、实际调用链和构建测试基线。保留用户已有修改；工作区与文档不同则记录证据并复用已存在能力。
2. 按 PO00–PO07 实施；先确定性复现，再最小生产修改，再定向及全量测试、独立代码审查。不要只写计划、空接口、虚假状态或弱化断言。
3. 每阶段更新 PO_ROADMAP 与 PO_PROGRESS，记录实际文件、测试命令、退出码、证据、阻塞及下一任务。未实测不能标 VERIFIED；真实账户/SDK 阻塞不妨碍独立任务。
4. 不擅自提交、推送或修改远程；不覆盖用户修改。不为制造进度而改历史文档。

## 业务不变量
- 来源是入队时真实选择上下文，不是歌曲专辑、当前浏览页或推测的 ID。每个 QueueEntry 有独立 UUID 与不可变来源；同曲可有不同来源，移动不重建，分页继承批次来源，历史及持久化保存真实身份。
- 复用 PlaybackOrigin、QueueEntry、PlaybackTarget、QueueSnapshot、QueueManager、PlaybackCoordinatorV2.submitIntent、PlaybackStore、QueuePaginationLoader、PlaybackSnapshotStore、MediaActionResolver 与现有资源身份/缓存/导航。无平行队列、第二播放协调器、可变全局 currentOrigin 或新网络层。
- 当前来源从一致的已确认播放上下文派生。准备、失败、暂停、停止、恢复、等待分页必须如实显示；pending 不是已播放。主播放器、Mini、来源和面板不能混用不同曲目的身份；队列变化不代表实际播放成功。
- 电台是单一远端会话：独立 station ID、真实 station origin、可选 seed resource、动态 current item。不能把页面其他电台或普通卡片加入远端队列；不能用当前歌曲 ID 重新连接电台。电台待播未知不是 0。默认无本地编辑/循环/随机；直播或未知类型使用保守能力，不凭枚举默认允许 skip/seek。所有入口使用同一能力快照，最终协调器检查。
- 普通队列→电台是明确替换；不保存隐藏恢复栈、不自动恢复旧队列；历史不能跨所有者误触发电台或把电台条目当普通歌曲。电台→播放/随机/另一电台直接替换；插播确认后立即播放；队首/队尾确认后结束电台并原子暂存普通队列，不自动播放。取消不改变电台。不得伪造远端列表或混入本地曲目。
- 用户动作时冻结资源、会话代数、意图、队列 ID、destructive epoch、必要的电台 item identity；每次 await 后检查，最终在协调器隔离域内原子校验。旧请求不得取消新分页、跨账户、重启新会话或覆盖新歌曲。导航请求使用独立导航代数，不修改播放意图。
- 来源菜单只做内部导航；任何跳转不触发播放/暂停/seek/入队/收藏/资料库写入，不通过会播放电台或歌曲的通用点击处理器。目标必须真实可用，按类型化身份去重；缺失关系按需有界解析，不猜测、不使用上一首信息。自建/协作/未知歌单容器严格只读，其他现有资料库/收藏行为保留，不扩大写操作；无分享、外部打开或新音源。
- 旧快照向后兼容；未知来源安全降级；电台恢复的是电台 ID 及上下文，暂停/待连接，由用户主动收听，不承诺恢复上次节目和秒数。账户与 provider/storefront 隔离，旧会话任务失效，不存凭证。

## UI 与效率约束
保留经典水晶外框、原始底条、Normal/Mini、歌词、UnifiedStageController 单宿主与 Original/Enhanced 两模式。仅扩展音乐库底部右侧同一玻璃宿主，来源及队列是独立命中、独立辅助功能的相邻控件；互斥展开且另一入口可用。Enhanced 使用实际公开 AppKit 原生 Liquid Glass；Original 保持原始皮肤；不得用模糊冒充融合。复用 MotionTokens 与现有过渡设施，动画可中断、反向，过期完成回调无副作用，命中与可见几何一致。Reduce Motion/Transparency、键盘/VoiceOver、窄窗、缩放、多屏、失焦/隐藏/销毁安全。

Swift 6 严格并发；AppKit MainActor，昂贵解析、I/O/解码不阻塞主线程。复用 Provider/Repository/缓存/会话。仅消费低频结构及 transport 状态，进度、音量、歌词不触发来源刷新；同来源不播放切换动画；无轮询、无额外 WebKit、无持续装饰时钟。任务、缓存、监听及图层有界并释放。60/120Hz 整帧预算 16.67/8.33ms 是目标非实测，不新增无必要依赖或用 unchecked Sendable/unsafe/detached 掩盖问题。

## 完成定义
PO00–07 有生产接线、回归、证据；P01–P42 自动测试及 E01–E08 实机验收按实际状态记录。真实电台事件、直播能力、原生融合、VoiceOver、Instruments 不得以 mock/初始化测试替代。状态 TODO / IN_PROGRESS / IMPLEMENTED / TESTED / PENDING_INTEGRATION / VERIFIED / BLOCKED。最终逐项报告目标与缺陷、命令与结果、环境、实机证据及未完成原因；不得虚构通过率。
