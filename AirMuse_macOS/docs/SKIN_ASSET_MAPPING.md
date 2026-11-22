# 原始皮肤资源映射表 (SKIN_ASSET_MAPPING)

> 记录 `airplay/resources/bitmaps/`（1× 原版解码 PNG）与 `AirMuse_Remastered/assets/`（4× 高清重采样 PNG）中所有关键视觉资源的尺寸、图集区域、使用位置、渲染方式及 macOS 对应组件。

| 资源名称 | 1× 原版尺寸 | 4× 高清尺寸 | 图集切分 / 区域 | 使用位置 | 渲染方式 | macOS 对应组件 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `WINDOWGLASS.png` | `30 × 40` | `120 × 160` | 9-Slice：四角 `15×20` (4×: `60×80`)；水平中段 `x=14..16`；垂直侧边 `w=5` (4×: `20`), `y=19..21` | 主播放器、迷你播放器、歌词窗口、资料库窗口 **失焦状态** 玻璃外框 | `NineSliceRenderer` 分段绘制（禁止整张拉伸） | `OriginalGlassRenderer` / `OriginalGlassSurface` |
| `WINDOWGLASSFOCUS.png` | `30 × 40` | `120 × 160` | 同 `WINDOWGLASS`（行 5/34 高光与中心对比度增强） | 所有窗口 **激活聚焦状态** 玻璃外框 | `NineSliceRenderer` + `focusRatio` 跨淡插值 | `OriginalGlassRenderer` / `OriginalGlassSurface` |
| `MAINCONTROL.png` | `192 × 32` | `768 × 128` | `6 × 1` 网格，每格 `32×32` (4×: `128×128`)：<br>0=Stop, 1=Prev, 2=Play, 3=Pause, 4=Next, 5=Eject | 主播放器中间控制区 5 枚核心播放按钮 | `SkinAtlas` 裁剪 + `OriginalControlRenderer` (`Normal 0.75 / Hover 1.0+18%亮 / Pressed 0.90+1pt下移`) | `OriginalSpriteButton` (于 `PlayerView`) |
| `MINICONTROL.png` | `96 × 16` | `384 × 64` | `6 × 1` 网格，每格 `16×16` (4×: `64×64`)：<br>0=Stop, 1=Prev, 2=Play, 3=Pause, 4=Next, 5=Eject | 迷你播放器播放控制按钮组 | `SkinAtlas` 裁剪 + `OriginalControlRenderer` | `OriginalSpriteButton` (于 `MiniPlayerView`) |
| `WINDOWBUTTON.png` | `130 × 26` | `520 × 104` | `10 × 2` 网格，每格 `13×13` (4×: `52×52`)：<br>Row0: 0=最小化, 1=最大化/资料库, 2=关闭, 3=展开, 4=收起, 5=未置顶, 6=已置顶, 7=迷你切换, 8=双窗, 9=停靠<br>Row1: 0=光盘, 1=下拉, 3=上, 4=下, 5=列表, 6=歌词音符 | 主/迷你播放器顶部玻璃条、歌词/资料库顶部栏窗口控制按钮 | `SkinAtlas` 裁剪 + `BarSpillFog` 局部暗雾衬底 | `OriginalSpriteButton` (于各窗口顶部/底部玻璃条) |
| `ICONBUTTON.png` | `165 × 45` | `660 × 180` | `11 × 3` 网格，每格 `15×15` (4×: `60×60`)：<br>Row0: 0=随机, 1=顺序, 2=单曲禁止, 3=单曲, 4=循环, 5=静音, 6..10=音量阶梯<br>Row1: 0=播放, 1=列表, 2=信息, 3=收藏星标, 9=搜索, 10=左右翻页<br>Row2: 0=编辑, 1=设备, 2=音频, 3=文档 | 播放模式、搜索、收藏、资料库辅助图标 | `SkinAtlas` 裁剪 + `OriginalControlRenderer` | `OriginalControlRenderer` / `LibraryTopBarView` |
| `TIMEFONT.png` | `90 × 14` | `90 × 14` | `15 × 2` 网格，每格 `6×7`：<br>Row0: `0..9` (0..9), `:` (10), `-` (11), `.` (12)<br>Row1: `+` (0), `-` (1) | 迷你播放器与主播放器数码时间显示 (`MM:SS`) | 最近邻 (`nearest`) 像素字体贴图，步长 `7px` | `PixelFontRenderer` (`TimeFontView`) |
| `MINIFONT.png` | `40 × 5` | `40 × 5` | `10 × 1` 网格，每格 `4×5` (`0..9`) | 极微型数字角标 / 比特率 / 采样率显示 | 最近邻 (`nearest`) 像素字体贴图 | `PixelFontRenderer` |
| `QUADFONT.png` | `130 × 16` | `130 × 16` | `13 × 2` 网格，每格 `10×8` | 采样率/声道/状态信息标签 | 最近邻 (`nearest`) 像素字体贴图 | `PixelFontRenderer` |
| `HINTGLASS.png` | `40 × 40` | `40 × 40` | 9-Slice 玻璃底板（`alpha=[0,138]`） | 浮动提示条 (Tooltip) 与进度拖拽气泡 | 9-Slice 玻璃渲染 | `OriginalGlassRenderer` (Tooltip / Scrub Bubble) |
| `MENUGLASS.png` | `40 × 40` | `40 × 40` | 9-Slice 玻璃底板（`alpha=[0,141]`） | 弹出菜单水晶玻璃底板 | 9-Slice 玻璃渲染（Enhanced 模式可叠加局部 `NSGlassEffectView`） | `OriginalGlassRenderer` / 菜单浮层 |
| `MENUICON.png` | `210 × 14` | `210 × 14` | `15 × 1` 网格，每格 `14×14` (0..10 有效) | 右键菜单与下拉菜单图标 | `SkinAtlas` 裁剪 | 上下文菜单项图标 |
| `PACKHINT.png` | `160 × 40` | `160 × 40` | 状态提示复合图 | 提示徽章 / 编码指示 | `SkinAtlas` 裁剪 | 备用状态指示 |
| `RATING.png` | `30 × 12` | `30 × 12` | 星级评分切片 | 曲目评分指示 | `SkinAtlas` 裁剪 | 备用评分指示 |
