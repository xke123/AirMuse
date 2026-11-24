# AirMuse Motion V2 — 目标架构与状态契约

## 原则
不改变 现有业务所有权；Presentation 仅接收真实状态、发出用户意图。原始皮肤渲染与光学增强独立。保持 UnifiedStageController 单一透明宿主、播放器/歌词/音乐库模块及现有 WebKit 引擎，不因布局切换重新挂载音频引擎。

```text
Business state snapshot / Pointer / Keyboard / Gesture
                  ↓
         Interaction reducer (MainActor)
                  ↓
        MotionCoordinator / transition registry
          ↙           ↓              ↘
 Stage geometry    Control motion    Content/optics
          ↘           ↓              ↙
     AppKit / Core Animation / native glass
        OriginalSkin + optional enhancement
```

## 模块职责
| 模块 | 责任 |
|---|---|
| MotionTokens | 时长、弹簧、速度、阈值与可访问性策略，避免散落常量 |
| MotionCoordinator | MainActor过渡所有者、冲突域、generation、取消、完成提交 |
| StageLayoutEngine | 纯函数：由可用屏幕、锚点、模式、可见模块求目标几何 |
| StageTransition | 在当前呈现几何与目标几何之间插值，统一宿主frame与子模块frame、裁切和命中 |
| InteractionState | hover/press/drag/focus/disabled，事件优先级及键盘等价入口 |
| OpticalEffects | 有界扫光、玻璃增强、环境光；隐藏即停止 |
| MotionAccessibility | 监听系统偏好，原子结束不再适用的过渡 |
| ContentTransition | 歌词、封面、搜索、列表，绑定稳定内容ID与当前业务 operation |

## 状态及调度
```swift
// 契约示意，按真实源码类型调整
struct TransitionKey: Hashable { let owner: String; let channel: String }
struct MotionTicket: Equatable { let key: TransitionKey; let generation: UInt64 }
// MainActor: transition registry owns active tickets and cancellation handles
```
同一冲突域仅一个当前过渡；不同域可并行（按钮hover与歌词）。拖动优先于自动布局，用户明确模式切换优先于装饰动效，系统辅助功能优先于一切。过渡启动时采样presentation layer或自定义插值当前值，取消旧动画并以新目标重建；可取得速度时继承速度，不能可靠取得时采用无跳变的速度近似。取消后旧completion不得隐藏新视图。对CA先设置正确model值，添加from当前呈现的动画，结束移除动画，不依靠fillMode永久保持视觉。

StageState 分为目标模式、当前呈现几何、最终布局、可见模块与过渡ID。动画中不得根据 isMiniMode 单独推断命中；根据实际可见区域和交互状态计算。宿主可使用包络区域避免频繁窗口resize，但必须限制透明区域命中，避免点击穿透或阻挡桌面；实机验证后选择策略。不得逐帧重建整个view树。锚点建议主播放器上边缘及水平中心，若屏幕边界冲突则以可用区域约束优先，实际对照原版录屏后记录选择。

## 业务边界
播放状态、会话、队列只能由既有业务层更新。视觉状态不推断播放成功；拖动进度仅本地预览，结束由既有PlaybackCoordinator提交，track/session改变立即废弃预览。封面、歌词异步回调验证稳定trackID及operation。动画完成回调不得发网络请求。WebKit实例、会话和队列在模式/模块切换前后保持不变。

## 实现建议
复用现有 DesignSystem/MotionCoordinator、MotionTokens、GlassButton、LiquidGlassControl、AuroraGlassFogView、UnifiedStageController，不机械新建目录。优先CA transform/opacity/mask；复杂stage几何可用单一按需显示同步驱动（核实SDK），无活动时停止。自定义spring使用稳定步长或解析解，避免大dt数值发散；睡眠/恢复重新对齐时钟。MainActor只做短几何更新，图片解码、颜色提取不占主线程。通知、tracking area、timer、动画观察者均由明确owner管理并释放。

## 模式与兼容
Original：经典皮肤、精灵及紧凑光晕，禁止新玻璃材质覆盖外框；可保留非侵入性的连续几何。Enhanced：同一布局/业务状态，局部原生玻璃、光学反馈。系统减少透明度覆盖两种模式的材质偏好；减少动态效果保留功能并简化过渡。不得使用私有API。具体SDK检查见 LIQUID_GLASS_SPEC。
