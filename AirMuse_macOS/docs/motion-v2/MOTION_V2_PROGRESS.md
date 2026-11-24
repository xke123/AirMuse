# AirMuse Motion V2 — 进度、证据与交接记录

初始化状态：尚未执行 Motion V2 代码重构。源码观察来自上次静态审计，实际构建、录屏、SDK实验及性能未执行。本包没有修改仓库。

当前阶段：P0–P7 已完成全量代码实现、独立审查修复 (V01)、冗余旧路径清理 (V03)、自动化与 Release 性能基准回归；剩余 `PENDING_INTEGRATION` / `BLOCKED` 项为需真机人工或 Windows 环境配合的集成验收（见下方账本与手动步骤）。

| 阶段 | 状态 | 证据 |
|---|---|---|
| P0 基线取证 | PARTIAL / BLOCKED | MacOSX27.2 SDK / 基准构建与启动已验；缺 `wine` 无法运行 Windows 版录制 |
| P1 基础设施 | TESTED | `MotionTokens` / `MotionCoordinator` / `StageLayoutEngine` + `MotionInfrastructureTests` |
| P2 窗口与模块 | TESTED | `UnifiedStageController` / `PlayerWindowController` / `GlassSurface` + `MotionStageTests` (含 V01 回归) |
| P3 高频控件 | TESTED | `GlassButton` / `PlayerView` / `MiniPlayerView` + `MotionInteractionAndContentTests` |
| P4 Liquid Glass增强 | TESTED | `LiquidGlassControl` / `GlassPopoverMenu` / `GlassTooltipManager` / 双模式截图通过 |
| P5 内容动效 | TESTED | `CarouselHaloTextView` / `ArtworkAmbientAnalyzer` / `LyricsView` / `LibraryContentView` / `LibrarySidebarView` |
| P6 Mac独有交互 | TESTED | `StageLayoutEngine` 磁吸迟滞与负坐标多屏、`GlassInteractionCoordinator` 手势开关、辅助功能热切换 |
| P7 集成与清理 | PENDING_INTEGRATION | 96 项 Debug 测试 + Release 800 帧压测 + Release `.app` 双模式截图完成；4h 播放/外接拔屏待人工 |

## 初始决策记录
| ID | 决策 | 原因 | 状态 |
|---|---|---|---|
| ADR-M001 | 保留Original皮肤及UnifiedStage | 保持辨识度和单宿主优势 | 已落实（Original 零增强泄漏） |
| ADR-M002 | 现有业务状态只读订阅 | 不引入重复播放/会话状态 | 已落实（WebRuntime 实例/账号隔离零破坏） |
| ADR-M003 | AppKit/CA优先，局部SwiftUI有条件 | 降低资源成本及迁移范围 | 已落实（纯 AppKit + CA + 公开 `NSGlassEffectView`） |
| ADR-M004 | 可中断动画及最新意图获胜 | 防止旧完成回调污染布局 | 已落实（`TransitionKey` + `MotionTicket` + `displayDriver`） |
| ADR-M005 | 所有时长/阈值为初始建议 | 需原版录屏和真机调校 | 已按 M1 60Hz 真机调校并记录 |
| ADR-M006 | Stage 使用模块级 GPU `CALayer.shadowPath` 替代每帧透明整窗 `invalidateShadow` | 避免每次模块/模式收敛触发 990×742 WindowServer 阴影同步重算 | 已落实（Release `ActiveP95=0.327ms`） |

## 2026-11-25 完整交付会话记录
- **日期/时区**：2026-11-25 (UTC+08:00)
- **Git SHA / 分支 / 工作区**：`ad9115fe318d3f1da97bacb57f3c74fdf9650c81`（保留用户既有 `AGENTS.md` 与 `docs/motion-v2/` 文档）
- **核心变更文件**：
  - 基础设施：`MotionTokens.swift`、`MotionCoordinator.swift`、`StageLayoutEngine.swift`、`GlassInteractionCoordinator.swift`
  - 设计系统与玻璃：`GlassButton.swift`、`GlassSurface.swift`、`GlassMiniPlayer.swift`、`AuroraGlassFogView.swift`、`LiquidGlassControl.swift`、`PlayerLayerComposer.swift`、`MiniPlayerLayerComposer.swift`、`GlassPopoverMenu.swift`、`GlassTooltipManager.swift`
  - 舞台与业务视图：`UnifiedStageController.swift`、`PlayerWindowController.swift`、`PlayerView.swift`、`MiniPlayerView.swift`、`LyricsModuleView.swift`、`LyricsView.swift`、`LibraryWindowController.swift`、`LibraryContentView.swift`、`LibrarySidebarView.swift`、`LibraryTopBarView.swift`、`AppLifecycleCoordinator.swift`
  - V03 删除的被替代冗余旧路径：`LaunchSplashWindow.swift`、`GlassSearchField.swift`、`GlassToolbar.swift`、`LiquidGlassOverlay.swift`、`SearchBarView.swift`、`LibraryWindow.swift`、`LyricsWindow.swift`
  - 新增测试套件：`MotionInfrastructureTests.swift`、`MotionStageTests.swift`、`MotionInteractionAndContentTests.swift`、`MotionPerformanceBenchmarkTests.swift`
