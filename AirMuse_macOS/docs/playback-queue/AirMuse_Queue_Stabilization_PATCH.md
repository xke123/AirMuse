# AirMuse — Playback Queue Stabilization Patch

**执行对象：** AI coding agent（Codex 等）  
**审查基线：** `3fb529ddc3a511a1c8ae9738edb8b6f45f243c3d`（main，2026-11-27 03:43 北京时间）  
**任务类型：** 增量修复与契约补齐，不是重新设计播放系统。  
**状态：** 待实施；本文是实施规格，不是已经应用的 git diff。

## 0. 任务入口与边界

在仓库中阅读现有 AGENTS.md、`AirMuse_macOS/docs/playback-queue/` 以及实际源码、测试。先记录当前 HEAD、工作区及构建基线。若 HEAD 已变化，逐项复核本文问题是否仍存在；已经修复的项保留实现并补充证据，不重复改造。本文对本专项的操作语义优先于旧队列文档中冲突的设计；同步修订相关文档并记录原因。保留无关用户改动。

**核心不变量：** 队列是播放器真正执行的播放计划，而非歌曲集合的镜像。用户的每个操作都必须具有明确、可预测、可验证的结果。UI 不持有第二份可写队列；业务层不因 UI 展开、关闭或重绘而重启播放。

- 保留 `QueueManager` 值类型，由 `PlaybackCoordinatorV2` 单一写入；保留现有播放器、引擎、Store、持久化与分页架构，按需修补。
- **本期不实现正在播放来源胶囊、来源菜单或双按钮玻璃融合**。现有单一队列按钮正确，不是缺陷。保留 `QueueEntry.origin` 及已有导航能力，保证下一期可以直接复用；不新增来源 UI，也不把来源元数据写入 `MusicTrack`。
- 专辑/歌单等详情页的播放按钮改为菜单属于后续规划。本期必须完成菜单所需业务契约、公共命令、现有入口的统一接线及测试；不提前重做详情页播放按钮 UI。现有右键菜单可以复用相同命令和文案。未来菜单无需再修改队列内核。
- 不扩大至鉴权、歌词、音源新增、皮肤重做、数据库整体迁移；不实现跨设备同步、智能续播或真正的服务端歌单编辑。
- 所有新增类型、方法名为建议，适配实际项目模块边界，避免重复类。不得用模拟数据、假成功、吞掉异常掩盖缺陷。

## 1. 产品操作契约（先实现这个，再修 UI）

### 1.1 四个独立意图

| 命令 | 未来播放菜单文案 | 当前歌曲 | 待播队列 | 集合/多选行为 |
|---|---|---|---|---|
| replaceAndPlay | 播放（替换队列） | 切换 | 替换原待播与循环集合 | 从指定曲目开始；整集合默认首曲 |
| interruptAndPlay | 立即插播 | 立即切换 | 保留原待播，将选中批次的其余歌曲放在原待播之前 | X 开始播放，Y/Z 接在 X 后，原队列随后 |
| prepend | 下一首播放（加入队列开头） | 保持 | 在待播头插入 | 保持批次内部顺序 |
| append | 添加到队列末尾 | 保持 | 在待播尾追加 | 保持批次内部顺序 |

**明确决策：** 本 Patch 将“插播”定义为立即切换、保留原待播，而不是“当前播完再播放”；被中断的当前歌曲进入真实历史，不自动恢复到中断进度，也不自动塞回待播。若产品未来需要暂停当前曲目并自动续播，另行设计 resume frame，不混入这四个命令。“下一首播放”和“加入队列开头”是同一语义，不应同时出现在一个菜单里。插播不会替换队列 ID 或清空历史；正常替换播放才建立新队列。原有右键“立即播放”仍是 replaceAndPlay；队列内部“立即播放此条目”是 playExistingEntry，不得调用 replaceAndPlay，也不得重新生成该条目的 ID。

示例：当前 A，待播 B C D，选中批次 X Y Z（来自另一歌单）。

