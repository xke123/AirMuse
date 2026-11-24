# AirMuse Core V2 — 目标架构

状态：拟实施规范；不是现有代码已实现的声明。与根目录 AGENTS.md 共同生效。

## 1. 设计目标与边界
原生 UI 快速出现，本地状态渐进恢复，网络和播放引擎独立就绪。以正确性优先于速度，优化可测量的用户等待。保留现有视觉及交互。Apple Music 目前采用 Web 会话与 Web 播放路径，未配置自有开发者凭据；平台内部接口和 WebKit 兼容性不保证稳定。仅在授权允许的范围内保留能力，不能绕过访问控制或 DRM。没有可靠身份/订阅信息时明确 unknown。Spotify/QQ Music 不在本次功能范围。

## 2. 依赖和所有权
```text
App/CompositionRoot
  ├─ Presentation → Application → Domain contracts/models
  ├─ Providers/AppleMusic → Domain contracts
  └─ Infrastructure → Domain contracts
```
Application 通过注入的协议访问平台和设施。Swift Package targets 按实际编译隔离需求调整，不为目录数量拆包。保留 DesignSystem。建议模块：App/Startup、Application/{Session,Playback,Library,Lyrics}、Domain/{Models,Contracts,States,Errors}、Providers/AppleMusic/{Authentication,Credentials,Catalog,Playback,Lyrics,Mapping}、Infrastructure/{Networking,Persistence,Cache,Security,WebKit,Diagnostics}、Presentation/{Player,Library,Account,Lyrics,Settings}。

| 组件 | 权威职责 | 不允许承担 |
|---|---|---|
| StartupCoordinator | 启动轨道、关闭和任务生命周期 | 等待网络才显示首屏 |
| SessionCoordinator (actor) | 账户会话、代际、失效事务 | 音乐数据解析、渲染 |
| CredentialService/Vault | 凭据生命周期、受支持刷新、安全保存 | 宣称用户权益 |
| LibraryRepository | 目录/个人库加载、缓存、分页、SWR | UI 操作、控制播放 |
| PlaybackCoordinator (actor) | 用户意图、队列、引擎调度、权威播放状态 | 直接操作 WKWebView |
| WebRuntime (@MainActor) | WebView 创建、挂载、保活、崩溃/销毁 | 自主改变会话 |
| PlaybackBridge/Engine | 类型化命令、事件、授权、实际副作用 | 独立决定本地下一首 |
| LyricsRepository | 歌词获取、匹配、缓存 | 阻塞音频 |
| Presentation (@MainActor) | 状态渲染、意图发送 | 私有 API、Token、SQL |

Store 使用只读快照和 AsyncStream；单一所有者写入，订阅可取消、缓冲策略有界。高频位置变化与结构状态分流，不整页重绘。

## 3. 启动及退出
启动：CompositionRoot 创建最小依赖 → 原生窗口可交互 → 并行恢复本地快照/账户、必要缓存、公开目录、按需引擎预热 → 逐步发布各子系统状态。皮肤关键资源最小预解码，其他资源延后；同步 I/O 不在 MainActor。Logo 可保留非阻塞过渡。

快照包含版本、平台、本地账户命名空间、歌曲、队列、位置、音量、循环/随机、窗口及页面状态。恢复时默认暂停，个人资源必须等待匹配账户上下文；未知身份不挂载旧个人快照。定期防抖保存，退出前有界刷新，不依赖退出时才第一次写入。退出取消长期任务、解绑系统媒体控制/观察者、停止引擎并释放 WebView；失败记录但不无限阻塞关闭。

## 4. 会话状态与事务契约
独立状态维度：
- Session: restoring / signedOut / authenticating / verifying / authenticated / offlineUnverified / invalidating / expired / failed。
- Credential: missing / available / refreshing / invalid；客户端与用户凭据分别跟踪。
- Subscription: unknown / active / inactive / unsupported。
- Catalog: idle / available / degraded / unavailable。
- Engine: idle / initializing / authorizing / ready / recovering / failed。

