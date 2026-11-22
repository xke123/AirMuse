# AirMuse macOS 局部 Liquid Glass 增强规范 (LIQUID_GLASS_ENHANCEMENT)

## 1. 核心原则

> **Original 定义身份，Liquid Glass 提升质感。**

- **Original 模式**：100% 纯净的 AIRPLAY-zion 水晶玻璃与位图精灵渲染，禁用所有 `NSGlassEffectView` 增强层。
- **Enhanced 模式**：完整保留原版玻璃外框、布局比例、精灵图标与配色，仅在适合的局部交互控件上叠加 macOS 26+ 原生 `NSGlassEffectView` / `NSGlassEffectContainerView` 光学质感。
- 用户可通过主播放器右键菜单 **视觉渲染模式** 随时切换，状态持久化至 `UserDefaults` (`airmuse.ui.renderMode`)。

---

## 2. 增强组件与作用范围

| 组件 | 原生 API | 作用位置 | 行为约束 |
| :--- | :--- | :--- | :--- |
| **`LiquidGlassControl`** | `NSGlassEffectView(style: .clear)` | 主/迷你播放器 `MAINCONTROL` / `MINICONTROL` 按钮悬停背光 | 仅在 `Hover` / `Pressed` 且处于 `Enhanced` 模式时淡入，形状严格贴合圆形按钮轮廓，不改变原版按钮大小与图标形状 |
| **`CapsuleProgressView`** | `LiquidGlassControl` | 进度条悬停与拖拽高亮 | 在进度条胶囊轮廓内提供微弱折射光感，不将进度条变为大号圆角药丸 |
| **`VolumeSegmentsView`** | `LiquidGlassControl` | 右侧 8 段音量柱悬停区域 | 悬停时提供局部玻璃背板，保留原版 8 段阶梯柱状视觉 |
| **`LibraryTopBarView`** | `LiquidGlassControl` | 资料库顶部导航与搜索栏 (`10pt` 圆角) | 取代原先整条 `NSVisualEffectView(.hudWindow)`，与外层 AIRPLAY 9-slice 玻璃边框和谐共存 |
| **`LiquidGlassOverlay`** | `NSGlassEffectContainerView` | 浮动提示与上下文扩展容器 | 仅供局部浮层/胶囊使用，严禁用于主窗口、歌词窗口或资料库窗口外框 |

---

## 3. 退化与兼容性

- 若控件在某个位置会破坏原版几何轮廓（如 13×13 顶部玻璃条小按钮），保留原始精灵材质与 `ControlState` 物理反馈，不强行包裹 `NSGlassEffectView`。
- 在 macOS 26 以下或 `Original` 模式下，`LiquidGlassControl` 保持透明未激活状态，零额外渲染开销。