| 操作 | 确认后当前 | 确认后待播 |
|---|---|---|
| 播放（替换） | X | Y Z |
| 立即插播 | X | Y Z B C D |
| 加入开头 | A | X Y Z B C D |
| 加入末尾 | A | B C D X Y Z |

插播 X 失败：X 明确处于失败状态，Y/Z 及 B/C/D 不丢失；不虚假宣称 A 仍播放，依据引擎实际状态决定保留 A、暂停或显示失败。提供重试 X/跳过 X；不可无提示重放 A。插播动作在确认后历史才推进。

无当前曲目时：prepend/append 仅创建或编辑待播，不自动播放；播放/插播立即开始；主播放器 Play 消费首个待播。自然耗尽后新加入的曲目优先于旧曲目；若无新曲目，可重播最后一首（明确 UI 状态）。

重复歌曲允许加入：每次添加生成新 UUID，来源在加入时捕获；现有条目的移动、回退、循环、重试不生成新 UUID、不改变来源。集合详情页中重复歌曲点击用行 occurrence/索引或条目 ID，不用 `firstIndex(track.id)` 猜测。

### 1.2 统一命令入口

建议新增/扩充现有 `LibraryQueueAction` / `QueueCommand`，通过统一协调器入口提交。`QueueManager` 只做同步计算，不处理网络或 UI；协调器校验能力、作用域、提交原子状态并调度必要引擎命令。

```swift
// 概念契约，不要求直接复制名称或签名
 enum QueueInsertionIntent { case replaceAndPlay, interruptAndPlay, prepend, append }
 struct QueueIntentContext {
     let intentID: UUID
     let sessionID: UUID
     let sessionGeneration: UInt64
     let expectedQueueID: UUID?
     let destructiveEpoch: UInt64
 }
 // submit(intent, resolvedEntries, context) -> QueueCommandResult
```

统一覆盖音乐库歌曲/专辑/歌单、搜索、艺人页、详情页播放按钮（现有动作）、右键菜单、未来播放菜单。批次来源为实际加入时所处资源；不能将当前浏览页后来变化当成来源。卡片和详情页的整个集合操作使用同一资源解析及完整分页路径；明确标记“仅加入所选歌曲”与“整个专辑/歌单”。禁用不支持的资源（如电台不能作为普通歌曲混入本地队列；榜单应先解析为歌曲集合）。

### 1.3 随机和循环语义

随机与循环独立；repeat-one / repeat-all 互斥。单曲循环只作用于自然结束，手动 Next、插播、指定条目不受限制。随机只在启用、开始新轮或用户明确重新洗牌时生成一次实际顺序；自然推进不再抽签。手动插入头尾和拖拽优先于随机，不自动重新洗牌。关闭随机时恢复尚未消费的基础相对顺序，同时保留显式头插/尾插/移动的用户意图；不得因为当前在乱序基础表中位置较后，使刚插入的下一首在关闭随机时落到其他待播后面。

建议把基础顺序定义为“未随机情况下用户编辑后的顺序”，已消费历史与循环成员单独表达。循环成员只包含仍有效的条目；删除和清空必须移除对应循环成员；用户明确回退到历史不等于将删除条目永久加入循环。历史是实际播放 occurrence 的时间序列（同一个队列 ID 在不同循环可出现多次），有界保存；同一轮待播 ID 不重复。手动 Previous：超过 3 秒先 seek 0，不足/等于 3 秒则回退历史，当前条目成为前进候选，反复 Previous/Next 不重复创建条目或丢失历史。失败/取消回退不得提前 pop 历史。

## 2. P0：播放状态机和作用域修复

### P0-01 会话失效与异步快照恢复（审查 BUG-01）

基线：`PlaybackCoordinatorV2.swift:140–171, 287–298, 574–607`。账户切换清空 QueueManager，却保留 `desiredTrack`；restore 在 await 前检查、返回后不复核。

