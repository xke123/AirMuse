# 原始 AIRPLAY-zion UI 像素级视觉规范 (ORIGINAL_UI_SPEC)

> 本规范基于对 `AIRPLAY-zion_unpacked.exe` 反汇编报告（`airplay/docs/REVERSE_ENGINEERING_REPORT.md`、`MINI_MODE_SPECIFICATION.md`）、解密原始位图（`airplay/resources/bitmaps/`）及 `AirMuse_Remastered` 复刻源码（`GlassRenderer.cpp`、`MainWindow.cpp`、`LyricsWindow.cpp`、`LibraryWindow.cpp`、`DockManager.cpp`）的联合考古整理。
>
> **证据等级说明**：由于当前运行环境为 macOS，无法直接执行 Windows PE 可执行文件 `AIRPLAY-zion.exe`，所有运行态动态细节均依据反汇编地址、原始 32-bit ARGB 位图像素及 Windows 复刻代码还原；未经原版 EXE 实机运行验证的细节已明确标注。

---

## 1. 主界面几何 (Main Player Geometry)

### 1.1 窗口尺寸与缩放体系
| 模式 | 1× 逻辑尺寸 (DIP) | 1.5× macOS 默认缩放 | 来源 |
| :--- | :--- | :--- | :--- |
| **主播放器 (Normal)** | `330 × 106` | `495 × 159` | `AirMuse_Remastered/src/ui/MainWindow.hpp` (`DEFAULT_WIDTH_DIP = 330`, `DEFAULT_HEIGHT_DIP = 106`)；`DesignTokens.swift` |
| **迷你播放器 (Standard Mini)** | `330 × 40` (原版默认宽 `360`) | `495 × 60` | `MINI_MODE_SPECIFICATION.md` §1.1；`AirPlayTypes.hpp` (`MINI_BAR_HEIGHT = 40`) |
| **迷你播放器 (Compact Mini)** | `330 × 30` | `495 × 45` | `MINI_MODE_SPECIFICATION.md` §1.1；`MainWindow.cpp` (`30.0f`) |
| **歌词窗口 (Lyrics)** | `330 × 240` | `495 × 360` | `LyricsWindow.hpp` (`330 × 240`)；`DesignTokens.swift` |
| **资料库窗口 (Library)** | `360 × 380` | `540 × 570` | `LibraryWindow.hpp` (`360 × 380`)；`DesignTokens.swift` |

### 1.2 窗口各层边界与玻璃边框几何
基于 `WINDOWGLASS.png` (`30×40`) 与 `WINDOWGLASSFOCUS.png` (`30×40`) 的逐像素透明通道分析及 `AirPlayGlassRenderer.cpp`、`GlassRenderer.cpp`：
- **顶部玻璃条 (Top Glass Cap)**：高度 `20 px`（1× 逻辑像素，`WINDOWGLASS` 上半部分 `y = 0..19`；来源：反汇编 `0x0047BB2F`, `sar edi, 1`, `40 / 2 = 20`）。
  - 行 `0..3`：外缘透明抗锯齿与微弱投影 (`alpha = 0..16`)。
  - 行 `4`：外沿过渡 (`alpha = 56` / 聚焦 `70`)。
  - 行 `5`：顶部高光锐线 (`rgb(218,218,218), alpha=113` / 聚焦 `rgb(226,226,226), alpha=136`)。
  - 行 `6..19`：凸面玻璃渐变折射层 (`rgb(182→62), alpha=42→90` / 聚焦 `42→101`)。
- **底部玻璃条 (Bottom Glass Cap)**：高度 `20 px`（`WINDOWGLASS` 下半部分 `y = 20..39`）。
  - 行 `20..33`：对称玻璃渐变过渡 (`rgb(58→161), alpha=92→52`)。
  - 行 `34`：底部高光锐线 (`rgb(176,176,176), alpha=136` / 聚焦 `rgb(179,179,179), alpha=166`)。
  - 行 `35..38`：底部投影 (`alpha = 91→5`)。
