# PD — 模块依赖与应用服务

## 1. 编译依赖 DAG（箭头为依赖方向）
```
App -> UI, Application, Playback, PlatformRuntime, Adapter targets, Infrastructure
UI -> Domain, Application, Playback, Lyrics, DesignSystem, generic Infrastructure
Application -> Domain, Playback, PlatformRuntime, generic Infrastructure
Playback -> Domain, generic Infrastructure
PlatformRuntime -> Domain, generic Infrastructure
AppleMusicAdapter / SpotifyAdapter / QQMusicAdapter -> Domain, generic Infrastructure
Lyrics -> Domain, Playback, generic Infrastructure
DesignSystem -> Domain
Infrastructure -> Domain
Domain -> Foundation / system value types only
```
PlatformRuntime 通过 Domain 中注册/engine factory 协议接收适配器；不 import 具体 Adapter，也不依赖 Playback/Application/UI。PlaybackCoordinator 可继续持有 `let engine: any PlaybackEngineProtocol`，由 App 注入稳定 Router facade；如需显式 prepare/switch 契约，定义在 Domain，避免循环依赖。Router 负责引擎与音频权，不拥有歌曲队列。具体 Adapter 不能反向 import UI/Application/Playback 来执行播放命令。平台授权呈现独立为 AppleMusicIntegrationUI 等可选 target，依赖具体 Adapter 和通用视觉组件，由 App 注入通用账户呈现协议，通用 UI 不反向依赖它。现有 Providers 聚合 target 可短期兼容，最终通用链路不得 import 或通过其它 target 间接依赖它；测试依赖随生产拆分。

## 2. 运行时所有者
| 状态 | 权威所有者 | 禁止 |
|---|---|---|
| 当前浏览 route/加载态 | Browse/Navigation application state | 改变播放平台 |
| 平台会话 | ProviderSessionRegistry，按平台/账户隔离 | 全局唯一 Apple Music 会话驱动全部平台 |
| 当前音频权/底层引擎 | EngineRouter | 再建一套 QueueManager |
| 播放计划、确认歌曲与来源 | PlaybackCoordinator / QueueManager / PlaybackStore | Router/UI 维护第二 currentTrack/currentOrigin |
| 资源操作状态 | 现有 MediaResourceStateStore 迁移至通用应用服务 | 按浏览平台缓存所有资源 |
| 视觉浮层/焦点/动画 | UI | 在动画完成时修改播放语义 |

## 3. Controller 拆分（逐步迁移，不一次性重写）
- BrowseService：按 descriptor/route 取栏目及页面；将平台原始推荐、AMP 分类、资源映射留在 Adapter。缓存及错误统一。
- Search/CollectionService：搜索、详情、分页游标、完整集合解析；封装跨 await 与请求身份。复用同一个集合加载/队列提交逻辑。
- PlaybackIntentService：冻结选择与来源，验证单平台队列作用域、能力及切换确认，把五种播放意图提交现有协调器。不能直接操作引擎。
- MediaActionService：现有 Resolver 仍为纯函数；Dispatcher 根据目标 identity 路由；状态 Store 迁移但不复制。支持队列右键菜单与当前浏览不一致的目标。
- NavigationService：纯内部路由；切换浏览上下文并打开资源，按可信 identity 去重及有界定位；没有页面就提示，绝不触发播放、重启电台或资源写入。
- AccountService：统一账户快照与登录/退出命令；实际认证由 Adapter 完成。平台专用 presenter 注入。
- Controller：窗口/布局、渲染、焦点、菜单呈现、视觉反馈；消费低频状态并发意图。不得读 AMP、token、SDK 或根据 ID 前缀分支。分阶段以已有功能调用链为单位迁移。

## 4. 端到端调用
浏览: UI -> BrowseService -> Registry.resolve(browseScope) -> Adapter -> 通用 Page -> UI。
播放: UI -> PlaybackIntentService -> Coordinator -> Router -> Engine -> 事件 -> Coordinator -> Store -> UI。
收藏: UI -> MediaActionService -> resourceScope 的 MutationProvider -> 状态 Store -> 差量订阅。
来源: QueueEntry.origin -> Resolver -> NavigationService -> 源平台 BrowseService -> 页面定位。此路径不能调用 PlaybackIntentService。

## 5. 歌词及基础设施
保留 LyricsRepository 与 LyricsEngine，第三方歌词检索从 AppleMusicProvider 移到独立通用歌词 source（不新增外部接口或权限），按当前实际歌曲、平台/版本/时长及语言匹配，远端动态歌曲变化取消旧查询。不能把标题相似作为资源 ID；歌词可有降级匹配但明确来源，不能跨私人会话泄漏。HTTP/Keychain/SQLite/ImageCache 复用；平台认证、请求 URL/签名/SDK/桥接只在 Adapter。WebKit 通用宿主可在 Infrastructure，但平台专有脚本、cookie lifecycle 不进入通用 UI。
