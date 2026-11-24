# AirMuse Motion V2 — 实施路线与完成定义

每个任务默认 TODO。先阅读 AGENTS 与全部规范，检查Git及当前构建。Phase 0的真机阻塞不妨碍已具备静态证据的后续任务；P4必须先验证相应公开API。每阶段可构建、可回滚，不擅自推送。

| 阶段 | 依赖 | 任务 | 完成门槛 | 状态 |
|---|---|---|---|---|
| P0 基线取证 | 无 | 三版本静态与可运行录屏、SDK验证、性能基线 | 全部效果建立证据状态；环境阻塞明确 | PARTIAL / BLOCKED（静态+macOS实机+SDK基线完成；Windows实机录屏缺少wine阻塞） |
| P1 基础设施 | P0静态基线 | 统一调度、状态/几何、取消与辅助功能 | 确定性中断测试、model/presentation一致；M26 | TESTED |
| P2 窗口与模块 | P1 | M01 M02 M07 M11 M12 M13 M14 M25 | 快速反向、多屏、命中、音频实例不变 | TESTED |
| P3 高频控件 | P1 | M03 M04 M05 M06 M09 M10 M23 | 鼠标/键盘、真实状态、seek合并 | TESTED |
| P4 Liquid Glass增强 | P2 P3 | M03 M04 M05 M08 M09 M10 M19 M20；SDK实验 | 材质真实、融合或明确降级、双模式 | TESTED |
| P5 内容动效 | P1 P3 | M15 M16 M17 M18 M21 M22 | 乱序结果隔离、滚动、SWR不受影响 | TESTED |
| P6 Mac独有交互 | P2 P3 | M12 M24 M25 M26 | 手势冲突、可配置、触觉与多屏 | TESTED |
| P7 集成与清理 | P2–P6 | M01–M26全量审查、性能及业务功能回归 | 真实录屏、实测、无旧动画路径；未验证项明确 | PENDING_INTEGRATION（自动化+Release构建+双模式静态截图全过；真机4小时播放/外接多屏待人工） |