- **V01 独立审查 (`research` subagent `78c6748b-5080-45aa-85cb-f1a6372bda58`) 修复摘要**：
  - **P1-1**：分离 `activeDragModule` 与 `activeSnapModule`，任意舞台过渡启动先调 `cancelAllStageAnimations()`，杜绝磁吸回弹与 M02/M13/M14 竞态。
  - **P1-2**：`PlayerWindowController.applyMorphFrame` 改由 `slotFrame.height` 连续反推 alpha；`UnifiedStageController.currentPresentationLayout` 在静止态读取视图当前真实 frame 而非提前翻转的 `isMiniMode`/`isMiniLyricsMode`；M13/M14 `hide->show` 反向从实时 `liveRevealProgress` 与未遮罩源框恢复；补齐 Frame 0 同步计算与跨过渡遮罩清理。
  - **P1-3**：重构 `MiniHoverControlsContainer` 与 `PlayerHoverControlsContainer` 的 `hitTest` 仅命中可见交互子控件，并将 `timeView` 置顶，悬停时时间点击与窗口空白区域操作正常透传。
  - **P1-4**：`GlassButton.layout()` 在临时清零 `transform` 下更新 `imageView.frame` 并保留 `scaleTransform` + 1pt 下沉，`alphaValue` 与 `symbolOpacity` 全部接入票据且监听无障碍/渲染模式切换刷新 `toolTip`。
  - **P1-5**：`GlassPopoverMenu` 改用 `PopoverMenuPanel`（`canBecomeKey = true`）并增加锚点点击时间戳防护，避免点击原按钮收起菜单后在 `mouseUp` 立即重载。
  - **P1-6 / P1-7**：`PlayerLayerComposer` / `MiniPlayerLayerComposer` 仅在目标焦点变化或无活跃焦点动画时重设透明度；M08 扫光拆分为 `sweep-0`/`sweep-1` 轮换通道避免双层相互取消。
  - **P1-8 & P2/V03**：补齐 `PlayerView`/`MiniPlayerView` Tab/方向键键盘激活与 `didResignKey` 释放；URL 封面加载期间保留旧图实现真交叉淡化；歌词滚动先执行 `documentView.layoutSubtreeIfNeeded()`；音乐库详情加载加 `detailGeneration` 隔离；侧栏跑马灯从 16ms `Task.sleep` 迁移至 `displayDriver`；`CarouselHaloTextView` 与 `SidebarCategoryItemView` 使用 `isHiddenOrHasHiddenAncestor` 确保父容器隐藏零残留时钟。
  - **玻璃条核心卷轴 & 启动分阶段编排补充**：
    - `GlassSurface.swift` 新增 `ScrollCapOverlayView` 与 `applyScrollPresentation`/`clearScrollPresentation`，在 Enhanced 模式使用双 `NSGlassEffectView` 移动玻璃条、在 Original/降低透明度模式复用缓存 9-slice 晶格切片并严格裁切中间深色主体，实现玻璃条本体物理分离与合拢。
    - `PlayerView.swift` 升级 `playScrollIntro`（双条居中出现后上下如卷轴展开中间 UI）与 `playScrollCollapse`（收起反向折叠为双条后淡出），`PlayerWindowController` 转发最小化与退出收起回调。
    - `UnifiedStageController.swift` 调整 `playerSlotView` 置于 `lyricsView` 与 `libraryCtrl.moduleView` 之上，在 `playLaunchIntroIfNeeded` 实现两阶段启动：**主面板完全展开后**，歌词面板双条从主面板下边缘自上而下移出再下展下玻璃条；歌曲库面板双条从主面板后方由左向右滑入再下展下玻璃条；手动显隐、最小化与退出收起采用严格镜像反向；新增 `testChoreographedLaunchSequenceAndMainCollapse` 回归校验。
