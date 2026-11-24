# AirMuse Motion V2 — Agent 工程规范

## 1. 当前唯一任务

当前唯一活动工程为 `AirMuse_macOS` 的 Motion V2：实现 M01–M26 全量交互动画，建立统一、可中断、可反向、可取消的原生动效系统。目标是经典 AirPlay 水晶外观、Windows Remastered 动效精华与 macOS Liquid Glass 的动态物理质感相结合，同时保持轻量、快速、稳定。

Windows 原版、逆向重建及 Remastered 仅作只读参考。保留现有布局、原始皮肤与精灵、Normal/Mini、歌词、音乐库、Original/Enhanced 模式及 UnifiedStageController 单宿主架构。不得顺带重构业务、增加音乐平台或重新设计产品视觉。

## 2. 每次会话执行流程

1. 阅读本文件以及 `AirMuse_macOS/docs/motion-v2/` 下八份规范：BASELINE、COMPARISON、ARCHITECTURE、INTERACTION_SPEC、LIQUID_GLASS_SPEC、PERFORMANCE、ROADMAP、PROGRESS（文件名均带 `MOTION_V2_` 前缀）。以当前源码和可复核证据为准。
2. 检查 Git 分支、HEAD、工作区、Package.swift、当前调用链、已有测试及 SDK 可用性；保护用户未提交的修改。
3. 根据 Motion V2 ROADMAP 的依赖关系选择最早可执行任务，实际编码、构建、测试、审查差异；不得只输出计划、Token、空接口或演示代码。
4. 每项效果按 INTERACTION_SPEC 实现触发、状态、关键帧、持续时间、中断、反向、取消、降级、命中及验收，确保真正接入生产路径。
5. 更新 ROADMAP 与 PROGRESS，记录任务 ID、变更文件、命令、结果、证据、阻塞及下一任务；架构变更同步更新相关规范。
6. 每阶段保持可构建、可回滚；用户授权时建立本地提交。不得擅自推送远程、覆盖无关工作或降低验收门槛。持续推进独立可执行任务，真机、账户或 SDK 阻塞只影响相关验证。

## 3. 视觉与材质不变量

- 原版水晶外框、玻璃切片、透明通道、锐利文字光晕及经典布局是产品识别基础；保留原始资源与几何规格。不得把整个播放器变成通用磨砂面板。
- Original 模式不引入增强材质；Enhanced 模式以局部真实 Liquid Glass 增强控件及光学反馈，不破坏原始外框。两种模式均需验证。
- 优先使用 AppKit、Core Animation、公开 SDK 的 NSGlassEffectView 及适用玻璃容器。局部 NSHostingView/SwiftUI 仅在原生 API 实验确认有实际收益时使用，不重写整套 UI。
- 玻璃融合、动态折射及形变必须通过本机 SDK 与实机验证；透明度变化、渐变或模糊降级不能宣称为原生玻璃融合。禁止私有 API。
- 动画参数由 MotionTokens 统一管理，按行为选择曲线；规格参数为初始调校目标，实机调整需记录原因。避免夸张缩放、持续闪烁、叠加多重扫光及遮挡文字。

## 4. 动画架构与交互不变量

- UI 交互状态与业务状态分离。Stage geometry、交互状态及动画目标各有明确所有者；避免多个 Controller 分别修改同一窗口 Frame 或图层属性。
- 最新用户意图优先：动画未结束即可反向、打断或取消，从当前 presentation geometry/可见状态重新定向；旧 completion 不得覆盖新目标。用 transition ID 或等价机制隔离过期回调。
- model layer、presentation layer、窗口几何、鼠标命中与可访问性状态在完成或取消后一致；隐藏控件不拦截点击。不得靠 fillMode 持久保留错误 model 状态。
- Normal/Mini 连续形变保持窗口锚点及播放器实例；歌词、音乐库展开收起与舞台几何联动。拖动直接跟手，吸附使用迟滞、屏幕边界约束及有界归位。
- Hover、Press、Release、Drag、Focus 及键盘操作具有明确状态转换；处理鼠标移出后释放、快速进入退出、窗口失焦和动画中再次点击。
- 进度条拖动预览属于 UI；最终 Seek 走既有用户意图接口，避免逐帧 WebKit 调用。播放暂停图标、缓冲与恢复动画以真实业务事件驱动。
- 手势限制作用区域、允许配置、避免抢占滚动和系统手势；触觉反馈仅在设备支持且实际发生对齐时触发。
- 系统 Reduce Motion、Reduce Transparency 及键盘可访问性必须适配，并响应运行期间设置变化。

## 5. 业务集成边界

- 动画与渲染层只订阅真实业务状态并发送用户意图，不改变业务语义、服务生命周期及状态所有权，不建立重复的播放、账户、队列或缓存状态源。
- 视觉过渡不得产生非必要网络请求、播放指令、WebKit 重建或音频重载；模式切换、模块显隐、缩放及拖动不得中断播放。
- 播放、缓冲、恢复、封面和歌词动画以有效业务事件及当前内容身份为依据，不伪造成功状态；启动动画不得阻塞首屏交互。
- 必要的接口接线须有明确理由及回归测试，不扩大任务范围。

## 6. 性能与实现约束

- Swift 6 严格并发；AppKit UI 由 MainActor 管理。避免同步磁盘 I/O、图片解码和昂贵色彩提取阻塞主线程。不为消除编译错误滥用 unchecked Sendable、unsafe 或 detached。
- 优先系统合成与局部图层更新，复用原始皮肤缓存和玻璃实例；禁止每帧整窗重绘、无界图层/定时器、重复监听器或持续装饰性动画。
- 动画停止、窗口隐藏、模式切换及销毁时释放不必要的动画、观察者和任务；不可见组件不持续刷新。必要自定义帧驱动在无活动动画时停止。
- 以 PERFORMANCE 为预算与测量协议：60Hz/120Hz 分别为 16.67/8.33ms 整帧预算，反馈争取一帧内，空闲装饰动画时钟为零。指标为目标，不是实测结果；按设备刷新率和实际 trace 评估。
- 不引入 Electron、Chromium、新运行时或不必要第三方依赖。避免纯为目录结构而过度抽象。

## 7. 验收、证据与完成定义

- 每项 M01–M26 必须有实际调用链、可执行测试及 Original/Enhanced 双模式验证；覆盖中断、反向、乱序 completion、快速操作、隐藏命中、多屏、辅助功能和资源释放。
- 使用可控时钟及确定性事件序列，避免只靠 sleep 或人工观感测试。不得删除有效测试、弱化断言、关闭严格并发或用 TODO/空实现/虚假成功冒充完成。
- Phase 0 区分原版逆向资料、复刻源码、macOS 源码及真实录屏证据。未运行过的行为不得写成实测事实。性能以 Instruments、signpost 和实际记录为准，区分 App 与 WebKit 子进程。
- 状态采用 TODO、IN_PROGRESS、IMPLEMENTED、TESTED、PENDING_INTEGRATION、VERIFIED、BLOCKED，遵守 ROADMAP 的定义。无法完成的真实设备、录屏、SDK 或 Apple Music 回归验证明确记录，不得宣称 VERIFIED。
- 最终通过独立审查，核对 26 项实际生产路径、视觉一致性、可中断动画、业务功能回归、性能和资源生命周期，删除已被替代的重复动画路径。
- 最终报告包括实现清单、证据、实测指标、降级行为、未验证项及人工验收步骤。只在满足 Motion V2 DoD 后宣布完成。
