# PO — 架构、数据、状态与并发

## 单一权威链路
用户动作 → typed selection + immutable PlaybackOrigin → existing submitIntent/QueueManager → PlaybackCoordinatorV2 → PlaybackStore atomic commit → low-frequency view projection → Dock/菜单/内部导航。导航仅改变 Library route，不进入播放指令链。

## 模型扩展（示意，复用实际类型）
```swift
// PlaybackOrigin 新增可选字段，保留既有 Codable 格式
let navigationTarget: OriginNavigationTarget?
let stationContext: StationOriginContext?
// typed route: resource(kind,id,scope,provider), librarySection(id),
// search(query,scope,section), chart(id), browseSection(id), stationDetail(id)
// StationOriginContext: stationID, stationType(.live/.algorithmic/.unknown),
// seedResource?, sourceNavigationTarget?（轻量、真实资源身份）
```
禁止在 origin 中保存整个页面、曲目数组、UI 对象、认证 token。若 MediaResourceReference 已含 origin，不能形成递归值类型或递归 Codable；使用无 origin 的轻量 route identity / seed ref，而非直接嵌套完整引用。可选字段缺失正常解码；枚举新增值或不合法数据需有安全 unknown 路径；版本迁移测试。现有 ID 与来源不可变，动态关系属于当前曲目投影或缓存，不回写历史来源。

## 当前播放投影
从现有 atomic commit 派生 `NowPlayingOriginPresentation`（名字建议）：scope/session generation、publish sequence、playback generation、queueID、owner、confirmed entry、pending/phase、target、station item sequence、可用能力、可选关系。不能分别拿最新的 PlaybackState 和较旧 QueueSnapshot 拼成错误当前歌曲。必要时在 PlaybackStore 增加同一次提交生成的低频投影或原子组合快照；状态、曲目、所有者、能力发生语义变化才 emit；position/volume/lyrics 不触发。`queueStream()` 可继续用于本地列表差量更新。`QueueSnapshot.confirmedCurrent` 与显示的状态必须属于同一上下文；owner 换但尚未确认时显示 transition，不把旧曲目误作新会话。`itemChanged` 不是 transport playing 确认；延用实际 engine state 事件并校验身份。

## 所有者切换原子事务
复用协调器 actor；增加最小内部操作 `switchRemoteToStagedLocal(entries, expectedContext)` 或等价能力，不创建第二队列。点击时捕获 session/queue/epoch/intent generation；确认前后重验；actor 内一次检查+失效旧播放代数/分页/远端 target+重建本地 staged snapshot，旧引擎 stop 命令必须绑定旧 context，避免延迟 stop 停掉新播放；协调器串行化 transport 切换并报告实际失败/准备状态。不得以 UI 连续调用 stop、replace、pause 模拟原子 stage。队列为空/不合法不得先结束电台。失败则明示最终真实状态，若旧会话仍真实可用可保留，不能假称回滚。所有权变化时清理跨模式旧 history/cycle/undo 等可执行路径，不影响已有普通队列内部语义；不得自动恢复隐藏队列。

## 并发与缓存
- 在点击时捕获 `OriginActionContext`：provider/account/session generation、queueID/epoch、play generation、stationID、itemSequence/真实 track identity（远端 UUID 不随切歌变）。导航另有 navigation generation、route identity、page generation；不因浏览而取消播放。关闭菜单/切歌/切账号/退出使查询 token 失效。
- 同歌曲关系查询按真实资源+scope 去重；用现有 Provider/Repository/SWR，短生命周期、有界缓存，失败状态明确；禁止逐曲目预取和从标题模糊匹配。返回后检查 item identity、scope、generation；UI 主线程只更新仍有效的展示。
- 播放/模式切换最终校验在协调器内原子完成，不仅靠 Controller await 前 guard。新意图不得被旧分页 cancel/stop 影响。真实能力变化与 transport 更新同版本发布。
- 持久化保持现有 store，保存已确认来源及真实 target；必要时保存 staged/pending 区别，不把 activeTargetEntry 直接恢复为 confirmed。远端恢复只用已验证 station ID，不 seek 到旧歌；无有效 station ID 安全降级，不能猜。按 provider/account/storefront 隔离，私有来源不跨账户；同账户新 session 取消旧请求。

## 文件责任（实际路径由 PO00 确认）
| 文件 | 改动 |
|---|---|
| Domain/Models/PlaybackOrigin.swift | 可选 typed target / station context / 安全解码 |
| Domain/Models/QueueSnapshot.swift、QueueCapabilities.swift、MusicStation.swift | 必要的模式、能力、投影字段；保留现有接口 |
| Playback/QueueManager.swift、PlaybackCoordinatorV2.swift | 单电台不变量、stage-only、代数与事件、统一能力检查 |
| Playback/PlaybackStore.swift、PlaybackSnapshotStore.swift | 一致低频投影与兼容恢复 |
| Providers/AppleMusic/Playback/AppleMusicWebEngine.swift | 真实事件及能力接线；不猜未验证 API |
| UI/Library/LibraryWindowController.swift | 所有入口来源冻结、纯内部导航、定位与返回 |
| Domain/Models/MediaActionResolver.swift、MediaActions.swift | resolveOriginMenu/typed routes，复用去重 |
| UI/Library/PlaybackQueue/LiquidFusionQueueDockView.swift | 共同宿主、模式化内容及现有列表行为 |
| 建议 PlaybackOriginCapsuleView / PlaybackOriginMenuView / PlaybackDockLayout / RemoteStationPanel | 可拆分职责，避免庞大单体；复用已存在等价组件 |
| Player/Mini/快捷键现有接线 | 同一 transport capabilities；不改皮肤 |
