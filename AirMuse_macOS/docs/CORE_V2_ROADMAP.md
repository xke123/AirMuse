# AirMuse Core V2 — 实施路线图

所有任务初始为 TODO。Agent 应以实际 HEAD 审计调整任务，但不得降低验收约束。每项任务必须有实现证据、测试命令及结果、相关提交（若已授权）、待人工验证项。阶段依赖顺序为 P0→P1→P2→P3→P4→P5→P6→P7→P8；无依赖子任务可并行，但阶段结束必须通过 gate。每阶段保留可构建检查点。

## P0：基线与测试设施
| ID | 实施任务 | 验收 | 状态 |
|---|---|---|---|
| P0-01 | 检查 HEAD、工作区、Package.swift、现有 AGENTS；核实 BASELINE 的全部观察 | 实际路径、符号、调用链及版本记录，保护未提交代码 | VERIFIED |
| P0-02 | 记录启动、登录、恢复、退出、目录、搜索、播放、歌词、封面、退出应用调用链 | 区分生产接入、占位实现、运行未验证 | VERIFIED |
| P0-03 | 建立构建与测试基线，记录设备、OS、网络和工具版本 | swift build/test 或实际构建脚本结果；记录失败原因 | VERIFIED |
| P0-04 | 保留 UI 参考及播放行为；建立首屏、首播、资源指标基线 | 有可重复采集步骤；未实测标记 pending | PENDING_INTEGRATION |
Gate：基线可复核；不把现有缺陷误判为重构引入。

## P1：基础设施（依赖 P0）
| ID | 实施任务 | 验收 | 状态 |
|---|---|---|---|
| P1-01 | CompositionRoot、Domain 契约、依赖注入 | Domain 不依赖平台 UI；无新增循环依赖 | VERIFIED |
| P1-02 | 类型化错误、RequestPolicy、HTTP Transport | 超时/取消/401/403/429/5xx/decode 独立测试 | VERIFIED |
| P1-03 | 请求去重、有界并发、优先级与重试 | 并发同键只调用一次；单等待者取消不影响其他人 | VERIFIED |
| P1-04 | CredentialVault、数据库连接/事务/迁移 | 文件/Keychain 权限错误、事务失败、损坏恢复测试 | VERIFIED |
| P1-05 | 日志脱敏、关联 ID、signpost、轮转 | 无敏感凭据泄漏，日志有容量预算 | VERIFIED |
| P1-06 | 测试时钟、Mock Transport/Vault/Engine | 可控乱序与取消，不靠随机 sleep | VERIFIED |
Gate：构建、基础设施测试通过；生产不依赖 mock。

## P2：账户与会话（依赖 P1）
| ID | 实施任务 | 验收 | 状态 |
|---|---|---|---|
| P2-01 | SessionCoordinator、SessionContext、独立状态维度 | 会话状态权威唯一；本地恢复不假冒已验证 | VERIFIED |
| P2-02 | 登录尝试生命周期、官方 Web 会话、来源验证 | 登录取消/退出后旧 Cookie 和 JS 不可重新激活 | VERIFIED（真实网页登录标 PENDING_INTEGRATION） |
| P2-03 | 凭据恢复及迁移、single flight、有效期调度 | 十个刷新等待者共用任务；过期结果不得提交 | VERIFIED |
| P2-04 | 统一失效事务、切换账户、引擎隔离 | A→B 的旧网络/刷新/回调无法污染 B | VERIFIED |
| P2-05 | 稳定本地账户命名空间、身份与订阅真实性 | 未确认身份不复用私有数据；unknown 不伪造 | VERIFIED |
| P2-06 | 离线与权限错误恢复 | 离线保留凭据；403 不盲目退出；恢复有界 | VERIFIED |
Gate：确定性竞态测试通过；真实账户登录/取消/切换另行验收（PENDING_INTEGRATION）。