- **左右玻璃边框 (Left / Right Glass Border)**：宽度 `5 px`（来源：反汇编 `0x0047DA6A`，返回常量 `5`）。
  - 九宫格四角切片采用 `15 × 20 px`（避免圆角高光端点被拉伸），左右垂直中间边仅采样最外侧 `5 px`（避免内部阴影柱渗入内容区）。
- **物理咬合卡槽接缝 (Groove Seams)**（当内容区高度 `midH > 0` 时）：
  - 顶部接缝 (`y = 20`)：`1px` 深色暗槽 `rgba(12,13,16, 190..225)` + 下方 `1px` 微光亮线 `rgba(255,255,255, 45..80)`。
  - 底部接缝 (`y = H - 20`)：`1px` 深色暗槽 + 下方 `1px` 微光亮线。
- **中间内容区 (Middle Body)**：`x = 5..W-5`, `y = 20..H-20`，尺寸 `320 × 66`（1×）。
  - 主播放器垂直渐变底色：`rgb(58,58,58)` → `rgb(31,31,31)`（来源：`GlassRenderer.cpp` `hasMainGloss`）。
  - 歌词/资料库底色：`rgb(23,23,23)`。
  - 透明圆角半径：`4 px`（原版 `GLASS_CORNER_RADIUS = 4`，紧凑条 `3.2 px`）。

### 1.3 主播放器控件坐标与间距 (1× 逻辑坐标 `330 × 106`)
所有坐标均来自 `MainWindow.cpp::UpdateLayout(330, 106)` 与 `Render()`：
- **主控按钮组 (`MAINCONTROL`, `32 × 32` 每枚, 圆形命中半径 `16 px`)**：
  - 起始 `startX = (330 - 166) / 2 = 82 px`，`y = 26 px`（悬停时显现，非悬停时渐隐显示曲目信息）。
  - `BTN_STOP` (index 0): `(82, 26, 32, 32)`
  - `BTN_PREV` (index 1): `(114, 26, 32, 32)` (间距 `0 px`)
  - `BTN_PLAYPAUSE` (index 2=Play / 3=Pause): `(149, 26, 32, 32)` (间距 `+3 px`)
  - `BTN_NEXT` (index 4): `(184, 26, 32, 32)` (间距 `+3 px`)
  - `BTN_EJECT` (index 5): `(216, 26, 32, 32)` (间距 `0 px`)
- **顶部玻璃条窗口按钮 (`WINDOWBUTTON`, `13 × 13` 每枚)**：
  - `BTN_MINIMIZE` (col 0): `(W - 93, 4, 13, 13)` -> `(237, 4, 13, 13)`
  - `BTN_MINI_TOGGLE` (col 7): `(W - 77, 8, 13, 13)` -> `(253, 8, 13, 13)`
  - `BTN_TOPMOST` (col 5未钉 / col 6已钉): `(W - 61, 4, 13, 13)` -> `(269, 4, 13, 13)`
  - `BTN_CLOSE` (col 2): `(W - 45, 8, 13, 13)` -> `(285, 8, 13, 13)`
- **底部玻璃条扩展按钮**：
  - 左侧来源切换区（Windows 复刻扩展，原版无多平台）：`BTN_SRC_APPLE (32, H-17, 13, 13)`, `BTN_SRC_SPOTIFY (50, H-17, 13, 13)`, `BTN_SRC_QQ (68, H-17, 13, 13)`。
  - 右侧面板开关：`BTN_LIBRARY` (`WINDOWBUTTON` col 1, `(W-63, H-17, 13, 13)` -> `(267, 89, 13, 13)`), `BTN_LYRICS` (`WINDOWBUTTON` row 1 col 6? 音符图标, `(W-45, H-17, 13, 13)` -> `(285, 89, 13, 13)`).