- 独立 `invalidatePlaybackSession` 和普通 stop。账户失效同步使旧 session/operation/engine 关联失效，清除当前、pending、队列、历史、时间锚点、pending seek、目标类型/ID、旧错误、恢复状态、结束去重、旧分页和保存任务；根据实际平台隔离或停止旧引擎。先发布无旧账户数据的状态，再执行可能阻塞的清理工作；旧 stop 不得覆盖新播放。
- 每个异步读取/命令返回后检查 session ID、generation、engine instance、对应播放 intent/epoch。对同账户 token 刷新与真正作用域切换区别处理；不能将私人数据迁移给新账户。
- restore 加载前捕获会话、restore generation、queue ID/revision、用户播放意图版本；返回时再次确认未发生新播放、队列编辑、账户切换，才提交；失败/过期结果不得覆盖新状态或永久阻断下一次合法恢复。
- 持久化按 provider/account（及需要的 storefront）隔离，旧保存操作不得清除或覆盖新账户快照。复用现有存储；若是单文件，明确其单账户最近快照限制，优先使用作用域文件或键，迁移旧文件时验证归属。不要把账号 ID 写入用户可见错误日志。

### P0-02 预留、确认、失败、取消和历史（BUG-02/03）

基线：`QueueManager.swift:246–338, 362–458, 561–590`。replace 先清空映射再读取历史；Next 提前消费，快速替换/失败的处理不完整。修复现有状态机，不额外创建独立 actor。

建立统一 reservation record：entry、操作 ID、queue ID、session、来源类型（replace/next/previous/direct/interrupt/repeat）、原待播位置或稳定相邻 ID、必要历史/前进变更计划。明确已确认条目和目标条目；旧确认条目在新目标实际开始之前保留在独立引用中，不依赖被清空的字典。

| 事件 | 原子结果 |
|---|---|
| 预留目标 | 从普通待播显示中划出并展示“正在准备”；不写真实历史 |
| 确认开始 | 只接受匹配 reservation 的有效事件；提交历史变化及当前条目，清除 reservation |
| 播放失败 | 保留失败目标和剩余队列，显示重试/跳过；不伪造历史 |
| 再次 Next | 用户明确跳过旧 pending；记录 skipped 决策，不进入已播放历史 |
| 新指定/插播取消旧 pending | 在同队列恢复尚未消费的旧目标到原相对位置，除非已被明确删除/清空；previous 的历史回退也要回滚 |
| replace | 取消旧 pending 和旧待播；保存此前实际确认的当前，待新目标确认后写历史 |
| 清空/停止 | 清空只影响待播、循环和分页；正在准备的目标作为当前切换意图保留，明确在 UI 表示，不再被视为待播；显式 stop 取消 reservation，未成功播放且未删除的条目回到可恢复计划 |

同一 reservation 只能终结一次。自然结束不得凭一个未验证的 ended 事件无条件确认从未开始的歌曲；确认与结束必须能关联正确资源和操作，重复结束只推进一次。对于失败目标，不用普通 `play()` 假装恢复引擎；调用明确的 retry 命令。已确认当前与 pending 显示不能矛盾：主播放器若显示准备中的目标，标注 loading，而实际来源/历史只认已确认条目。

### P0-03 引擎命令身份与播放状态一致性

基线：`PlaybackCoordinatorV2.swift:655–890, 906–935`。现有 `operationID` 同时受 transport/seek 与播放切换影响，`activePlayOperationID` 和实际发出的 playItem context 可能分离；Store 分两次 await 发布 state/queue。

- 区分 playback generation（每次真正选择音源）、transport command revision（播放/暂停/seek 等）、queue revision（编辑），避免音量、排序、seek 让正在播放的有效事件失效。playItem 必须使用其 reservation 的固定 ID，而非 await 后最新的通用 operationID。引擎 bridge 必须把事件关联到真实播放 generation，不能将迟到事件重新标记为当前操作。
- drainCommands 在任何 await 后复核对应 context；暂停中 pending 未发出或未完成时，继续播放应重新调度必要的 playItem，不只发 `.play` 给可能未装载的资源。检查 `stateChanged(.failed)`、异常、超时、crash、重复 ended、近结束 seek 和短歌曲的行为；不要单凭接近时长的 pause 当自然结束，除非明确排除用户操作且有引擎证据。
- Store 接收同一决策时刻的不可变 state + queue snapshot，建议单次 actor 调用原子更新，带 monotonic publish sequence 拒绝旧发布；现有两个订阅流可保留，但先在 Store 中统一提交后再通知。高频进度仅发布 transport state，不重新构造 10k 条目的队列快照。禁止 UI 写 Store 或修改队列。

