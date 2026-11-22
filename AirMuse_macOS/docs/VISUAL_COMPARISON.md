# 视觉对比与回归验证报告 (VISUAL_COMPARISON)

> 本报告记录 **AirMuse macOS** 重构后的原版 AIRPLAY 水晶玻璃渲染结果与原版资源组合基线之间的定量及人工视觉对比。
>
> **证据边界说明**：受限于当前 macOS 运行环境，无法直接运行 Windows 原生程序 `AIRPLAY-zion.exe`。基线图 (`Tests/VisualRegression/Baselines/`) 为依据 `AIRPLAY-zion_unpacked.exe` 解密 32-bit ARGB 位图与反汇编坐标规则组合渲染的 **资源复原基线**，而非原程序实机截图。

---

## 1. 视觉对比资产清单

| 状态 | 基线图 (`Baselines/`) | 当前渲染图 (`Captures/`) | 差异图 (`Diffs/`) |
| :--- | :--- | :--- | :--- |
| **主播放器失焦 (1× `330×106`)** | `baseline_reconstructed_main_unfocused_1x.png` | `capture_main_unfocused_1x.png` | `diff_main_unfocused_1x.png` |
| **主播放器聚焦 (1× `330×106`)** | `baseline_reconstructed_main_focused_1x.png` | `capture_main_focused_1x.png` | `diff_main_focused_1x.png` |
| **迷你播放器 (1× `330×40`)** | `baseline_reconstructed_mini_40px_1x.png` | `capture_mini_40px_1x.png` | `diff_mini_40px_1x.png` |
| **主播放器聚焦 (1.5× Retina `495×159`)** | — | `capture_main_focused_1_5x.png` | — |
| **迷你播放器 (1.5× Retina `495×60`)** | — | `capture_mini_60px_1_5x.png` | — |

---

## 2. 玻璃外框像素与结构对比结果

通过编译链接 `DesignSystem` 与 `UI` 模块离屏渲染并逐像素比对玻璃外框区域（顶部 `20px`、底部 `20px`、左右 `5px`）：

| 对比项 | 玻璃外框精确匹配率 | 差异原因分析 |
| :--- | :--- | :--- |
| **主播放器失焦 (`1× 330×106`)** | **95.40%** (`13,222 / 13,860 px`) | 剩余 4.6% 差异集中于底部/顶部 `1px` 物理卡槽接缝（新渲染器按 `GlassRenderer.cpp` 额外绘制了接缝亮/暗线，原版资源组合基线未叠加该接缝） |
| **主播放器聚焦 (`1× 330×106`)** | **92.83%** (`12,866 / 13,860 px`) | 基线图在顶部/底部玻璃条上预先叠加了 `WINDOWBUTTON` 精灵按钮，而纯玻璃壳捕获图未叠加按钮，外框与高光曲线本身完全对齐 |
| **迷你播放器 (`1× 330×40`)** | **95.27%** (`12,575 / 13,200 px`) | 基线图叠加了 `MINICONTROL` 与 `TIMEFONT` 示例，其余全部透明通道、行 5/34 高光锐线与圆角裁切完全一致；**无任何深色不透明横条** |

---

## 3. 人工检查清单

1. **玻璃外框连续性**：四角 `15×20` 切片无非等比拉伸，顶部行 5 高光与底部行 34 高光在水平拉伸后连续无接缝。
2. **透明通道**：迷你模式 `40px` / `60px` 中间无 `rgb(23,23,23)` 不透明填充，完全由 `WINDOWGLASS` / `WINDOWGLASSFOCUS` 透明通道决定质感。
3. **焦点切换**：`isFocusedSurface` 切换时可清晰观察到高光对比度提升（`alpha` 从 `147` 提升至 `172`）。
4. **Retina 与 1× 缩放**：`1.5×` Retina (`495×159` / `495×60`) 采用 `4×` 超采样资产无锯齿；`1.0×` 采用 `1×` 原始资产最近邻渲染保持像素锐利。

---

## 4. 性能基准实测 (`verify_airmuse` @ Apple Silicon)

| 指标 | 实测结果 |
| :--- | :--- |
| `1×` 主播放器玻璃壳首次渲染 (`330×106`) | **0.49 ms** (Focused) / **0.42 ms** (Unfocused) |
| `1×` 迷你条首次渲染 (`330×40`) | **0.93 ms** |
| `1.5×` Retina 主播放器首次渲染 (`495×159`) | **1.40 ms** |
| `1.5×` Retina 迷你条首次渲染 (`495×60`) | **0.80 ms** |
| `PlayerLayerComposer` `2×` Retina 缓存未命中 | **2.67 ms** |
| `PlayerLayerComposer` `2×` Retina 缓存命中 (`RenderCache`) | **0.0039 ms** (~685× 加速，静态零重绘) |