- **进度条与时间显示**：
  - 进度条命中区：`x = 68, y = 64, w = W - 136 (194), h = 14`；视觉胶囊高度 `6 px`（`y = 68`）。
  - 当前时间（左侧）：`Rect(26, 65, 38, 13)` 右对齐（可用 `TIMEFONT` 或清晰等宽数字）。
  - 总时长（右侧）：`Rect(W - 64, 65, 38, 13)` 左对齐。
- **音量区域（右侧 8 段阶梯柱）**：
  - 命中区：`Rect(W - 25, 42, 16, 38)` -> `(305, 42, 16, 38)`。
  - 绘制：8 个 `7 × 2 px` 横条，自下而上 `segY = 74 - seg * 4`。
- **静息态专辑与曲目信息**（非悬停时显示）：
  - 专辑封面：`Rect(14, 25, 34, 34)`，圆角 `5 px`（注：Windows 复刻扩展；原版 AIRPLAY 主界面无内置封面时文本居中）。
  - 标题：`Rect(54, 25, W - 90, 19)`，粗体 `13 px`，`rgb(235,235,235)`。
  - 歌手：`Rect(54, 45, W - 90, 16)`，常规 `11 px`，`rgb(166,166,166)`。
- **透明区域与鼠标命中区域**：
  - 四角外侧像素（行 `0..3`、`36..39`、列 `0..2`、`27..29`）完全透明或为软阴影。
  - 空白玻璃与面板非控件区域均触发窗口拖拽；双击非控件空白区域触发 Normal ↔ Mini 模式切换。

---

## 2. 迷你模式几何 (Mini Mode Geometry)

### 2.1 原版标准迷你模式 vs 紧凑模式
- **原版标准迷你高度**：`40 px`（上 `20 px` 玻璃条 + 下 `20 px` 玻璃条直接咬合，中间内容高度 `0`；`MINI_MODE_SPECIFICATION.md` §1.1）。
- **紧凑迷你高度**：`30 px`（上下玻璃条各截取/缩放至 `15 px`；`MainWindow.cpp`）。
- **默认宽度**：`330 px`（macOS 1.5× 下为 `495 × 60` 或 `495 × 45`）。
- **圆角变化**：正常模式窗口外轮廓圆角 `4 px`；迷你模式收缩时向内收拢至 `3.2 px ~ 4 px`（在展开动画阶段一先凝聚为半径 `10 px` 的 `20×20` 玻璃珠，再横向拉伸并从 `10 → 3.2`）。

### 2.2 控件坐标 (`MINICONTROL` `16 × 16` & `WINDOWBUTTON` `13 × 13`)
- **原版迷你条常驻布局**（`MINI_MODE_SPECIFICATION.md` §2 & `AirPlayMiniPlayer.cpp`）：
  - 左侧按钮（`16×16`，间距 `2px`，左起 `9px`，`y = 2 + (H - 20)/2`）：Prev (1), Play/Pause (2/3), Next (4), Stop (0)。
  - 中间跑马灯标题区：曲目 `歌名 - 歌手`，8 向 `1px` 紧凑黑光晕 `rgba(15,15,15,0.75)` + `rgb(235,235,235)`。
  - 右侧时间区：`TIMEFONT` (`6×7` 每字符，步长 `7px`，`MM:SS` 占 `35px`)，紧邻右侧菜单/最小化/关闭按钮。
- **Windows 复刻悬停切换布局**（`MainWindow.cpp` `h < 50`）：
  - 静息态 (`hoverAlpha = 0`)：居中轮播曲名/歌手/专辑（10s 上下滑动切换，`DrawGlyphHaloText` 紧凑光晕）。
  - 悬停态 (`hoverAlpha = 1`)：居中显示 5 枚 `16×16` 控制按钮 (`startX = (W - 92)/2`, `y = 7`)，右侧显示歌词/展开/关闭 (`13×13`)，左侧显示平台切换。