### P0-04 电台播放资源身份（BUG-04）

基线：`PlaybackCoordinatorV2.swift:574–607, 389–395, 811–839`。电台 itemChanged 后歌曲 ID 替代电台 ID，恢复/重试时却仍用 station kind。

将引擎目标 `PlaybackTarget(kind, providerResourceID, scope)` 与展示曲目、队列条目来源分别建模，复用已有字段可行时不新增重复模型。电台 target 永远是电台 ID，itemChanged 只更新 currentTrack；重试/恢复使用 target，不用歌曲 ID，不对新随机电台歌曲 seek 到旧歌曲位置。旧快照若无法恢复电台 ID，应诚实降级为不可恢复电台，不猜 ID。远端队列能力按实际验证结果，默认不支持的按钮禁用，不能把远端自动续播伪造成待播列表。

### P0-05 异步播放/添加意图（BUG-05）

基线：`LibraryWindowController.swift:1969–2144`。点击 A 请求慢，后点 B 请求快，A 可能最后覆盖 B；批量添加完成后可能写入错误账户/队列。

- 意图在用户点击时创建，不在请求完成时创建。replace/interrupt 属于立即播放意图，更新 generation、取消或拒绝较旧的立即播放请求；prepend/append 绑定队列及 destructive epoch，非冲突普通排序不使其无故失败。清空、replace、账户切换取消旧的批量添加/分页提交。
- 同队列多个异步添加操作需要确定顺序：按用户发起顺序提交（用批次序号/串行提交屏障或占位边界），不要按网络完成顺序提交。头插的最后一次用户操作在前，尾插按发起顺序排列；单批内部顺序固定。若先发批次失败，释放屏障并反馈失败，不能永久堵塞后续操作。防止 UI 重复点击同一正在加载动作导致意外重复；完成后再次主动添加允许重复歌曲。
- 取消 Task 不是充分条件；提交时必须在协调器隔离下复核上下文。初始播放返回明确 accepted queue/batch token，分页启动不要再次读取“现在的队列”来猜测所属 queueID。

## 3. P0/P1：分页及全量随机

### P0-06 分页重试接线（BUG-06）

基线：`LiquidFusionQueueDockView.swift:585–587, 650–654`，重试按钮调用 `retryPendingOrCurrent`。新增或扩展分页 retry API；保存失败页 nextURL、已提交页标识、batchID、scope、queueID、epoch、累计数、访问游标集合、加载函数/资源描述。重试从失败页继续，只提交一次，不重播、不 seek、不影响当前音频。网络错误/临时失败可重试，循环游标/无效资源/上限状态明确不可重试或提供明确继续加载策略。清空、切换、取消后旧成功/失败回调都不得更新新状态（不仅验证 queueID，还检查批次及 epoch）。

### P1-01 稳定批次边界（BUG-08）

基线：`QueueManager.swift:747–784`，anchor 已消费后 fallback append，可能让后续页越过用户追加项。改为逻辑批次边界/哨兵，边界不依赖某首歌曲存在；不出现在实际歌曲列表、不参与循环。记录每批原始顺序和用户显式编辑；分页追加到自己的批次末尾、用户后续 append 之前，拖拽跨批时不覆盖用户移动。删除某一页末尾歌曲不应自动取消整个批次，只有显式取消、清空、替换、会话失效才关闭相应批次。无效批次不能再提交或设置 loadingState。

例：A 正在播放，待播 B C | 批次边界 | X Y。B/C 消费后，D/E 页到达，仍应得到 D E X Y，而不是 X Y D E。

若批次边界到达队首且下一页未就绪，不越过该边界播放之后的用户歌曲；显示等待剩余歌曲，保持播放意图但不反复 stop/start。失败时提供继续加载、明确跳过未加载部分两种路径；只有用户明确跳过才消费边界后曲目。若列表循环已开，不能在未加载批次完结之前开始下一轮。

