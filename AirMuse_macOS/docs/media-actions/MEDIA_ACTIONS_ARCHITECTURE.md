# 架构与数据流
页面播放菜单 / 卡片右键 / 曲目右键及更多 / 队列菜单 → ActionResolver（纯函数）→ ActionDispatcher → 既有 PlaybackCoordinator、LibraryRepository/Provider、内部导航。所有 View 仅提交意图和显示快照。建议 MediaAction、MediaActionContext、MediaActionResolver、MediaActionDispatcher、PlayableSelectionResolver、MediaContextMenuBuilder；名称为建议，依实际 module graph 合并，不为文件数制造新层。

## 契约（示意而非可直接编译代码）
现有统一入口（以实际源码签名为准）：
```swift
public func submitIntent(
    _ intent: QueueInsertionIntent,
    entries: [QueueEntry],
    startIndex: Int = 0,
    kind: PlayableKind? = nil,
    loadingState: QueueLoadingState? = nil,
    batchID: UUID? = nil,
    expectedQueueID: UUID? = nil,
    expectedDestructiveEpoch: UInt64? = nil
) async throws -> QueueCommandResult
```
Dispatcher 解析 PlayableSelection（单曲/选中行/专辑/歌单/艺人热门歌曲）及 ActionContext（provider、account、session generation、storefront、resource、location、queueID、entryIDs、intentID、permissions、resource state），再调用上述入口。复用 `.replaceAndPlay`、`.interruptAndPlay`、`.prepend`、`.append`，最小扩展 `.shuffleAndPlay` 或等价原子模式参数。普通播放与随机替换须在协调器同一次无 suspension 的状态决策中确定模式、完整随机顺序、首曲及 pending 目标，然后执行引擎命令。禁止 UI 分两次 await 设置 shuffle 和替换。保留原有非本期调用者的兼容语义，明确页面菜单顺序播放关闭随机。QueueCommandResult 的 queueID/revision/destructiveEpoch/acceptedCount/message 用于操作回执；播放开始必须由有效引擎事件确认，不能以 acceptedCount 或 message 证明。
队列中的 playEntry/moveEntries/removeEntries 仍走现有命令；不要转换为 append。来源在加入时捕获并保留，不放进共享 MusicTrack；本期不新增来源胶囊。使用类型化目录 ID 与资料库 ID、歌单归属、艺人关系，禁止只靠前缀或名称决定删除目标。菜单打开时捕获不可变资源身份及页面上下文，点击时再次验证；导航仅改变浏览状态，保留返回位置，不能触发播放。

## 异步及事务
替换/插播先登记最新播放意图，再异步加载；提交前核对 session generation、intentID、队列作用域。队首/尾追加按用户提交顺序或明确批次规则提交，不因请求完成乱序。使用有界分页、稳定批次边界、游标去环和独立失败重试；全量随机需完整集合，不偷偷截断。清空、换队列、退出账户使旧批次失效；正常拖拽不取消不冲突分页。失败页重试不重新加载音频。播放确认、目标保留、旧事件隔离复用既有调度机制，不让 UI 乐观修改队列。异步写操作前后验证账户，不接受旧账户响应更新新 UI。

## 资源状态
按 provider + account + storefront + 规范化资源身份建立共享缓存；目录/资料库 ID 映射只来自真实关系。状态分别表示 libraryMembership 和 favorite：unknown / known(true|false) / pending(target, previous, operationID) / failed(lastKnown, error)。同一资源写操作串行或合并最终目标，两个状态若有服务端联动一起核对；不能将超时等同失败未执行。超时后查询真实状态再决定重试，不盲目重发非幂等写。错误反馈及回滚不得覆盖较新意图。缓存有界、合并查询、按需批量加载；账户退出撤销任务并清隔离状态。资料库列表、收藏列表、卡片、详情按钮和队列菜单订阅同一状态，差量更新；不重建整页或打断滚动。

## 性能
菜单构建纯本地，禁逐项请求；预取仅可见且必要资源，状态查询有界并发；复用 repository、HTTP transport、session、image cache、MotionCoordinator。队列结构订阅与高频进度分离；避免每个歌曲行持有长期任务；滚动复用、关闭释放观察者。测量菜单打开、点击反馈、100/1000/10000 条队列操作及内存，比较同设备基线，记录 p50/p95、请求次数、主线程和 WebKit 子进程；不承诺未测性能。

## 现有实现迁移
复用 `playIntentGeneration`、`expectedDestructiveEpoch` 及批次取消机制；只补必要的会话与意图提交校验。既有 `LibraryQueueAction` 可作为过渡映射，最终统一菜单描述，禁止双分发。艺人收藏由现有 Provider.setArtistRating 接入 FavoriteService，替换控制器中的局部乐观状态写入；状态读回以真实接口为准。已有队列反馈组件优先复用，修正播放接受与播放确认文案。
