# PD — 平台运行时、音频权与自适应队列

## 1. 注册与激活
注册只存 descriptor + lazy factory，不能构造 WKWebView、建立网络连接、启动事件订阅。平台未注册/未授权/不可用要有真实状态；正式 App 仅展示实际可用的平台，不将 Fixture、未完成 Spotify/QQ 标成可播放。无激活平台时 UI、队列、歌词窗、Normal/Mini 正常启动并显示空态。默认 Apple Music 可保留为生产选择偏好，不能变成 Domain 默认身份。启动恢复仅加载所选真实账户必要信息，不为所有已注册平台预热。

`browsingContext`、`activePlaybackContext`、`resourceOperationContext` 独立；每个请求保存明确 scope，不从可变全局 currentProvider 重新取目标。ProviderSessionRegistry 管理平台/账户/地区、sessionID、generation、授权状态、运行时引用和取消域。只浏览时可按需建立 API/授权会话，不创建播放引擎；播放引擎按需启动，独立宿主不因音乐库关闭/布局迁移销毁。登录网页实例和音频 WebRuntime 共享/隔离策略由 Apple Music Adapter 决定；不同平台/账户凭证、数据存储隔离。退出当前播放账户必须隔离其音频并清除相应私人状态；退出其他账户不能停止当前音频。旧会话结果、旧缓存回填及旧登录回调拒绝。关闭 App 有序取消任务、持久化并停止/释放音频与宿主。

## 2. EngineRouter 契约
稳定 Router 可实现现有 PlaybackEngineProtocol 或经 Domain 扩展提供显式 prepare/activate；底层 engineInstanceID 不可用 Router 固定 ID 覆盖。Router 的单一事件流桥接当前引擎，保留事件真实 session/engine/operation/track/item identity，增加必要 routing generation。Coordinator 不接收未激活引擎的播放事件；准备事件与活动播放事件区分。每个命令绑定实际引擎引用及 generation，不在 await 后从全局 activeEngine 重新获取目标。所有产生音频的入口（播放、恢复、远端重连、快捷键、系统媒体、错误重试）都通过同一音频权门禁。单活动音频权 token/lease，由 Router 唯一维护；只允许持有者执行可发声命令，准备过程必须无声。底层 SDK 如果不能无声准备，则先确认旧音频隔离，再准备新引擎，明确中断风险。

## 3. 切换事务
```
idle/active -> preparingCandidate -> quiescingOld -> transferringLease
            -> startingCandidate -> confirmed / failed
```
- 用户点击时注册最新 intent，冻结目标 scope/资源/队列 epoch；预检能力与账户。旧音频仍在时，新引擎只能无声准备；准备失败/取消，旧会话若仍真实有效则保持原播放及队列。不可先清除旧 UI 再猜测结果。
- 每次 await 返回核对 intent、会话、engine、routing generation。停止前校验，停止期间串行化音频权交接；较新意图可取代候选，但不能绕过旧音频隔离屏障。受控序列执行 stop/隔离（不持锁跨 await 但 actor 状态机门禁），不使用 `try?` 掩盖。
- stop 成功/明确静音或销毁隔离确认才释放旧 lease；若停止无法确认，拒绝新音频启动，报告 handoffFailed/状态不确定，提供安全重试/隔离路径。仅命令 promise 完成不必然等价静音，Adapter 定义证据。禁止双音频。旧 stop 迟到不得停止新会话：不同实例优先，复用同实例时必须严格序列/代数与 SDK 可验证隔离。
- 交接后协调器提交新的播放计划/待确认目标；引擎确认才发布 confirmedCurrent；启动失败显示真实失败，不自动恢复旧音频、旧队列，不伪造仍在播放。状态明确区分请求接受、准备、切换中、已确认、失败、取消、过期。
- 退出电台并暂存普通队列也遵守上述屏障：旧音频停止确认后一次性提交本地 staged queue、无 current、无自动播放；禁止 stop→replaceAndPlay→pause 模拟。取消或预检失败无副作用。发布前最后校验与修改之间无 await。需要处理 stop 已成功但意图已过期的真实状态，不能显示旧音频仍在播。
- 资源释放：候选失败、被替代或退出均取消其观察与任务、关闭专用引擎；非活动引擎默认释放，必要短期保留必须有上限、理由、空闲期限，保持无声。不在 UI 可见性或动画回调释放活动音频。

## 4. 单平台队列契约
| 操作 | 同平台/有效账户作用域 | 跨平台或不匹配账户 |
|---|---|---|
| replaceAndPlay / shuffleAndPlay | 原语义 | 经切换事务替换，不自动恢复旧队列 |
| interruptAndPlay | 原语义；远端电台需确认 | 明确拒绝、零副作用 |
| prepend / append | 原语义；远端电台确认结束后暂存 | 明确拒绝、零副作用 |
| 来源/资源导航 | 纯导航 | 切换浏览上下文，不动音频 |
| 收藏/资料库 | 按资源权限 | 按目标真实平台及有效账户路由，与浏览/播放平台独立 |

队列内所有 playable entries、批次页、历史恢复需校验平台/账户作用域，公共目录也需与当前可播放会话匹配。不能向当前引擎发送另一平台 ID；禁止 ID 字符串伪装。历史、undo、分页不得跨队列或 owner/账户误触发。`QueueOwner` 与 `PlayableKind` 独立，当前 Apple Music 普通曲目仍 localCoordinator、电台 remoteEngine；其他 Adapter 可以描述远端管理的普通集合，但未验证的能力不开放。不得用本地编辑操作推断远端控制权限。真实远端列表只读仅在 Adapter 返回可验证数据时呈现。

## 5. 电台
station ID 是真实播放目标，seed resource 是创建来源，current item 为动态歌曲。切歌只更新实际歌曲关系，不改变电台身份，不继承上一首缺失关系；即使 QueueEntry UUID 不变也以 item generation / track identity 校验。直播/算法/未知类型只是内容分类，不等于播放能力；取平台、会话、资源及引擎的有效能力快照，未知保守。所有 UI、键盘、系统媒体和协调器统一检查。远端待播未知不是 0；不可构造普通列表或混入其他电台。暂停/连接/失败/恢复真实显示。电台切换普通模式依现有规则及上文音频权屏障；重启只恢复电台资源，用户主动连接，不承诺恢复同一节目或秒数。
