# AirMuse Motion V2 — 源码基线与取证

基准提交：`ad9115fe318d3f1da97bacb57f3c74fdf9650c81`（上次审计 main）。实施前重新获取 HEAD，记录差异。以下为静态源码与仓库逆向文档，不是实机录像或性能实测。

## 原版证据
- `airplay/docs/REVERSE_ENGINEERING_REPORT.md`：Zion Win32 分层透明窗口、ARGB 皮肤、WINDOWGLASS/WINDOWGLASSFOCUS、菜单和提示条资源。
- `airplay/docs/MINI_MODE_SPECIFICATION.md`：标准 40px、紧凑 30px、上下各20px玻璃条咬合、左右5px边框；按钮 Alpha 180/255/230，按下偏移1px；文字八向1px光晕，50ms跑马灯、约20px/s、间距30px；时间切换、空白区拖动、15px任务栏吸附。
- `airplay/src/AirPlayMainWindow.cpp` 与 `AirPlayMiniPlayer.cpp` 为重建源码，不能直接当作原二进制行为证明。原版完整展开曲线、全量菜单行为、频谱驱动仍需验证。

## Windows Remastered 证据
路径前缀 `AirMuse_Remastered/src/ui/`。
| 文件/符号 | 已观察的实现 | 待验证 |
|---|---|---|
| MainWindow.cpp:79,162,210,279,294 | StartIntroSequence、ToggleMiniMode、StepMotion、TriggerSweep、Render；30 DIP目标高度、弹簧、最多2条扫光、控制区交叉淡入 | 实际关键帧/反向切换 |
| MainWindow.cpp:314,441–582 | Mini文字滑动、按钮高亮、胶囊进度、平台图标 | 按压手感、命中 |
| MotionCoordinator.cpp | 16ms SetTimer，有活动时运行，结束停表；非真实VSync | 最后一帧提交、掉帧 |
| LibraryWindow.cpp:64,127,198 | 展开/收起、焦点与卷轴绘制 | 展开方向与内容裁切 |
| LyricsWindow.cpp:73,164,355 | Mini切换、歌词滑动 | Seek及手动滚动 |
| DockManager.cpp:22,70,99,116 | 方向选择、24 DIP换算阈值、模块同步 | 多屏和吸附解除 |

## 当前 macOS 证据
路径前缀 `AirMuse_macOS/Sources/`。
| 文件 | 观察 | 缺口 |
|---|---|---|
| DesignSystem/MotionTokens.swift | 280/160/120/220/520/320/850ms；弹簧及400速度阈值 | token存在不等于接入 |
| DesignSystem/MotionCoordinator.swift | CASpringAnimation、NSAnimationContext、Reduce Motion；fillMode forwards与不移除 | model/presentation一致性、统一取消 |
| UI/Player/PlayerWindowController.swift:172 | isMiniMode.toggle、直接切isHidden | 连续形变 |
| UI/Dock/UnifiedStageController.swift:335,480,533 | 单宿主、吸附几何、直接setFrame animate:false | 过渡几何/命中、反向动画 |
| UI/Player/PlayerView.swift:14,191,627,677 | 进度/音量、加载动画、扫光触发、hover渐变 | 统一调度、真实材质形变 |
| UI/Player/MiniPlayerView.swift:81,313 | 文字切换、hover交叉渐变 | 隐藏时停表、反向连续性 |
| DesignSystem/GlassButton.swift:245–354 | hover/press、透明度、图层、局部玻璃 | 统一物理按压与键盘 |
| Rendering/GlassEnhancement/LiquidGlassControl.swift | NSGlassEffectView .clear、alpha显隐 | 容器融合与生命周期 |
| UI/Lyrics/LyricsModuleView.swift:187 | 直接切换mini模式 | 连续形变 |
| UI/Library/LibraryContentView.swift | 卡片hover、原生滚动、固定玻璃头 | 选中/加载/分类过渡 |
| Package.swift | macOS 26、Swift 6；审计时出现硬编码MacOSX27.2 SDK路径 | 实际本地SDK及构建 |

## Phase 0 取证操作
1. 记录 `git rev-parse HEAD`、`git status --short`、`swift --version`、`xcrun --show-sdk-path`、OS、机器、刷新率、UI scale、渲染模式。
2. 构建并运行 Windows 原版、Remastered、Mac；若没有 Windows 环境或可运行二进制，记录阻塞，不编造。逐项按 INTERACTION_SPEC ID 录制 60fps 或更高视频，记录输入时刻、首帧、稳定帧、锚点、状态、关键帧、异常。
3. 比较浅色/深色/复杂壁纸、正常/减少动态效果/减少透明度、Mini/Normal、窗口拖动及播放状态。采集 PERFORMANCE 基线。
4. 将证据链接、命令、结论写入 PROGRESS。原版逆向报告与重建代码冲突时保留差异，以实际二进制行为为准；无法验证不阻塞独立实现。
