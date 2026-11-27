# 架构与并发修复契约

## 所有权与最小改造
UI → MediaActionResolver（纯决策）→ 现有分发路径/薄适配 → 现有协调器或 Provider/StateStore。不要新增平行 PlaybackIntent、第二个队列 actor、全局 UI 业务状态或重复缓存。将 LibraryWindowController 的分散路径逐步收敛成可测试的薄入口；仅在减少重复并能验证时提取类型/模块。Menu builder 只渲染，不做网络或业务推断。

### 资源身份与能力
统一已有 MediaResourceReference 构造，区分 resourceKind、provider、catalogID?、libraryID?、queueEntryID?、account/session/storefront、真实 playlist ownership、关系 ID 的命名空间。没有证据的 ID 为 nil，不能将 track.id 无条件填入 libraryID。目录与资料库别名只通过可信映射合并，映射未确认时维持各自身份；本地队列 UUID 不用于平台写入。别名合并须原子处理在途操作，必要时拒绝/重新核对，不合并不同资源。导航传递 typed ref 而不是重建 card 猜前缀。当前详情身份去重及 origin/album 去重使用已确认映射。

Provider 能力按资源类型和权限生成并缓存，读取菜单使用现成同步快照；异步预取只针对必要资源/登录状态，零逐项请求。UI 仅合并队列能力、当前详情及选中项。执行时重新验证 Provider、账户代数、资源权限、ownership 和身份；不依赖 UI 隐藏作为写保护。明确 unknown、unsupported、unauthorized、temporarilyUnavailable；canRead 必须实际存在读取能力。未认证的播放可走已有登录引导，但不能误称已播放。

### 资源状态模型
在现有 MediaResourceStateStore/MediaToggleState 上扩展必要内部字段，不必引入新公共状态体系。每字段独立保存 confirmedValue、desiredValue、operationID、revision、lastError/unknownOutcome；视图可显示 pending target，但不得当作 confirmed 或回滚依据。receipt 改成字段级 patch（absent 表示未提供，不覆盖；有证据的 known/unknown 需明确来源及新鲜度）；写入结果合并到最新状态，不替换整个对象。

同资源所有平台写操作串行，允许 coalesce 尚未执行的同字段旧意图；其他字段顺序保留。旧请求已实际到达服务器，即使被新意图取代，也应记录其可靠确认事实或触发核对，不覆盖新的 desired/pending；最终操作以真实结果为准。不同资源可有限并发。返回 typed outcome：confirmed(value)、accepted/pending、unknownOutcome、superseded、cancelled、failed；避免旧调用正常返回新状态然后 UI 提示旧动作成功。

GET 捕获 scope generation 与字段 revision / op identity；提交时逐字段判断是否仍可用。读合并的等待者返回相同已合并结果而非未校验 raw task.value；旧 defer 不得删除新 read slot。已开始写入的字段不被旧读或旧详情 seed 覆盖。核对跨 await 后验证 session、operation、revision；核对成功但与目标不同应返回实际状态及未达成结果；读回失败保持 unknownOutcome，不回滚成确定 false。不能把任何 2xx 或 `updated?.isFavorited ?? enabled` 当成已读回。若接口契约明确确认字段值，可作为证据，仍要同步已知联动。

### 会话与任务生命周期
Scope 包含 provider/account/storefront 及 sessionID/generation；即使相同账号重新授权也要失效，A→B→A 不能复用旧任务。切换时取消旧任务、清除私有状态、使旧页面不可执行、通知订阅者；Provider 在网络发送和提交时使用捕获会话，不从新会话获取凭证代旧请求。取消 HTTP 不等于服务器撤销，旧账户响应只丢弃 UI 提交，不声称写入未发生。每个 inFlightRead/activeWrite slot 带 ID，defer 仅清理自己；intent 元数据完成后安全清除，避免 task 链永久保留。缓存上限覆盖辅助元数据，保护 pending，超限背压或清理已完成非活跃项；不是无界并行。

### 播放操作上下文
现有五种 `QueueInsertionIntent` 与 `submitIntent` 已实现。统一页面集合解析与卡片解析，冻结资源、selection、origin、scope、intentGeneration、queueID/epoch（编辑类）和加载批次 ID；点击时同步注册用户意图，再开始请求。若跨 actor 获取快照，使用当前可验证 UI 快照或协调器立即注册返回 ticket，不能等请求/前序链后再确定目标。最终验证必须在协调器 actor 内与变更同一无 await 临界段，不能仅靠 Controller guard。普通替换/随机/插播、电台、艺人、行点击共享失效机制；旧意图不能 cancel 新批次。使用真实提交 receipt 的 queueID/epoch/batchID 启动后续分页，不在 await 后重新采集不相关的最新快照。错误反馈也需绑定操作身份。

追加/插入加载可并行有界，提交按发起顺序，并在所有 await 后校验目标；清空/替换/会话失效后旧编辑拒绝。连续 prepend 的先后规则由现有队列契约决定（后执行批次在队首），批次内部保序。分页渐进必须使用稳定批次边界和明确加载状态，等待到达未加载边界时不能错误结束/跳过；失败保留已提交部分及独立分页重试，已消耗/已清空成员不复活。遇到资源上限或循环游标失败，不继续伪完整提交随机集合。

### 结果与订阅
QueueCommandResult 是提交接受凭据，不等于引擎确认，使用 operation/entry/session 关联后续状态。发布 state 与 queue snapshot 的一致版本；不以高频 position 更新触发资源菜单刷新。UI 只订阅共享资源状态，移除独立艺人乐观状态/rollback（展示可以使用 pending），当前页/列表/队列按资源 key 定向刷新；详情 seed 有版本。平台写入失败不改变队列；若后续资源不可播放，沿用现有失败重试路径，不偷偷删队列。
