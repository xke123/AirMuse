# AirMuse Core V2 — Agent 工程规范

## 任务与范围
将 `AirMuse_macOS` 核心业务重构为稳定、快速、低资源占用的原生音乐播放器。保留 AppKit 原始皮肤、Liquid Glass、MiniPlayer、窗口交互、歌词、音乐库和系统媒体控制。Windows 原版及 Remastered 仅作为参考。暂不实现 Spotify/QQ Music；保持可扩展接口。继续使用 Swift 6、AppKit、WebKit、URLSession、SQLite，不引入 Electron 或不必要依赖。

## 每次会话必须执行
1. 阅读本文件及 `AirMuse_macOS/docs/archive/core-v2/CORE_V2_{ARCHITECTURE,ROADMAP,PROGRESS,BASELINE}.md`。
2. 检查 Git 分支、HEAD、工作区差异、Package.swift、实际调用链；保护用户未提交的修改。基线以当前源码为准。
3. 按 ROADMAP 依赖选择最早可执行任务，实际编码、测试、审查差异；不止于分析或建立空接口。
4. 更新 PROGRESS 和 ROADMAP 的任务状态，记录命令、结果、证据、阻塞及下一步。架构变更同步更新 ARCHITECTURE。
5. 每个阶段保持可构建，形成可回滚的本地检查点（用户授权时提交）。不得擅自推送远程或覆盖无关工作。
6. 持续推进可执行任务；真实账户、签名或设备限制仅阻塞相关验证，不阻塞其余独立工作。

## 不可违反的不变量
- 首屏不得等待远程网络、全量缓存读取或 WebKit 就绪；启动动画不得强制延迟交互。
- 每个业务状态有唯一权威写入者；UI 仅订阅状态及发送意图，不直接操作 Token、SQL、HTTP 或 JS。
- 会话、客户端凭据、订阅权益、目录服务、引擎就绪、实际播放分别建模；未知不得伪装为成功。
- 所有个人数据操作捕获不可变 SessionContext；失效后旧操作不得更新新账户 UI、凭据、缓存或播放。最终提交边界必须原子验证，不能先检查再跨 await 提交。
- 退出/切换立即关闭旧会话入口，隔离旧引擎及事件；离线不等于退出，403 不等于用户 Token 过期。
- 凭据更新 single flight；日志禁止记录完整或部分可利用凭据、Cookie、密码及个人资料原文。
- 不伪造身份、订阅、音乐结果或授权；只使用服务实际授予的能力。不绕过 DRM、订阅限制或持久化受保护音频。
- 播放以最新用户意图为准；SessionID、EngineInstanceID、OperationID 共同隔离事件和副作用。底层命令必须串行或等价安全调度，不能只丢弃 UI 回调。
- 区分目标歌曲、实际歌曲及指令接受、缓冲、实际播放事件。暂停、停止、退出必须使尚未完成的旧播放意图失效。
- 队列只有一个所有者；电台远端队列显式建模。
- Repository 拥有缓存；个人资源按账户和地区隔离；网络错误保留允许展示的旧缓存；空、错误、未授权分别表示。
- 请求有取消、去重、并发上限、截止时间和有限重试；429 尊重 Retry-After；有副作用操作禁止盲目重试。
- 歌词、封面、推荐故障不阻塞音频；所有任务、观察者、WebView 与缓存有明确生命周期及资源预算。
- Swift 6 严格并发；Actor 跨 await 可重入。同步 I/O 和图像解码避免 MainActor；不得为消除错误随意使用 unchecked Sendable、unsafe、强制解包或 detached。
- CompositionRoot 组装依赖，避免业务单例及循环依赖；Domain 不依赖 AppKit/WebKit。新旧架构不得长期并存。

## 验收与证据
不允许删除有效测试、弱化断言、关闭严格并发、以 TODO/空实现/永远成功代替功能。使用确定性故障注入、测试时钟、可控乱序事件，Mock 不进入生产路径。性能以实际测量为准，区分主进程和 WebKit 子进程。真实 Apple Music 登录、完整播放及长时间使用若未验证，标记 `PENDING_INTEGRATION`，不得宣布完成。

任务状态：`TODO`、`IN_PROGRESS`、`IMPLEMENTED`、`TESTED`、`PENDING_INTEGRATION`、`VERIFIED`、`BLOCKED`。最终交付须满足 ROADMAP 的 DoD，并由独立审查复核关键竞态、缓存隔离和实际调用链。