### P1-02 全量随机（BUG-07）

初次顺序播放允许首批就绪后开始，后台渐进加载。用户开启随机（或之前随机已开启并发起大集合播放）时，必须区分 requested 与 effective shuffle：完整集合未加载前显示“正在准备随机”，不假称已全量打乱；待加载完成，对剩余可随机条目一次 Fisher–Yates；当前/已预留/已消费及手动指定头尾批次保持语义。若失败，保留已加载顺序并提示继续加载或明确选择仅随机已加载部分，默认不静默降级。取消随机后迟到分页不得自动重新开启。模式状态、队列顺序与 UI 必须原子提交。

### P1-03 全量集合路径一致性

详情页“整个专辑/歌单”操作与卡片菜单同一数据源及分页流程。支持 350+ 曲目、重复 Track ID、空页带 nextURL、未知总数、游标循环、请求失败与重试。批量添加可以先完整加载再原子提交，期间显示可取消的加载反馈；达到上限时不能把不完整结果冒充成功，明确部分加载并由用户决定继续或取消。保存快照时若分页未完成，持久化可恢复的资源/游标及 scope，或明确恢复为部分队列并提供补全，不得恢复成完整状态。分页 loader 应有单一隔离域（如 @MainActor 或 actor），避免 `@unchecked Sendable` 的无保护 activeTask 并发变更；播放计划生命周期不依附于音乐库窗口开合。

## 4. P1：业务与操作体验

### P1-04 清空、循环边界和耗尽（UX-01/02）

- 清空可用条件由快照派生 `canClearUpcoming`：可编辑且存在待播、尚会复活的循环成员或活跃分页。最后一首正在播放、列表循环打开时仍可清空。清空保留当前播放/进度、历史、模式设置，但清空循环成员及未加载批次；状态与 undo 原子更新。无待播时显示“本轮结束后循环”或由业务层已生成并承诺的下一轮，不让 UI 猜测随机顺序；若循环下一轮尚未确定，明确提示，不展示虚假的精确队列。
- 区分 idle/noCurrent、paused、preparing、playing、failed、stoppedByUser、exhausted、waitingForPage。Play：暂停恢复；失败重试；无当前/自然耗尽且有新待播则消费首项；自然耗尽无待播可重播最后一首；用户主动停止可从当前开头重播。重新装载资源时必须走 playItem，不能只对未加载引擎发 play。主播放器、MiniPlayer、系统媒体键共享规则。
- 清空后若仍在单曲循环，允许当前歌曲继续循环；repeat-all 仅在存在有效循环成员时再生，不能恢复删除项。

### P1-05 电台切换与平台能力（UX-03）

目前 `promptRemoteStationSwitch` 文案“添加到队列”却实际立即播放。保留确认流程，但明确选择“继续收听电台 / 结束电台并播放所选歌曲”；确认后才切换，取消不动任何状态。若产品要求真正的只添加不播放，另提供明确“结束电台并建立待播队列”的独立命令，不混用。电台菜单禁用/隐藏不能支持的操作；本地歌曲队列拒绝 station 对象混入。能力区分读取、播放指定条目、头插、尾插、删除、清空、重排、随机、两种循环、跳前后；逐项校验，不以 canRead 替代 canPlayEntry。切换远端不展示不支持但仍选中的本地模式；按产品决定保留为本地偏好、切回时恢复，不能让远端 UI 假装已启用。

### P1-06 操作反馈、撤销、键盘（UX-04/05）

所有入口调用同一结果反馈机制：accepted/committed 才显示成功；批量网络请求开始显示进度，失败/冲突可见且可重试。队列错误当前仅日志或 `try?` 的地方改为用户可见轻量提示，不用大量模态对话框；日志保留技术细节。示例：“已将 3 首歌曲加入下一首”“已添加 350 首”“队列已切换，本次添加已取消”。失败提示不能显示成功；重复点击的 loading 状态应可理解。