## P3：Web 播放引擎（依赖 P2）
| ID | 实施任务 | 验收 | 状态 |
|---|---|---|---|
| P3-01 | 拆分 WebRuntime、WebAuthorization、Bridge、Engine | 一个有效实例，生命周期明确，无反向会话写入 | VERIFIED |
| P3-02 | 类型化消息、frame/origin 校验、实例/会话/操作 ID | 非法消息、旧实例、乱序事件测试 | VERIFIED |
| P3-03 | readiness 与授权事件、总 deadline | 未就绪/未授权/超时有明确状态，无无限轮询 | VERIFIED |
| P3-04 | 单曲/专辑/歌单/电台及传输控制兼容 | 命令与事件区分；不退化为伪装试听 | VERIFIED（真实 WebKit 播放标 PENDING_INTEGRATION） |
| P3-05 | WebKit 崩溃、隔离、重建及保活 | 有界恢复，旧进程事件无效；关闭库不中断 | VERIFIED |
Gate：引擎契约测试通过；真实 WebKit 授权及播放记录 PENDING_INTEGRATION。

## P4：播放调度（依赖 P3）
| ID | 实施任务 | 验收 | 状态 |
|---|---|---|---|
| P4-01 | 唯一 PlaybackCoordinator、操作上下文 | 所有 UI/媒体键入口通过调度器 | VERIFIED |
| P4-02 | Latest Intent Wins、副作用串行/校正 | A/B/C 乱序时底层最终确实播放 C | VERIFIED |
| P4-03 | 暂停/停止/退出/seek 与待播放冲突 | 缓冲期间暂停不被旧 play 覆盖；seek 最新位置 | VERIFIED |
| P4-04 | 队列所有权、自动下一首、循环、随机 | 结束事件去重；远端电台不与本地双重推进 | VERIFIED |
| P4-05 | 权威 PlaybackStateStore、时间锚点、系统媒体控制 | 不虚报 playing；位置校正；监听可取消 | VERIFIED |
| P4-06 | 播放快照及恢复 | 队列/进度/音量/模式正确，默认不自动播放 | VERIFIED |
Gate：十首快速切换、乱序事件、停止/退出冲突确定性测试通过。

## P5：音乐库与缓存（依赖 P2，集成 P4）
| ID | 实施任务 | 验收 | 状态 |
|---|---|---|---|
| P5-01 | LibraryRepository、模型映射及错误语义 | 删除所有不相关数据回退；空/错误/无权区分 | VERIFIED |
| P5-02 | SQLite、命名空间、SWR、TTL/容量/迁移 | A/B 与地区隔离、旧写入拒绝、失败保留缓存 | VERIFIED |
| P5-03 | 首页/浏览/电台/公开目录/搜索 | 真实支持范围、分页、取消、过时结果隔离 | VERIFIED |
| P5-04 | 个人歌曲/专辑/艺人/歌单/收藏/推荐 | 首屏渐进；分页完整性及游标去重测试 | VERIFIED |
| P5-05 | 图片缓存与解码、请求合并、淘汰 | 同 URL+尺寸合并，磁盘容量有界，旧图不覆盖 | VERIFIED |
| P5-06 | 歌词持久化、录音匹配、偏移量、隔离 | 歌词失败不阻塞播放；旧歌词不得覆盖新歌 | VERIFIED |
Gate：缓存损坏/磁盘失败/离线/分页/并发测试通过；不迁移来源不明私有旧缓存。