```swift
struct SessionContext: Sendable, Equatable {
    let providerID: String
    let accountID: String // 持久化本地记录，不冒充 Apple ID
    let storefront: String
    let sessionID: UUID
    let generation: UInt64
}
```
登录：打开官方登录 UI → 获取平台允许的授权结果 → 验证 → 持久化 → 发布可信会话 → 独立建立播放授权。登录尝试拥有 attemptID；取消后失效。恢复：读取凭据 → 标记未验证 → 允许匹配且符合政策的本地缓存 → 网络验证；离线保留但不宣称授权已确认。用户主动重新登录且无法确认同一身份时创建新命名空间。

失效事务：在会话所有者同步段递增 generation 并关闭入口 → 取消旧任务 → 隔离引擎和旧 WebKit store/回调 → 按原因处理凭据 → 解除旧缓存挂载 → 发布终态。主动退出/切换/确证用户凭据失效与网络离线、客户端凭据失效区别处理。后两者不自动删除用户凭据。不得仅按 HTTP 403 判定用户退出。

所有个人操作捕获 context，最终写入必须在同一隔离域原子验证并提交，或使用带 epoch 的数据库事务条件；禁止 validate 后再 await 无条件写入。旧 context 的缓存读写、Cookie 回调、凭据刷新、事件均拒绝。登录 WebView 与播放 WebView 仅共享同一允许的会话数据域；退出后旧实例不得重新激活账户。校验 HTTPS、精确允许域/子域边界、frame、消息类型和字段，不用 contains 判断来源。

凭据服务：区分客户端和用户授权生命周期；安全存储优先 Keychain，本地开发文件存储须明确威胁模型且不能宣称等价。旧凭据迁移失败不静默丢失设置；日志全面脱敏。按 (sessionID, credentialKind) single flight，共享任务由服务拥有，单个等待者取消不影响其他等待者；代际变化使刷新结果失效。只使用平台允许的刷新方式，无能力时要求登录，禁止伪造凭据。

## 5. 网络与数据
HTTP Client 接收 RequestPolicy（总 deadline、单次超时、retry budget、priority、auth scope、cache policy）。统一错误：offline、timeout、transport、clientCredentialInvalid、userCredentialInvalid、forbidden、subscriptionRequired、rateLimited、server、decode、notFound、cancelled、staleSession、unsupported。401/403 结合端点与证据判断；429 尊重 Retry-After；安全 GET 对临时失败有限退避加抖动；有副作用请求不盲目重试。重试共享总预算，取消不转为错误弹窗。

请求合并键包含方法、规范 URL/参数、平台、地区、账户/权限上下文；有界并发，播放/鉴权优先于后台目录及预取。单等待者取消只解除订阅；无等待者时可取消实际请求。公开目录无需等待用户验证。API 解析通过领域映射层，拒绝以排行榜冒充个人歌曲、普通资料库冒充收藏。

LibraryRepository 支持首页、浏览、编辑精选、电台、榜单、新发行、公开/个人搜索、歌曲/专辑/艺人/歌单、收藏、推荐、最近添加、详情和曲目。按真实平台能力返回 unavailable/unsupported。分页以 cursor/next、完整性、去重及有界并发管理；检测循环游标；首屏优先，不把首批当完整库。搜索 debounce、取消和 query generation；分类快速切换丢弃旧结果。

## 6. 缓存与持久化
```text
UI → Repository → Memory LRU → SQLite → Remote
```
Key = provider + scope(public/account) + accountID(if private) + storefront + resource + normalizedParameters + schemaVersion。条目包括 fetchedAt、expiresAt、lastAccessedAt、completeness、source、payload。私有数据不能跨账户挂载；未识别旧 JSON 个人数据直接安全失效，不自动迁移。数据库事务、迁移、损坏重建仅影响可再生缓存；不可恢复设置单独保存。

