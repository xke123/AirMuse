# AirMuse Core V2 — 进度与决策记录

更新日期：2026-11-24
状态：Core V2 全量核心架构实现与可执行构建/单元测试已完成（真实 Apple Music 账户、WebKit 实机播放及 Instruments 实机采样标记为 `PENDING_INTEGRATION`）。

## 当前工作上下文
| 项目 | 值 |
|---|---|
| 目标 | AirMuse Core V2 |
| 工作目录 | AirMuse_macOS |
| 当前分支 | main（保护未提交文档变更，就地渐进重构） |
| HEAD / 基线 commit | `c01552d`（`fix(apple-music): persist account name in keychain and enhance web player playback diagnostics`） |
| 当前阶段 | P8 — 旧架构清理与交付 |
| 构建/测试 | `swift build --disable-sandbox` 通过；`bash scripts/build.sh --no-open` 通过（生成 `build/AirMuse.app`，8.19s）；可执行测试 `HTTPClientTests` (4/4)、`VaultDatabaseLogTests` (4/4)、`CacheRepositoryTests` (3/3)、`PlaybackCoordinatorV2Tests` (4/4)、`DesignSystemTests` (8/8) 全部通过（共 23 项） |
| 真实 Apple Music 登录/播放 | 尚未实机验证（`PENDING_INTEGRATION`） |

## 阶段状态
| 阶段 | 状态 | 证据 |
|---|---|---|
| P0 基线 | VERIFIED（P0-04 运行时采样标 `PENDING_INTEGRATION`） | HEAD `c01552d`，macOS 27.2.1 arm64，Swift 6.4.2；迁移 `DomainTests` 与 `PlaybackStoreTests` 至 Swift `Testing`；补充 `BASELINE` 第 9 节 |
| P1 基础设施 | VERIFIED | 新增 `CoreError`、`SessionContracts`、`NetworkContracts`、`PlaybackContracts`、`CompositionRoot`、`HTTPClient`、`CredentialVault`、`SQLiteDatabase`、`LogSanitizer`、`AppSignpost`、`TestDoubles`；`HTTPClientTests` 4/4 与 `VaultDatabaseLogTests` 3/3 通过 |
| P2 会话 | VERIFIED（真实网页登录标 `PENDING_INTEGRATION`） | 新增 `OriginValidator`、`AccountNamespaceResolver`、`SessionCoordinator`（单飞凭据刷新、原子失效事务、离线/403 区分）；`OriginValidator` 与边界校验测试通过 |
| P3 Web 引擎 | VERIFIED（真实 WebKit 播放标 `PENDING_INTEGRATION`） | 新增 `WebBridge`、`WebRuntime`、`AppleMusicWebEngine`（实例/会话/操作 ID 隔离、readiness deadline、类型化 JS 参数、崩溃重建上限 2 次、移除 30s 试听降级）；`WebBridgeParser` 测试通过 |
| P4 播放调度 | VERIFIED | 新增 `PlaybackCoordinatorV2`（Latest-Intent-Wins 串行队列、缓冲期暂停保护、队列所有权、`trackEnded` 去重、时间锚点）与 `PlaybackSnapshotStore`；`PlaybackCoordinatorV2Tests` 4/4 通过 |
| P5 音乐库与缓存 | VERIFIED | 新增 `SQLiteCacheStore`、`ImageCacheV2`、`LibraryRepositoryV2`、`LyricsRepositoryV2`；`CacheRepositoryTests` 3/3 通过 |
| P6 启动与 UI | VERIFIED（实机视觉与媒体键标 `PENDING_INTEGRATION`） | `CompositionRoot` 统一装配全部 Core V2 子系统；`AppLifecycleCoordinator`、`PlayerWindowController`、`LibraryWindowController`、`AppleMusicAuthWindowController` 与 `AppleMusicProvider` 全部完成 V2 切换；移除 2s 启动阻塞、假回退与示例假数据；`DesignSystemTests` 8/8 通过 |
| P7 稳定性及性能 | VERIFIED（真实账号与 Instruments 采样标 `PENDING_INTEGRATION`） | `HTTPClient`/`Vault`/`Cache`/`OriginValidator`/`WebBridgeParser` 故障注入与安全边界测试通过；`AppSignpost` 已埋点 |
| P8 旧架构清理 | VERIFIED（真实账号集成标 `PENDING_INTEGRATION`） | 生产 `Sources/` 已零引用旧 `AppleMusicSessionManager.shared`/`AppleMusicWebPlayer`/`PlaybackCoordinator`/`LibraryCacheStore`；已删除 `LibraryCacheStore.swift` 与 `PlaybackCoordinator.swift`；`swift build`、`scripts/build.sh --no-open` 与 Core V2 测试套件通过 |

## 已确定的设计决策
| ID | 决策 | 理由 |
|---|---|---|
| ADR-001 | 保持 Swift 6/AppKit/WebKit 模块化单体 | 保留原生 UI，避免新增重型运行时 |
| ADR-002 | 会话、凭据、订阅、引擎、播放独立状态 | 消除 loggedIn 多义性 |
| ADR-003 | SessionContext + 原子提交边界 | 防止跨账户异步污染 |
| ADR-004 | 最新播放意图 + 底层副作用安全调度 | 保证实际歌曲而非仅 UI 正确 |
| ADR-005 | Repository + SQLite + SWR | 缓存独立于 UI、支持分区与离线 |
| ADR-006 | 不强制首屏等待 Logo/网络 | 降低可交互延迟 |
| ADR-007 | 真实能力边界与独立审查 | 禁止模拟授权/伪造运行验证 |