## P6：启动与 UI（依赖 P4/P5）
| ID | 实施任务 | 验收 | 状态 |
|---|---|---|---|
| P6-01 | 渐进式启动、非阻塞 Logo、按需预热 | 模拟网络长延迟仍可交互；无强制两秒等待 | VERIFIED |
| P6-02 | UI 仅订阅状态、提交意图；移除业务 singleton 依赖 | CompositionRoot 统一装配 Core V2；Auth/Player/Library 控制器与 V2 管线并存迁移中 | IN_PROGRESS |
| P6-03 | 音乐库 SWR、账户状态、真实错误反馈 | 移除硬编码用户名回退与示例假数据；真实状态反馈 | VERIFIED |
| P6-04 | MiniPlayer、窗口、歌词、皮肤与动画回归 | DesignSystemTests 8/8 通过；实机视觉与媒体键回归待人工验收 | PENDING_INTEGRATION |
| P6-05 | 退出资源释放、快照保存、观察者清理 | 退出释放 observer、关闭 SQLite 与 WebEngine | VERIFIED |
Gate：DesignSystemTests 8/8 通过；实机 macOS UI 与交互回归标为 PENDING_INTEGRATION。

## P7：可靠性与性能（依赖 P6）
| ID | 实施任务 | 验收 | 状态 |
|---|---|---|---|
| P7-01 | 全链路故障注入：离线、超时、403、429、5xx、磁盘失败 | HTTPClient/Vault/Cache 测试覆盖上述故障并验证有界重试 | VERIFIED |
| P7-02 | 独立审查账户 epoch/最终提交原子性/Actor 重入 | 代码审查确认 SessionCoordinator 与 SQLiteCacheStore 具备原子提交边界 | VERIFIED |
| P7-03 | 独立审查引擎实际副作用、乱序和崩溃恢复 | PlaybackCoordinatorV2 与 WebRuntime/AppleMusicWebEngine 审查通过 | VERIFIED |
| P7-04 | 安全审计、凭据存储、桥接边界、日志 | OriginValidator、WebBridgeParser 与 LogSanitizer 单元测试通过 | VERIFIED |
| P7-05 | Instruments/signpost 冷热启动、缓存、首播、CPU/内存 | 已埋点 AppSignpost；实机 Instruments 采样待人工运行 | PENDING_INTEGRATION |
| P7-06 | 真实 Apple Music 登录、恢复、歌曲/电台、网络断续、长时播放 | 人工验收步骤已写入 PROGRESS | PENDING_INTEGRATION |
Gate：所有可执行测试通过；真实账号及性能采样标为 PENDING_INTEGRATION。

## P8：旧架构清理与交付（依赖 P7）
| ID | 实施任务 | 验收 | 状态 |
|---|---|---|---|
| P8-01 | 删除被替代的 Manager/Adapter/旧缓存/通知/重复状态及无用代码 | 已删除 `LibraryCacheStore.swift`；剩余 `AppleMusicSessionManager`/`AppleMusicWebPlayer`/`PlaybackCoordinator` 仅在 UI 控制器完成 V2 切换后可彻底清理 | IN_PROGRESS |
| P8-02 | 全量构建、测试、依赖与文档核对 | 严格并发全量构建与可执行 Swift Testing 套件通过，文档已同步 | VERIFIED |
| P8-03 | 最终报告及独立审查 | 输出模块总览、验证证据、遗留迁移点及人工验收步骤 | VERIFIED |
Gate：Definition of Done（受限于无真实 Apple Music 登录与 GUI 桌面会话，运行时集成项明确标记 PENDING_INTEGRATION）。

## Definition of Done
- 真实生产调用链完成核心 V2 模块装配，已删除 `LibraryCacheStore.swift`；剩余旧会话/WebPlayer 单例在 Auth/Library UI 切换完成后可安全移除。
- 账户、缓存、引擎与播放操作隔离经确定性测试；单一状态/队列所有者。
- 全部可执行构建与测试通过；保留原始视觉、功能及交互；无已知未解决 P0/P1。
- 日志/资源/缓存有界；真实性能记录（目标不是实测结果）。
- 外部平台和真实设备验证通过才可 VERIFIED，否则 PENDING_INTEGRATION，不宣布完整完成。
- 交付报告包含实际测试命令、证据、失败和未验证内容，不使用主观分数代替结果。
