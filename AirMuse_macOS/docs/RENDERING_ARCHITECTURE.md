# AirMuse macOS 渲染架构设计 (RENDERING_ARCHITECTURE)

## 1. 设计目标与原则

本渲染架构旨在彻底移除原先基于整面 `NSVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)` 的全窗口磨砂替代方案，恢复 **AIRPLAY-zion** 原生 32-bit ARGB 分层水晶玻璃架构，同时为 macOS 26+ 提供局部、克制的 `NSGlassEffectView` 增强层。

核心职责分离：
- **原始皮肤资源层 (`OriginalSkin`)**：资源加载、1×/4× 分辨率切换、精灵图集裁剪、九宫格玻璃外框、像素字体与 8 向紧凑光晕。
- **局部液态玻璃增强层 (`GlassEnhancement`)**：仅在 `Enhanced` 模式下激活的 `NSGlassEffectView` / `NSGlassEffectContainerView` 局部胶囊、滑块与浮层。
- **合成与缓存层 (`Composition`)**：静态外框 `CGImage` LRU 缓存 (`RenderCache`) 与 Core Animation 图层树 (`PlayerLayerComposer` / `MiniPlayerLayerComposer`)。
- **设计令牌层 (`DesignSystem`)**：`OriginalDesignTokens`、`MotionTokens`、`ControlStates`。

---

## 2. 模块目录结构

```text
Sources/DesignSystem/
├── Resources/Skin/
│   ├── 1x/                      # 解包自 AIRPLAY-zion_unpacked.exe 的原始 PNG
│   └── 4x/                      # AirMuse_Remastered 4× 超采样高清 PNG
├── Rendering/
│   ├── OriginalSkin/
│   │   ├── SkinAssetLoader.swift
│   │   ├── SkinAtlas.swift
│   │   ├── NineSliceRenderer.swift
│   │   ├── OriginalGlassRenderer.swift
│   │   ├── OriginalControlRenderer.swift
│   │   └── PixelFontRenderer.swift
│   ├── GlassEnhancement/
│   │   ├── LiquidGlassControl.swift
│   │   ├── LiquidGlassOverlay.swift
│   │   └── GlassInteractionCoordinator.swift
│   └── Composition/
│       ├── RenderCache.swift
│       ├── PlayerLayerComposer.swift
│       └── MiniPlayerLayerComposer.swift
├── OriginalDesignTokens.swift
├── MotionTokens.swift
├── ControlStates.swift
├── GlassSurface.swift           # 基于 PlayerLayerComposer 的原版玻璃宿主视图
├── GlassMiniPlayer.swift        # 基于 MiniPlayerLayerComposer 的迷你条视图
├── GlassPanel.swift             # 5px 侧边 + 20px 上下玻璃条内嵌容器
└── GlassButton.swift            # 精灵图集按钮 + ControlState 物理 + 局部玻璃悬停
```

---

## 3. 分层合成管线

### 3.1 主播放器 (`PlayerLayerComposer`)
1. **`backgroundLayer`**：由 `RenderCache` 缓存的静态水晶玻璃壳（含 `rgb(58)→rgb(31)` 主体渐变、15% 专辑封面微漫反射、9-slice `WINDOWGLASS`/`WINDOWGLASSFOCUS` 外框、`1px` 物理卡槽接缝）。仅在尺寸、缩放、焦点或曲目封面变化时重绘，静态零 CPU 消耗。
2. **`sweepLayer`**：严格裁剪于中间内容区 `(5, 20, W-10, H-40)` 的 Core Animation 高斯镜面扫光层，由鼠标中线跨越与玻璃边界碰撞触发，完全由 GPU 合成。
3. **交互控件层**：`PlayerView` 承载 `MAINCONTROL`、`WINDOWBUTTON`、`TIMEFONT`、`CapsuleProgressView` 与 `VolumeSegmentsView`。

### 3.2 迷你模式 (`MiniPlayerLayerComposer`)
- 当 `H <= 40 * uiScale` 时，`OriginalGlassRenderer` 自动进入迷你玻璃条模式：**不绘制任何不透明深色矩形**，由 `WINDOWGLASS` 上下 20px 玻璃条直接咬合，保留原版通透水晶棒质感。

---

## 4. DPI 与缩放支持

- `SkinResolutionMode.original1x`：直接采样 `1x/` 原始位图，配合 `.none` 最近邻插值，实现 1:1 像素锐利复刻。
- `SkinResolutionMode.retina4x`：采样 `4x/` 高清资源，配合 `.high` 高质量插值，适配 macOS Retina Display (`backingScaleFactor = 2.0`)。
- `uiScale`：支持 `1.0×` (`330×106` / `330×40`) 与 `1.5×` (`495×159` / `495×60`) 全局等比缩放，所有按钮、边框、字号与吸附阈值均等比联动。