## 独立任务账本
| ID | 任务 | 验收摘要 | 状态 |
|---|---|---|---|
| B01 | 三版本源码审计及录屏 | 静态源码审计完成；macOS实机截图已采集；Windows运行录屏缺`wine` | BLOCKED |
| B02 | SDK及性能基线 | MacOSX27.2 SDK (`NSGlassEffectView`/`Container`/`CADisplayLink`/无障碍API) 编译与实测完成 | TESTED |
| A01 | Motion协调器及可中断动画 | `MotionCoordinator`/`MotionTicket`/`TransitionKey`/冲突域/确定性时钟通过 (`MotionInfrastructureTests`) | TESTED |
| A02 | Stage geometry与命中 | `StageLayoutEngine` 纯布局、顶中锚点、迟滞磁吸、多屏负坐标与透明命中通过 (`MotionStageTests`) | TESTED |
| A03 | 资源与可访问性 | `MotionDisplayDriver` 零空闲时钟、实时 Reduce Motion/Transparency 响应通过 | TESTED |
| M01 | 启动卷轴 | `PlayerView.playScrollIntro` 非阻塞，首击即取消并清 mask；实机冷启动 `+564ms` 可交互 | TESTED |
| M02 | Normal/Mini 水晶形变 | 连续高度驱动 alpha、Frame 0 零闪烁、10次快速反向、`WebRuntime` 实例零重建 | TESTED |
| M03 | 普通控制区悬停 | `PlayerHoverControlsContainer` 仅子控件命中、隐藏不响应、键盘焦点解锁 | TESTED |
| M04 | Mini 控制区悬停 | 零窗口改尺寸、`timeView` 悬停可点击、Tab/Esc 键盘可访问与失焦清理 | TESTED |
| M05 | 按钮物理反馈 | 弹性按压缩放+1pt下沉、`bounds` 稳定不随缩放漂移、移出释放不误触、键盘一致 | TESTED |
| M06 | 播放暂停图标 | 真实播放状态切换；缓冲不伪装 Playing，icon opacity 对齐目标透明度 | TESTED |
| M07 | 聚焦失焦 | GPU 双层纹理交叉淡化；非动画 `layout()` 不打断进行中焦点渐变，失焦零残留 | TESTED |
| M08 | 光学扫光 | `sweep-0`/`sweep-1` 轮换通道、`180ms` 冷却、上限 2 层，支持主动取消 | TESTED |
| M09 | 进度液态滑块 | 拖拽胶囊预览气泡与液体放大；松手最多触发 1 次 `onSeek`；切歌立即取消 | TESTED |
| M10 | 音量HUD | 0–1 严格夹紧、独立通道 HUD 淡入淡出、无滚动劫持 | TESTED |
| M11 | 窗口拖动 | 交互按钮与滚动区拒绝拖拽窗口，无位置漂移 | TESTED |
| M12 | 模块磁吸 | `activeDragModule` 与 `activeSnapModule` 隔离；迟滞阈值、预览、0重叠、每次吸附单次触觉 | TESTED |
| M13 | 音乐库卷轴 | `hide->show` 断点续接不归零；大列表零重排展开，播放实例不受影响 | TESTED |
| M14 | 歌词模块伸缩 | Mini-Lyrics 40pt 连续伸缩与遮罩清理；隐藏后自动停止占位跑马灯时钟 | TESTED |
| M15 | Mini文字跑马灯 | CoreText CJK/RTL/emoji 测宽、悬停暂停、`isHiddenOrHasHiddenAncestor` 自动停钟 | TESTED |
| M16 | 封面过渡 | 异步解码+URL加载期保留旧封面至新图就绪后再交叉淡化；`trackKey` 防乱序覆盖 | TESTED |
| M17 | 环境光 | 严格限制于内层纹理区（边框零染色）、主线程零解码、带 LRU 缓存 | TESTED |
| M18 | 歌词流动 | 乱序时间戳稳定排序、字体变更先更新栈布局再滚动、手动滚动暂停与恢复 | TESTED |
| M19 | 玻璃菜单融合 | 自定义 `canBecomeKey` `PopoverMenuPanel`、Esc/点击外部/失活关闭、防锚点重复弹出 | TESTED |
| M20 | 提示条 | 400ms 停顿触发、`isHiddenOrHasHiddenAncestor` 二次校验、不抢焦点/不遮挡 | TESTED |
| M21 | 音乐卡片 | 零每卡独立 `NSGlassEffectView`、单 `titleLabel` 约束复用、详情请求 `detailGeneration` 隔离 | TESTED |
| M22 | 搜索栏与分类 | 胶囊切换、侧边栏 `displayDriver` 驱动跑马灯、`category/searchGeneration` 隔离 SWR 不阻塞 | TESTED |
| M23 | 加载缓冲恢复 | `StreamLoadingBarView` 仅真实缓冲/加载驱动，失败或播放立即停钟 | TESTED |
| M24 | 触控板手势 | 区域限制（进度区/音量区）、开关可配置、不劫持列表滚动 | TESTED |
| M25 | 多屏及缩放 | `StageLayoutEngine` 1x/1.5x 与全簇屏幕变化钳位（含负坐标）、RenderCache 失效重建 | TESTED |
| M26 | 辅助功能 | 运行时响应 Reduce Motion（取消装饰）/Reduce Transparency（高对比降级框）& `toolTip` 同步 | TESTED |
| V01 | 独立架构审查 | 独立 `research` subagent 审查识别 P1-1..P1-8 与 P2 缺陷，已全部修复并通过回归测试 | TESTED |
| V02 | 真机验收及性能 | Release 100轮压测+Dual-mode截图+启动指标完成；4h真机播放/外接多屏/Instruments待人工 | PENDING_INTEGRATION |
| V03 | 旧路径清理及交付 | 已删除7个被替代旧视图/窗口文件及残留 16ms Sleep 循环，全量测试通过 | TESTED |

状态语义：TODO未开始；IN_PROGRESS进行中；IMPLEMENTED代码接入；TESTED自动化通过；PENDING_INTEGRATION真实环境待验；VERIFIED真实验收证据齐备；BLOCKED注明原因和恢复步骤。阶段状态不可替代单项状态。共享效果跨阶段完成时记录增量，不重复开发。

## Definition of Done
全部M01–M26有真实接入或明确经验证的降级；正常/mini/歌词/音乐库连续交互，快速反向无跳变或错误命中；Original与Enhanced视觉回归通过；不改变现有业务状态与播放生命周期；系统辅助功能、键盘、多屏测试；空闲无装饰计时器，性能实测及长时间资源记录；独立审查修复P0/P1缺陷；清理替代路径；文档与代码一致。真实Windows/macOS/Apple Music不可测试时只能交付已实现并待集成验证，不得宣布全部VERIFIED。

## Agent执行入口
从B01开始，持续执行所有可执行任务，而不是只写计划。每个任务先写失败测试或可复现验收，实施、构建、测试、检查diff、更新账本和PROGRESS。遇到需要真实账户或硬件时记录人工操作步骤，继续独立任务。最终交付三版本录屏比较、实现路径、测试日志、性能对比、缺陷修复与待验清单。