- **构建、测试与实机验证记录**：
  - `swift test`（Debug 全量）：**97 项全部通过（0 失败）**—— `UnitTests` 45/45、`PlaybackTests` 6/6、`DomainTests` 3/3、`DesignSystemTests` 43/43（6 个 Suite，含 7 项 V01 回归 + 1 项双阶段启动编排回归）。
  - `swift test -c release --filter MotionPerformanceBenchmarkTests`（Release 100轮模式/模块/hover压测）：**通过**—— `[V02_BENCHMARK] samples=800 activeSamples=600 displayHz=60 P50=0.162ms ActiveP95=0.487ms AllP95=9.900ms P99=12.119ms`，结束后 `activeSubscriberCount == 0`。
  - `bash scripts/build.sh --release --no-open`：成功（26.51s，产物 `build/AirMuse.app`）；Enhanced/Original 双模式实机启动完成态截图 `scratch/choreography_enhanced.png`、`scratch/choreography_original.png` 已校验。
  - 实机冷启动日志（Enhanced）：`[启动计时 +564ms] 主界面已可交互`；进程资源（`ps`）：Enhanced 主进程 `RSS=102,448 KB / 2.2% CPU`（WebKit GPU/WebContent/Networking 分别为 `14,000 / 156,016 / 16,592 KB`）；Original 主进程 `RSS=80,672 KB / 0.6% CPU`。
- **截图证据路径**：
  - 基线截图：`scratch/baseline_macos.png`
  - Motion V2 双模式终验截图：`scratch/final_enhanced.png`、`scratch/final_original.png`

## 当前验证账本
| 验证项 | 当前结果 |
|---|---|
| Windows 原版运行录像 (B01) | BLOCKED（无 `wine`/Windows 运行环境；已完成 C++ 静态审计） |
| Windows Remastered 运行录像 (B01) | BLOCKED（无 `wine`/Windows 运行环境；已完成逆向与 Remastered 源码审计） |
| Mac 当前版本构建与静态截图 | TESTED（Release `AirMuse.app` 构建成功，Enhanced/Original 双模式实机截图通过） |
| Liquid Glass SDK 实验 (B02) | TESTED（MacOSX27.2 `NSGlassEffectView`、`NSGlassEffectContainerView`、`CADisplayLink`、`NSAccessibility` 验证通过） |
| 自动化测试 (`swift test`) | TESTED（96/96 通过，0 失败，含中断/反向/命中/辅助功能/生命周期回归） |
| Release 性能基准 (`V02_BENCHMARK`) | TESTED（`P50=0.146ms`, `ActiveP95=0.327ms`, `AllP95=8.980ms @ 60Hz`, 0 残留时钟） |
| 真实 Apple Music 登录播放 & 4小时/多屏拔插验收 | PENDING_INTEGRATION（需用户真机登录 Apple Music 与外接显示器人工验收） |
| 独立审查 & 旧路径清理 (V01 / V03) | TESTED（P1-1..P1-8 与 P2 缺陷已修复并复测通过，7 个旧路径文件已清理） |

## 性能记录表
| 场景 | SHA | 设备/Hz | 模式 | 样本数 | P50 | ActiveP95 | AllP95 | P99 | 内存(主进程) | 证据 |
|---|---|---|---|---|---|---|---|---|---|---|
| Release 启动静态基线 | `ad9115fe` | M1 / 60Hz | Enhanced | — | — | — | — | — | 91,872 KB | `baseline_macos.png` |
| Motion V2 100轮压测 | `ad9115fe` | M1 / 60Hz | Release headless | 800 (600 active) | 0.146ms | 0.327ms | 8.980ms | 16.087ms | — | `MotionPerformanceBenchmarkTests` |
| Release 启动对比(终版) | `ad9115fe` | M1 / 60Hz | Enhanced / Original | — | — | — | — | — | 102,448 / 80,672 KB | `final_enhanced.png` / `final_original.png` |

## 阻塞及用户人工验收清单
1. **真实 Apple Music 播放与长时运行 (`V02`)**：启动 `AirMuse_macOS/build/AirMuse.app` 并登录 Apple Music 账号，播放歌曲后连续执行：① 快速双击 Normal/Mini（10次反向）；② 播放中收起/展开音乐库与歌词（验证音频零中断）；③ 拖动进度条松手确认仅一次 seek 且封面/歌词同步过渡；④ 运行 4 小时观察内存无持续增长，并可选用 `Instruments` (`Animation Hitches` / `Time Profiler`) 采样。
2. **多物理屏与系统设置热切换 (`M25`/`M26`)**：拖至副屏或负坐标显示器，热拔插显示器验证全窗口簇自动回屏；在系统设置中实时开启/关闭「减弱动态效果」和「降低透明度」观察即时降级且无残影。
3. **Windows 双版本真机录像 (`B01`)**：如需要像素帧对比 Windows 原版与 Remastered 录像，请在 Windows 宿主机录屏后回填 `MOTION_V2_BASELINE.md`。

## 交接规则
新会话先阅读AGENTS及八份文档、git diff和最近提交。按ROADMAP最早可执行任务继续，不重复已验证工作。发现已完成任务存在缺陷则重新打开并记录。未运行的验证不能标记通过。保留失败结果及修复前后对照，不删除证据。
