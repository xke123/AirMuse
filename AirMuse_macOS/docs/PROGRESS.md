# AirMuse macOS — 原始 AIRPLAY UI 复刻与 Liquid Glass 精修总结 (PROGRESS)

> 最后更新：2026-11-23

## 1. 阶段完成情况

| 阶段 | 状态 | 核心交付 |
| :--- | :---: | :--- |
| **Stage A: 视觉考古与基线** | ✅ | 完成 `airplay/` 与 `AirMuse_Remastered/` 考古，生成 `ORIGINAL_UI_SPEC.md`、`SKIN_ASSET_MAPPING.md` 及资源组合基线图 |
| **Stage B: 原始皮肤渲染器** | ✅ | 导入 `1x/` 与 `4x/` 皮肤 PNG；实现 `SkinAssetLoader`、`SkinAtlas`、`NineSliceRenderer`、`OriginalGlassRenderer`、`OriginalControlRenderer`、`PixelFontRenderer`、`RenderCache`、`PlayerLayerComposer`、`MiniPlayerLayerComposer`；移除 `GlassSurface` 全窗口 `NSVisualEffectView` |
| **Stage C: 主播放器 1:1 复刻** | ✅ | 重建 `PlayerView`（`MAINCONTROL` 5 枚按钮、`WINDOWBUTTON` 顶/底窗口按钮、胶囊进度条、8 段音量柱、`TIMEFONT` 数码时间、中线/边界扫光） |
| **Stage D: 迷你模式与动画** | ✅ | 重建 `MiniPlayerView`（`40px`/`60px` 透明玻璃条、`MINICONTROL`、8 向紧凑光晕跑马灯、`TIMEFONT` 点击切换剩余时间）、`PlayerWindow` 双击防抖与右键菜单、`PlayerWindowController` 顶部锚定动画与位置记忆 |
| **Stage E: 歌词/资料库/吸附** | ✅ | 使用 `GlassPanel` 重构 `LyricsWindow` / `LyricsView`；替换 `LibraryTopBarView` 为局部 `LiquidGlassControl`；升级 `DockManager` 缩放感知吸附 |
| **Stage F: 局部 Liquid Glass** | ✅ | 实现 `Original` / `Enhanced` 双模式切换、`LiquidGlassControl` (`NSGlassEffectView`)、`LiquidGlassOverlay` (`NSGlassEffectContainerView`) 及 `GlassInteractionCoordinator` |
| **Stage G: 视觉回归与验证** | ✅ | 完成 `DesignSystemTests`、`Tests/VisualRegression/` 捕获与差异对比、`RENDERING_ARCHITECTURE.md`、`ANIMATION_SPEC.md`、`LIQUID_GLASS_ENHANCEMENT.md`、`VISUAL_COMPARISON.md` |

---

## 2. 构建与测试状态

| 检查项 | 结果 | 说明 |
| :--- | :---: | :--- |
| `swift build --disable-sandbox` | ✅ 通过 | 主工程 0 errors（9.88s） |
| `swift build --disable-sandbox --product AirMuse` | ✅ 通过 | 可执行文件编译完成（11.84s） |
| `verify_airmuse` 链接测试套件 | ✅ 全部通过 | 覆盖资源加载 (14/14)、图集裁剪、9-slice DPI、MiniMode 状态机、`DockManager`、性能基准与视觉回归 |
| `swift test` (`XCTest` 目标) | ⚠️ 环境限制 | 当前环境仅安装 CommandLineTools（无完整 Xcode `XCTest.framework`），`DomainTests` 等旧 `XCTest` 目标无法在该环境链接；新增 `DesignSystemTests` 已采用 Swift Testing (`import Testing`) |

---

## 3. 已知局限

1. 当前环境无法直接运行 Windows 原生程序 `AIRPLAY-zion.exe`，基线参考图由解包原始 32-bit ARGB 资源与反汇编规格组合复原。
2. 未安装完整 Xcode，故 `XCTest` 测试目标需在完整 Xcode 环境下运行 `swift test`。