清空/删除后给带撤销的短暂轻量提示（建议 5 秒，使用现有提示组件优先），保留严格 queueID/scope/编辑版本校验；播放进度不得使撤销失效。播放推进、冲突编辑、批次变化确实可能使撤销不安全，明确说明“队列已变化，无法撤销”。第一阶段不做复杂跨操作合并；若能安全实现，使用结构编辑版本区分纯元数据/加载进度与冲突状态。撤销清空不得复活旧分页任务，恢复已加载曲目时明确部分状态。

队列行：单击选中、双击立即播放该已有条目（保留其他待播）、Cmd/Shift 多选、Delete 删除、Escape 关闭；右键只作用选中项或被点击条目，批量操作明确数量；已有来源导航保留但不扩大至下一期胶囊。拖拽在 mouse-down 捕获 queueID、条目 ID、稳定目标，提交时重新验证；若目标正在播放或不存在则拒绝并更新 UI；拖回自身/原位置视为 no-op，不报错。批量删除允许全量校验原子执行，或明确部分成功及数量，不能静默部分删除。

## 5. P2：单一队列按钮与性能

### P2-01 原生玻璃队列面板（不做双胶囊）

保留 `LiquidFusionQueueDockView` 单按钮；使用现有 `NSGlassEffectView`，保持底部原版水晶条。暂不因为只有一个 glass view 就创建第二个；共享融合容器可保留为未来接入点，但不声明已完成双按钮融合。关闭队列应有可见入口（例如面板右下角保留收起按钮），同时支持 Escape、外部点击；不把关闭事件穿透造成底层卡片意外播放，除非明确设计为可同时操作底层。面板正常大小为库宽 50%、高 70%，小窗口下按可用空间 clamp，不能以最小 240/220 强行超出边界。

修复 `setExpanded` 动画回调先修改 `isAnimatingMorph` 再检查 ticket 的错误；旧 completion 无权更新任何新动画状态。动画从当前 presentation geometry 反转，几何、圆角、内容渐显和 hit-test 同步；减少动态效果时直接完成，减少透明度时确保可读性。关闭、隐藏、失焦、窗口尺寸改变时妥善清理 monitor/ticket，保留当前播放状态。原生交互和光学效果需在实际 SDK 验证，不用普通 blur 假冒 Liquid Glass。工具栏继续左清空（撤销可临时出现）右随机/单曲循环/列表循环，下面唯一滚动区；不新增当前歌曲展示区。

### P2-02 效率与状态刷新

- 队列结构更新与播放进度隔离；Store 不为相同结构和元数据无意义重复发送队列快照；打开面板不发网络、引擎命令或持久化写入。
- `NSTableView` 按稳定 ID 差量插入/删除/移动，保留滚动锚点、选择、正在拖拽的身份；同 ID 元数据变化时只重载相应可见行。大批量 replace 可一次 reload，不对每页每首重复重绘。缩略图继续用缓存及复用取消逻辑，复用行时立即清除旧封面，避免短暂显示错误图像；不可见行不启动额外加载。
- `upcomingOrder.removeFirst`、全量 snapshot/map/prune 在 10k 项时可能积累 O(n) 成本；先基准测量，不为理论复杂度盲目引入依赖。若实测推进/删除成为热点，采用 head cursor/有界压缩或合适数据结构；结构变更才生成快照、减少重复构造，历史上限 200 保留。分页网络并发有界、按批发布；持久化 off-main、合并写入、单一写入顺序，错误可诊断，不能每次进度事件全量 JSON 写盘。退出 flush 需与 session/写入版本协作。
- 基线仓库报告（不是独立复测）：10k replace 17.26ms、shuffle 1.30ms、save 94.34ms（Debug）。重新测 100/1k/10k：replace、next/previous 100 次、shuffle、move、batch commit、snapshot、save；报告 P50/P95、设备、构建配置及前后对比。目标为不退化，UI 主线程不承担 10k 序列化，空闲无额外定时器，进度更新零队列重绘。60Hz 帧预算 16.67ms、120Hz 8.33ms 仅为观察目标，真实 Instruments 结果另记录，不能宣称达标未测。

## 6. 代码定位（审查基线；实施前重新核实）

