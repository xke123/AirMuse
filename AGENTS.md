# AirMuse — Media Actions Stabilization Patch

## 1. 当前唯一任务
对 AirMuse_macOS 已存在的音乐资源操作系统进行专项收口：真实资料库添加/移除与收藏/取消收藏，资源身份、权限和状态一致性，完整集合播放，所有入口的异步意图隔离，菜单及反馈生命周期、底部队列控件效率、状态栏窗口恢复。目标是正确、轻量、可预测的多音源播放器，而不是完整音乐平台客户端。以 `ccd3102a5ddaa86785a645b1e000b9afce47a38c` 为静态审查参考；实际 HEAD 必须复核。

自建、协作、归属未知歌单容器严格只读：可查看、播放及将内容加入临时队列，禁止创建、编辑、删除、改名、增删或重排成员。资料库及收藏是正式交付目标；平台歌单只允许经验证的订阅关系添加/移除及收藏。不得因资料库移除误删个人歌单或隐式修改其内容。禁止分享、复制链接、外部打开、减少推荐。当前播放来源胶囊、双胶囊融合及其他音源接入不属于本期。现有来源元数据及内部来源导航保留；保留单队列按钮，不扩展无关功能。

## 2. 唯一执行规范
每次会话先读本文件与 `AirMuse_macOS/docs/media-actions-stabilization/` 下全部九份 `MAS_*.md`。GOALS 是范围及验收目标，BASELINE 是问题证据，RULES 是产品契约，ARCHITECTURE 是实现约束，PROVIDER 是真实平台验证门槛，UI_PERFORMANCE 是交互及性能规范，ROADMAP 是依赖顺序，TESTS 是测试契约，PROGRESS 是实际进度。现有源码为实现事实，不因文档推测覆盖工作区。旧任务文档只作参考，不作为本期活动任务指令。

1. 检查 git status、HEAD、分支、diff、Package.swift、真实 SDK、测试基线及相关调用链；保护用户未提交修改。逐项复核 BUG/UX 证据；若已修复，验证后关闭，不重复开发。
2. 按 ROADMAP 依赖执行，先确定性复现缺陷，再做最小生产代码修复，再运行定向与全量测试。禁止仅写计划、空接口、伪造成功。局部账户或 SDK 阻塞不妨碍独立任务。
3. 每阶段记录实际文件、调用链、命令、退出码、测试及性能证据，更新 PROGRESS 与 ROADMAP 的状态；重大契约变化同步文档并说明理由。未实测不得标 VERIFIED。
4. 保持可构建、可回滚，保护现有功能和用户改动。仅在用户授权时提交或推送；不得擅自远程修改。不要修改其他任务的历史文档以制造完成假象。

## 3. 业务与并发不变量
- 复用 `MediaActionResolver`、`MediaResourceReference`、`MediaResourceStateStore`、`MediaPlayIntent`、`QueueInsertionIntent`、`PlaybackCoordinatorV2.submitIntent`、`QueueCommandResult`、`QueueManager`、`QueuePaginationLoader`。五种播放意图已存在；不要建立平行队列、调度器、播放器或状态缓存。仅作必要的原子校验、集合解析、状态合并和接线。
- UI 不把已渲染数组当完整集合；页面与卡片的集合动作统一解析真实资源和分页。单曲、集合从某行播放、已有队列条目是不同选择。入队创建独立 UUID 与来源；移动保留身份。随机替换全量洗牌，顺序播放关闭随机；插播/队首/队尾保留批次内顺序和原有模式。未加载完成不伪称全量；清空/换队列后旧分页失效。
- 点击时冻结目标、资源身份、会话代数、播放意图、队列 ID 与 destructive epoch；跨 await 后校验，最终提交在协调器隔离域内原子校验。旧任务不可取消新任务分页、写入新账户或改变新队列。区分命令接受、引擎确认、失败、取消、过期。
- 收藏和资料库两字段各自保留 confirmed/desired/operation/revision；字段级合并有证据的结果，保护其他 Pending。超时属于结果未知，核对服务端；不能以乐观值回滚、以请求成功推定服务器状态、以旧 GET 覆盖新写入。缓存和任务均有界，任务注销按身份校验。
- Provider 是平台能力唯一来源；UI 只合并当前上下文。写操作必须在提交时重新检查账户与资源权限。真实目录/资料库映射，不以名称/ID 前缀猜测删除目标。已验证安全接口才开放；未验证能力显式阻塞，不伪造返回，不绕过鉴权，不记录或导出凭证。
- 资料库及收藏不主动改变本地播放计划、来源、历史、音频；平台关联影响须验证。安全无法确认的破坏性写入保持禁用。

## 4. UI、性能和工程约束
保留经典水晶外框、原始皮肤、布局、Normal/Mini、歌词、UnifiedStageController 单宿主及 Original/Enhanced 两模式。Original 保持原始视觉；Enhanced 局部使用公开 AppKit 原生 Liquid Glass。右键优先 NSMenu；播放菜单沿用现有组件。禁用/空菜单不能兜底执行播放。菜单目标冻结，失焦、页面切换、关闭和销毁时清理监听、子窗口及动画；可中断、可反向、过期回调无副作用，焦点、命中与可见几何一致。Reduce Motion/Transparency、键盘及 VoiceOver 适配。不得把模糊或淡入冒充原生连续玻璃形变。

Swift 6 严格并发；AppKit MainActor，昂贵解析、I/O、图片解码不阻塞主线程。复用网络、会话、缓存和 MotionTokens；菜单打开不得逐项网络请求，不因动画/队列进度重载音频或 WebKit。采用局部状态刷新，有界请求及反馈合并，不丢真实业务操作。禁止无界 Task、监听、图层、定时器；空闲装饰时钟零。60/120Hz 的整帧预算 16.67/8.33ms 是目标非实测。无新运行时或无必要依赖，不用 unchecked Sendable/unsafe/detached 掩盖并发错误。

## 5. 完成定义
所有 MAS 任务有真实生产接线、确定性回归和独立审查；保留既有测试，禁止降低断言。状态 TODO、IN_PROGRESS、IMPLEMENTED、TESTED、PENDING_INTEGRATION、VERIFIED、BLOCKED；以实际证据为准。真实账户写接口、远端电台、SDK 原生材质、VoiceOver 和 Instruments 不能由 mock 或初始化测试替代。未验证的能力不开放且必须明确列入剩余交付，不能宣称本期完整完成。最终报告逐项列出 BUG/UX 关闭依据、测试命令及结果、测量设备和指标、未完成原因及人工验收步骤。