SWR：有效缓存立即渲染 → 必要时后台刷新 → 成功原子提交并差量通知 → 失败保留允许展示的旧数据并标记 stale/offline。无缓存才显示首屏 loading。空结果是成功的空数据，不是错误。超过策略允许陈旧期限时不得展示私有缓存。以下为初始可调策略，实施时记录基线并调整：公开目录 1h TTL/7d stale；个人库 5min/24h（仅已匹配本地账户）；推荐 15min/24h；搜索内存 2min；歌曲详情 24h；歌词按来源版本管理。TTL 不代表授权有效期。初始图片预算内存 50MB、磁盘 300MB，结构缓存 100MB；以测量调整，清理策略 LRU/过期优先。封面键含 URL+像素尺寸，有界解码与请求合并；歌词键含平台+录音 ID+版本/来源，偏移量持久化。受保护音频由官方播放环境管理，不自行缓存。

## 7. 播放引擎与队列
```swift
struct PlaybackOperationContext: Sendable {
    let sessionID: UUID
    let engineInstanceID: UUID
    let operationID: UInt64
    let trackID: String
}
```
所有入口（主播放器、Mini、音乐库、系统媒体键、自动下一首）进入 PlaybackCoordinator。维护 desiredTrack、actualTrack、desiredTransport、actualState、queueOwner、operationID。状态 idle/preparing/buffering/playing/paused/seeking/recovering/ended/failed。新意图立即反馈 metadata+loading，不虚报 playing。引擎仅在可信 readiness 事件后执行，必要时有界轮询。Command/Result/Event 带引擎、会话、操作标识及歌曲身份；拒绝旧实例/旧歌曲/乱序事件。

冲突命令（setQueue/play/pause/stop/seek）串行执行或等价安全调度；等待过程中保留最新目标。取消 Swift Task 不等于取消 JS 副作用。旧命令无法取消时待其结束并校正最新目标；若超时且副作用状态不确定，隔离旧引擎并受控重建，禁止直接在同一不确定引擎重叠执行。暂停/退出使待播放操作失效，连续 seek 合并最新目标。命令接受与播放事件分别记录。只有可信当前歌曲播放事件/进度证据可标记 playing；不声称检测物理音频输出。

队列所有权：本地队列由 Coordinator 推进，远端电台/平台控制队列显式由 Engine 管理，禁止双重自动下一首；同一结束事件去重。个人库 ID 映射按账户/地区隔离，未找到返回真实错误。WebKit JS 使用类型化参数，不拼接不可信输入；登录及播放路径保留已验证兼容性，但不得绕过平台授权。

引擎崩溃：旧 engineID 立即失效 → recovering → 有界重建（初始最多 2 次，冷却退避）→ 确认会话和最新意图 → 平台允许时恢复歌曲/进度，否则失败并允许手动重试。关闭音乐库不释放活跃引擎。时间锚点使用单调时钟插值，暂停/缓冲/seek/切歌校正，避免高频 JS 查询。封面歌词独立任务绑定操作上下文。

## 8. 性能、可观测性与验收
目标（非实测）：正常 Apple Silicon 冷启动 UI 可交互 ≤500ms；常规本地缓存 ≤100ms；点击反馈 ≤50ms；60Hz 帧预算 16.7ms；良好网络已预热引擎首有效播放事件争取 1–2s。外部延迟统计 P50/P95/失败率，注明冷/热、网络和设备。记录 OSSignposter 启动/缓存/会话/引擎/首播阶段；Instruments 检查 MainActor、CPU、主进程及 WebKit 子进程内存、长时间增长。日志只记录脱敏关联 ID、状态及耗时，有界轮转。测试使用可控时钟、transport、store、engine 与乱序事件；真实账户/DRM/网络验证单列，不以 Mock 代替。详细任务见 ROADMAP。