以下相对 `AirMuse_macOS/Sources/`，行号只对应基线。源码入口：<https://github.com/xke123/AirMuse/tree/3fb529ddc3a511a1c8ae9738edb8b6f45f243c3d/AirMuse_macOS>。

| 文件 | 必要改动 |
|---|---|
| `Playback/QueueManager.swift` | reservation/历史、插播、随机基础顺序、循环清空、批次边界、撤销 |
| `Playback/PlaybackCoordinatorV2.swift` | 统一命令、session/engine/intent 校验、确认失败、恢复/耗尽 |
| `Playback/QueuePaginationLoader.swift` | 批次上下文、重试、取消、顺序提交、隔离 |
| `Playback/PlaybackStore.swift` | 原子发布及结构订阅、版本检查 |
| `Playback/PlaybackSnapshotStore.swift` | 目标资源、作用域、部分加载快照与迁移 |
| `Domain/Models/PlaybackQueue.swift`, `QueueSnapshot.swift`, `QueueCapabilities.swift` | 复用 QueueEntry，增补命令/状态/能力；不重造来源模型 |
| `UI/Library/LibraryWindowController.swift`, `LibraryContentView.swift` | 捕获用户意图、统一现有菜单及集合解析、反馈 |
| `UI/Library/PlaybackQueue/LiquidFusionQueueDockView.swift` | 重试接线、按钮状态、差量更新、动画/命中、错误反馈 |
| `Providers/AppleMusic/Playback/AppleMusicWebEngine.swift` | 必要的引擎事件身份及 station target 执行修正 |
| `Providers/AppleMusic/AppleMusicAmpClient.swift`, provider | 复用分页、验证完整性及会话作用域 |
| `App/AppLifecycleCoordinator.swift`, `CompositionRoot.swift` | 仅必要的加载任务生命周期、恢复/flush 接入 |

## 7. 实施顺序与回归测试（必须自动化的先自动化）

每阶段先写失败用例，实施后运行相关测试及全量回归；禁止删除原有断言让测试通过。优先扩充 `QueueManagerTests`、`PlaybackCoordinatorQueueTests`、`QueuePaginationTests`、`PlaybackStoreTests`、`LiquidFusionQueueDockTests`、`QueuePerformanceTests`。异步测试使用受控 fake engine、可手动释放的网络 continuation、固定 RNG、虚拟时钟，避免以 sleep 猜事件顺序。必要时增加现有 UI/controller 集成测试，不要求真实登录才能验证纯状态机。

