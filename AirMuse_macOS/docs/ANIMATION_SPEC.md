# AirMuse macOS 动画与交互规范 (ANIMATION_SPEC)

## 1. 动画设计原则

所有动效均以 **AIRPLAY-zion** 与 **AirMuse_Remastered** 为行为基线，使用 Core Animation / `NSAnimationContext` 合成，并严格遵守：
- 静态状态下零持续重绘（仅在跑马灯滚动、扫光或窗口形变时激活渲染）。
- 所有动画均检测 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`，开启 Reduce Motion 时自动降级为 `0.01s` 即时切换并关闭跑马灯与扫光。
- 动画中断安全：支持快速连续双击防抖与逆向切换，不产生状态错乱或尺寸跳变。

---

## 2. 时序与物理参数 (`MotionTokens`)

| 动画名称 | 时长 / 弹簧参数 | 触发条件 | 视觉行为 |
| :--- | :--- | :--- | :--- |
| **双击收缩/展开 (`miniToggle`)** | `0.28s` (`easeInEaseOut`) | 双击空白区域 / 点击迷你切换按钮 / `⌘M` | 锚定窗口顶部 (`maxY` 不变)，主播放器 `106×uiScale` 与迷你条 `40×uiScale` 之间平滑过渡并交叉淡入淡出内容；`0.18s` 双击防抖 |
| **控制区悬停渐变 (`hoverFade`)** | `0.16s` | 鼠标移入/移出主播放器或迷你条 | 主播放器：曲目信息 (`idleContainer`) 与 `MAINCONTROL` 按钮组 (`controlsContainer`) 交叉淡入淡出；迷你条：跑马灯/时间与 `MINICONTROL` 按钮组交叉切换 |
| **按钮状态反馈 (`buttonState`)** | `0.12s` | 悬停 / 按下 / 释放 | `Normal` `alpha=0.70` → `Hover` `alpha=1.00` + 加法提亮 → `Pressed` `alpha=0.90` + 垂直下移 `1pt` |
| **玻璃镜面扫光 (`specularSweep`)** | `0.52s` (`CALayer` 位移+透明度关键帧) | 鼠标低速 (`<= 400 DIP/s`) 跨越中线，或碰触上下 `20px` 玻璃边界 | 仅在中间内容区裁剪域内渲染青白高斯光晕，自边界/中线扫过面板，GPU 合成，不重绘背景缓存 |
| **迷你模式跑马灯 (`marqueeTick`)** | `50ms` 定时器 (`1px/tick`) | 迷你模式非悬停且标题宽度超过可视区 | 向左平滑滚动，滚出后留 `30px` 间隙循环；窗口隐藏时自动停止定时器 |
| **歌词窗迷你折叠** | `0.28s` | 点击歌词窗顶部迷你切换按钮 | 顶部 `maxY` 锚定，在 `240×uiScale` 与 `40×uiScale` 之间切换 |
| **窗口磁吸同步 (`DockManager`)** | 即时同步 | 拖动主窗口、子窗口或切换迷你模式 | `16px * uiScale` 吸附阈值内自动咬合对齐 |