- **缩放锚点与收起/展开视觉顺序**：
  - 锚点：窗口顶部边缘（macOS 坐标系 `maxY` 固定，`origin.y = maxY - targetHeight`），保证顶部玻璃条位置不动、底部向上收缩。
  - 双击动画顺序：
    - 收起：内容区渐隐 → 高度弹簧收缩 (`106 → 40`) → 上下玻璃条咬合。
    - 展开：高度弹簧展开 (`40 → 106`) → 上下玻璃条分离露出 `midBody` → 控件与进度条渐显。
    - 首次启动卷轴动画（4 阶段）：玻璃珠凝聚 (`0..0.22`) → 横向拉伸 (`0.22..0.52`) → 单条分裂双条 (`0.52..0.70`) → 卷轴上下展开 (`0.70..1.00`)。

---

## 3. 材质分层分析 (Material Layers)

严格禁止合并为单一 `NSVisualEffectView` 全窗口模糊，必须拆分为独立图层：

1. **完全透明区域**：窗口四角外缘像素 (`alpha = 0`)，保持无边框透明轮廓。
2. **阴影层**：`WINDOWGLASS` 自带上下 `3..4px` 软阴影（行 `0..3`、`35..38`）及系统阴影，不额外叠黑。
3. **纹理/贴图层 (Content Body)**：仅在 `H > 40` 时绘制于 `(5, 20, W-10, H-40)`，主播放器使用 `rgb(58,58,58)→rgb(31,31,31)` 渐变，歌词/资料库使用 `rgb(23,23,23)`（可选 15% 专辑封面微漫反射）。
4. **半透明玻璃区域 (`WINDOWGLASS` / `WINDOWGLASSFOCUS`)**：九宫格切片渲染顶部 `20px`、底部 `20px`、左右 `5px` 玻璃外框。
5. **高光边缘与卡槽接缝**：位图自带行 `5` 顶部亮线、行 `34` 底部亮线，以及中间内容区上下边缘的 `1px` 暗槽 + `1px` 亮线。
6. **玻璃折射/扫光层 (`Specular Sweep`)**：仅限中间内容区裁剪域内的横向高斯光晕扫过（外层 `rgba(130,215,255)` + 核心 `rgba(250,252,255)`），由鼠标中线跨越或碰触玻璃边界触发。
7. **控件高亮层**：`BarSpillFog`（玻璃条上的局部暗雾衬底，使白色玻璃条上的图标与文字清晰可读）+ 按钮 `Normal (0.70) / Hover (1.00, 1.18×亮度) / Pressed (0.90, +1px 下移)`。
8. **焦点与悬停状态层**：失焦使用 `WINDOWGLASS`，聚焦平滑过渡至 `WINDOWGLASSFOCUS`（高光更锐、透明对比度更高）。

---

## 4. 原版设计与 Windows 复刻扩展区分

| 元素 | 来源归属 | 说明 |
| :--- | :--- | :--- |
| `WINDOWGLASS` / `WINDOWGLASSFOCUS` 边框、20px 上下条、5px 侧边 | **原版 AIRPLAY** | 反汇编与原始位图直接证实 |
| `MAINCONTROL` / `MINICONTROL` / `WINDOWBUTTON` / `TIMEFONT` 图集 | **原版 AIRPLAY** | 解密位图直接证实 |
| 文字 8 向紧凑黑光晕 (`1px`)、Normal/Hover/Pressed 透明度与 1px 下移 | **原版 AIRPLAY** | 反汇编 `0x0049B180`、`0x004574DA` 证实 |
| 双击切换 Normal/Mini、窗口吸附、玻璃扫光 | **原版 AIRPLAY** | 反汇编 `Shell_TrayWnd`、双击及光学反馈 |
| 330×106 布局中的 34×34 专辑封面、3 平台切换图标、资料库 Web 宿主 | **Windows 复刻扩展** | `AirMuse_Remastered` 为多平台流媒体新增 |
| macOS 局部 `NSGlassEffectView` (macOS 26+) | **macOS Enhanced 增强层** | 仅用于 Enhanced 模式局部交互控件 |
