# 队列架构与状态契约

## 唯一权威
Library/Player/System Media/Queue UI → PlaybackCoordinatorV2 → QueueManager（同步纯逻辑）→ PlaybackStore（只读快照）与 WebEngine（实际命令）。网络加载和磁盘存储为外围服务。Actor 隔离不等于跨 await 原子性；队列决定与版本更新在无 await 的区间完成，外部返回必须重新验证上下文。

## 模型
复用 PlaybackQueueItem（若已有），否则建立 QueueEntry：UUID id、MusicTrack track、PlaybackOrigin origin。禁止两个同职责类型；来源在加入时捕获，未知明确 unknown，不写进 MusicTrack。每次加入生成独立身份，即使歌曲 ID 相同。播放请求通过条目 ID 定位，不用 firstIndex(track.id)。

PlaybackQueue 持有 queueID、条目表、baselineOrder（非随机基础顺序及有效循环成员）、upcomingOrder（实际待播顺序）、history（实际播放访问轨迹，可重复引用）、currentEntryID、pendingEntryID（待确认目标）、revision、加载批次标识。允许简化内部存储，但不变量必须保持。循环成员与历史独立；已删除条目可留在有界历史，不能由历史重建循环。引用对象回收以所有合法引用为准。

QueueSnapshot：queueID、revision、sessionScope、confirmedCurrent、pendingTarget、upcomingEntries、shuffleEnabled、repeatMode、capabilities、loadingState。状态有 idle/loading/partial/complete/failed（含可重试信息）。电台未知待播与空列表严格区分。快照包含来源，不靠 UI 拼接。

接口示意（以实际 Swift 类型适配）：
```swift
func insertNext(_ entries: [QueueEntry]) async throws
func append(_ entries: [QueueEntry]) async throws
func playEntry(id: UUID) async throws
func removeEntries(ids: [UUID]) async throws
func moveEntries(ids: [UUID], before targetID: UUID?) async throws
func clearUpcoming() async throws
func setShuffleEnabled(_ enabled: Bool) async
func setRepeatMode(_ mode: PlaybackState.RepeatMode) async
func queueStream() -> AsyncStream<QueueSnapshot>
```
编辑请求附 queueID/sessionScope/expected revision；若版本变化但目标及锚点仍有效，可以按 ID 安全重定位，否则返回明确冲突并刷新。批量操作原子提交。所有操作通过协调器，禁止 UI 直接写数组。队列编辑不增加播放 operationID，除非确实改变播放目标；不使正在播放的有效引擎事件无故失效。

## 状态发布与事件
协调器一次决策产生结构快照和必要的 PlaybackState 更新，通过单一 store 提交；同一当前条目与来源共享标识。结构 revision 单调递增，旧发布不可覆盖新值（跨会话使用 scope/epoch）。AsyncStream bufferingNewest(1)，订阅立即收到当前值，取消时删除 continuation。进度/音量/歌词变化不重发队列。UI MainActor 差量刷新，隐藏浮层不保留多余监听。

引擎命令绑定 sessionID/generation、engineInstanceID、operationID 与条目身份（可在协调器建立 operation→entry 映射）。同一歌曲重复条目也不能混淆。自然结束、推断结束及重复事件仅消费一次；校验当前操作与 transport。播放失败不能把目标冒充已确认歌曲；保留可重试目标及剩余队列，明确错误，不无限自动跳过。历史仅记录确认播放的访问，不记录失败或仅预备的意图。

## 持久化
复用 PlaybackSnapshotStore；升级 schema，保存身份、来源、基础/实际顺序、历史、当前、模式、位置及账户/平台/storefront。旧 tracks/index 迁移为独立 ID，来源 unknown；不猜测历史或随机顺序；验证引用完整性和索引范围，损坏数据安全降级。默认暂停恢复，不自动发播放指令；首次 Play 应实际装载恢复条目并 Seek 到合法位置。私有快照需确认账户及平台匹配；不同会话切换、注销立即使旧任务和私有队列失效。写入防抖与最终 flush，防旧保存覆盖新快照；结构编辑尽快保存，进度节流。电台只恢复可确认的电台引用，不伪造未来曲目。