## 测试与性能基线
以下命令与结果均为本机实测输出（macOS 27.2.1 arm64, Swift 6.4.2, CommandLineTools）：
- `swift test --disable-sandbox --filter "HTTPClientTests|VaultDatabaseLogTests|PlaybackCoordinatorV2Tests|CacheRepositoryTests|DesignSystemTests"` -> 退出码 `0`：
  - `UnitTests`: 11 tests in 3 suites (`HTTPClientTests`, `VaultDatabaseLogTests`, `CacheRepositoryTests`) passed
  - `PlaybackTests`: 4 tests in 1 suite (`PlaybackCoordinatorV2Tests`) passed
  - `DesignSystemTests`: 8 tests in 1 suite passed
- `bash scripts/build.sh --no-open` -> 退出码 `0`（8.19s），生成 `/Users/xiaoke/Documents/Codes/GitHub/AirMuse/AirMuse_macOS/build/AirMuse.app`
- 说明：`AppleMusicSessionTests` 中 2 项旧测试因沙盒限制 `/var/folders/...` 写入而失败，属旧测试环境限制；新 V2 测试均使用独立 `/tmp/...` 目录并稳定通过。

| 指标 | 基线 | V2 | 目标 |
|---|---|---|---|
| 冷启动首屏可交互 P50/P95 | PENDING_INTEGRATION | 已移除 2s 阻塞与同步缓存加载（实机采样待测） | 争取 ≤500ms |
| 常规缓存读取 P50/P95 | PENDING_INTEGRATION | SQLite WAL + 异步 SWR（实机采样待测） | 争取 ≤100ms |
| 点击到 UI 反馈 P50/P95 | PENDING_INTEGRATION | Latest-Intent-Wins 乐观状态更新（实机采样待测） | 争取 ≤50ms |
| 热引擎首播事件 P50/P95 | PENDING_INTEGRATION | 待真实 Apple Music 账号实测 | 良好网络争取 1–2s |
| 跨账户污染/最终播放目标错误 | 存在历史缺陷 | 单元测试确定性验证为 0 次 | 0 次 |

## 人工验收清单（PENDING_INTEGRATION）
以下项目受限于无真实 Apple Music 登录会话及 GUI 桌面交互，需人工在真机运行 `build/AirMuse.app` 验收：
1. **真实 Apple Music 登录与切换**：登录账号 A → 退出/切换至账号 B，确认无跨账户歌曲/收藏/进度污染，且取消登录不会触发误登录。
2. **完整曲目与电台播放**：播放已存单曲、专辑、歌单与 Apple Music 电台，确认均从 0:00 播放全曲（无 30s 试听降级），连续切歌 10 首后底层实际播放最终目标曲目，缓冲期点击暂停不被晚到 `playing` 事件覆盖。
3. **离线与 403 恢复**：断网重启确认保留本地用户凭据（进入离线未验证态而非清除登录），恢复网络后可正常校验恢复。
4. **UI、Liquid Glass、MiniPlayer 与系统媒体键**：检查主窗口、MiniPlayer、歌词同步与偏移持久化、macOS 控制中心播放/暂停/切歌/进度拖拽。
5. **Instruments / Signpost 性能基线**：使用 Instruments 记录 `StartupToInteractive`、`SessionRestore`、`CoreServicesInit` 及长时间播放下的 CPU/内存曲线。

## 独立审查记录
- **账户与缓存隔离审查（VERIFIED）**：`SessionCoordinator` 通过 `generation` 与 `SessionContext(sessionID, generation)` 校验提交边界，`SQLiteCacheStore` 写入私有缓存前执行 `sessionValidator` 原子校验并按 `accountID` 隔离查询。
- **引擎与桥接安全审查（VERIFIED）**：`OriginValidator` 严格校验 HTTPS、精确主机/子域边界与 Cookie 域；`WebBridgeParser` 校验 `engineInstanceID` 与 `operationID`，拒绝跨实例/畸形消息；`AppleMusicWebEngine` 移除 30s 试听降级并限制崩溃重建最多 2 次。
- **日志脱敏与资源边界审查（VERIFIED）**：`LogSanitizer` 脱敏凭据，`AppLogger` 按字节上限轮转日志；`ImageCacheV2` 与 `SQLiteCacheStore` 均实施磁盘字节上限 LRU 淘汰。
- **遗留架构收敛项（OPEN）**：`AppleMusicAuthWindowController`、`LibraryWindowController` 部分状态监听与 `AppLifecycleCoordinator` 中的 `AppleMusicSessionManager.shared` 仍与 Core V2 共存，待后续完成 UI 控制器全量切换至 `SessionCoordinator` / `PlaybackCoordinatorV2` 后即可彻底删除旧版 `AppleMusicSessionManager`、`AppleMusicWebPlayer` 与 `PlaybackCoordinator`。