| ID | 场景 / 预期 |
|---|---|
| R01 | A 已确认，replace X：X 确认前 A 未加入历史；确认后历史有 A；X 失败不伪造推进。 |
| R02 | A→Next B→Next C，B 尚未确认：B 明确 skipped；迟到 B 事件不消费 C。 |
| R03 | B direct pending 被插播取消，同队列恢复 B；previous pending 取消后历史不丢。 |
| R04 | 播放失败后 retry/skip 不丢其他待播；重复 ended 只推进一次。 |
| R05 | prepare 时 pause/play、seek/volume/queue edit 与 engine await 交错，操作身份正确。 |
| R06 | A 账户切 B，歌曲/来源/队列/旧事件清除；旧保存不覆盖新快照。 |
| R07 | 快照读取暂停期间用户启动新播放或切换账户，旧结果被拒。 |
| R08 | 电台 itemChanged 后 retry/恢复仍用原 station ID，不 seek 旧歌曲进度。 |
| R09 | 慢 A/快 B 的 replace/interrupt，最终最新意图生效；批量添加跨账户/clear 被拒。 |
| R10 | 两批网络完成乱序，头插/尾插顺序由用户发起顺序决定；失败释放提交屏障。 |
| R11 | 四种命令用 A,B,C + X,Y,Z 验证第 1 节表；插播失败、空队列及重复歌曲分别验证。 |
| R12 | 同一 track 两个 occurrence、不同 origin，点击/移动/删除仅作用对应 UUID。 |
| R13 | 分页失败重试只请求失败游标，不发 playItem/seek、不重复提交已加载页。 |
| R14 | 批次锚点已消费，迟到分页仍在 X/Y 前；删除锚点不取消整个集合。 |
| R15 | 待播到达尚未加载批次边界，等待/失败反馈，不提前停止或循环；继续后顺序正确。 |
| R16 | 分页中 clear 后迟到成功和失败事件都不改变新 loadingState/队列。 |
| R17 | 随机请求在 350 首未完整加载时 pending；完整后随机剩余条目；取消/失败不假开启。 |
| R18 | 随机中 prepend/append/拖拽，关闭随机后显式操作仍正确；同轮无重复消费。 |
| R19 | 循环最后一首时仍允许 clear；清空后无成员复活，单曲循环例外。 |
| R20 | 详情页与卡片整个集合操作均加载全部页；游标循环/上限不得假成功。 |
| R21 | 队列耗尽后 append + Play 消费新条目；pause/failed/stop 各行为符合表。 |
| R22 | 随机+循环历史前进/回退、失败回退恢复、删除历史项不进入循环。 |
| R23 | 电台切换取消无副作用；确认文案与真实行为一致；禁止将 station 当普通歌。 |
| R24 | undo 恢复有效条目，冲突时提示，不恢复失效分页。 |
| R25 | 状态与 queue snapshot 同源；旧发布拒绝；position/volume 不发结构更新。 |
| R26 | 拖动中目标变为当前，安全拒绝；多选、拖回自身、过期右键不误操作。 |
| R27 | 快速开合、反向动画、resize、Escape、窗口隐藏，无过期回调和意外播放。 |
| R28 | 真实成功/失败/进度反馈；重复加载点击防误添加；键盘和辅助功能可用。 |
| R29 | 100/1k/10k 性能与持久化顺序；关闭/打开浮层无引擎/网络请求。 |
| R30 | 旧快照迁移、部分分页恢复、损坏数据安全降级；随机顺序重启保持。 |

阶段 A：P0-01～06（正确性，R01–R13、R16、R25）。阶段 B：四种命令及 P1-01～03（R09–R18、R20、R30）。阶段 C：P1-04～06（R19、R21–R24、R26、R28）。阶段 D：P2（R27、R29 及全部回归）。阶段划分可按依赖微调，不能因为 UI 工作跳过 P0。对每阶段记录改动、构建命令、退出码、测试结果、未完成项。

## 8. 完成门槛与 Agent 交付

1. 保留上一期 Q01–Q20 的有效实现和测试，不把本期未做的来源胶囊误标为问题；已有单队列按钮正常。
2. 未来播放菜单四种操作均有统一公共业务入口、现有菜单接线、可重复测试；不实现后续菜单 UI。
3. 所有 P0 缺陷的回归用例通过，P1/P2 实现按上述契约验收；若任何项受真实平台限制，记录具体限制与安全降级，不用假数据绕过。
4. 在实际仓库运行可用构建命令与 `swift test`，记录真实输出；若环境不能编译，明确阻塞，不声称成功。真实 Apple Music 账户、电台、350+ 歌单、原生玻璃、拖拽手感和 Instruments 单列人工验收；不得把 mock 结果当成实机通过。
5. 更新 `QUEUE_PROGRESS.md` / `QUEUE_ROADMAP.md` 和冲突的语义文档；新增专项记录 `QUEUE_STABILIZATION_PROGRESS.md`（基线、HEAD、修复 ID、代码位置、测试、实际结果、剩余风险）。最终报告逐项列出已修复/部分修复/未验证，附证据。
6. 不提交或推送到远程，除非用户另行授权。完成本地修改后提供 diff 概要、测试结果和人工验收路径。不要停在计划阶段：对当前环境能够完成的任务直接实施，遇到阻塞继续完成其他不依赖项。

**审查限制：** 本文依据上一轮对固定提交的静态源码审查及仓库自报测试结果编写，并非 macOS 实测。插播是否自动恢复旧歌曲、头插顺序、等待分页边界、撤销时长等是本 Patch 明确选定的产品默认规则，便于 Agent 执行；如用户后续修改这些规则，先更新契约与测试再调整实现。
