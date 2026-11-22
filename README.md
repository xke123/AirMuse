# AirMuse

AirMuse 是一个跨平台桌面音乐微悬浮播放器与流媒体套件，灵感与视觉基因源自经典播放器 **AIRPLAY (Zion)**，并在 Windows 与 macOS 上以原生图形技术与现代流媒体引擎进行高保真复刻与重构。

---

## 核心特性

### 经典水晶玻璃美学与跨平台原生实现
- **Windows (`AirMuse_Remastered/`)**：基于 C++20、Win32 Layered Window、GDI+ 与 WebView2 构建，具备极低资源占用、4× 超采样水晶玻璃外框、SMTC 系统媒体控制集成、镜面扫光与弹簧阻尼动画。
- **macOS (`AirMuse_macOS/`)**：基于 Swift 6（Strict Concurrency）、AppKit、Core Animation、Core Graphics 与 WKWebView 原生构建，完整复刻 AIRPLAY-zion 九宫格透明水晶边框、原始位图精灵图集（`MAINCONTROL` / `MINICONTROL` / `WINDOWBUTTON` / `TIMEFONT`）、独立主/迷你双窗口切换、多窗口磁吸停靠，并支持 `Original`（纯原版复刻）与 `Enhanced`（macOS 26+ 局部 `NSGlassEffectView` 增强）双渲染模式及 `1.0×` / `1.5×` 全局缩放。

### 多窗口协同与交互体验
- **主播放器**：左右两栏紧凑布局（左栏常驻专辑封面，右栏展示曲目信息/悬停控制与胶囊进度条），支持鼠标跨越中线与触碰玻璃边界的光学镜面扫光。
- **独立迷你模式**：`40pt`（1×）/ `60pt`（1.5×）全透明水晶玻璃条，非悬停状态下每 10 秒垂直轮播歌曲名、歌手与专辑，文字采用柔和暗雾光晕渲染；支持点击时间切换已播/剩余时长。
- **桌面歌词窗**：同步滚动歌词、翻译支持、滚轮/按钮延迟微调（±0.5s），以及可折叠的单行迷你歌词条模式。
- **音乐资料库与多源引擎**：支持 Apple Music 官方 Amp-API 直连与 Web Playback、Spotify、QQ 音乐等解耦式音源架构，集成主页、新发现、广播、资料库、歌单五大模块与全局/个人曲库双域搜索。

---

## 目录结构

```text
AirMuse/
├── AirMuse_macOS/                # macOS 原生版本 (Swift 6 + AppKit + Core Animation)
│   ├── Package.swift             # SwiftPM 工程清单（Domain / Playback / Lyrics / Providers / DesignSystem / UI / App）
│   ├── Sources/
│   │   ├── Domain/               # 领域模型与 Provider 协议
│   │   ├── Infrastructure/       # SQLiteStore、ImageCache、NetworkSession、Keychain、WebKit 桥接
│   │   ├── Providers/            # AppleMusic（Amp-API + WebPlayer）、Spotify、QQMusic
│   │   ├── Playback/             # PlaybackStore、PlaybackCoordinator、MediaArbitrator
│   │   ├── Lyrics/               # LyricsEngine 同步歌词引擎
│   │   ├── DesignSystem/         # 原版皮肤加载、九宫格玻璃渲染、像素字体、局部 Liquid Glass 增强
│   │   ├── UI/                   # Player、MiniPlayer、Lyrics、Library、DockManager、Auth、Log
│   │   └── App/                  # AppDelegate 与应用入口
│   ├── Tests/                    # 单元测试与 VisualRegression 视觉回归基线/对比资产
│   ├── docs/                     # 原版视觉规范、资源映射、渲染/动画/增强架构文档
│   └── scripts/build.sh          # macOS .app 打包与签名脚本
├── AirMuse_Remastered/           # Windows 原生版本 (C++20 + GDI+ + WebView2 + SMTC)
│   ├── CMakeLists.txt
│   ├── run.ps1                   # Windows 一键编译与启动脚本
│   ├── assets/                   # 4× 超采样玻璃与控件 PNG 资产
│   └── src/
│       ├── core/                 # AppController、WinCommon
│       ├── media/                # WebSourceProvider、Apple Music 直连引擎与多源适配器
│       └── ui/                   # MainWindow、LyricsWindow、LibraryWindow、GlassRenderer、DockManager
├── airplay/                      # AIRPLAY-zion 原版逆向工程资料、RLE 解码器与解包位图资源
│   ├── docs/                     # 逆向工程报告与迷你模式规格说明书
│   ├── resources/                # 解密 32-bit ARGB PNG 位图、图标、二进制数据与 manifest.json
│   └── src/                      # C++ 逆向参考实现与 RLE 编解码器
├── AIRPLAY-zion.exe              # 原版参考可执行文件
└── AIRPLAY-zion_unpacked.exe     # 脱壳后用于静态逆向分析的可执行文件
```

---

## 构建与运行

### macOS (`AirMuse_macOS`)

**环境要求**：macOS 26+，Swift 6.2+（Xcode 或 CommandLineTools）

```bash
cd AirMuse_macOS

# 方式一：打包为 AirMuse.app 并启动
bash scripts/build.sh

# 方式二：仅构建 SwiftPM 工程
swift build
```

### Windows (`AirMuse_Remastered`)

**环境要求**：Windows 10 (1809+) / Windows 11、CMake 3.20+、Ninja、Visual Studio 2022 (MSVC v143)

```powershell
cd AirMuse_Remastered

# 一键编译并启动
.\run.ps1
```

或使用 CMake 手动构建：

```powershell
cd AirMuse_Remastered
cmake -B build -G "Ninja" -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

---

## 开源许可证

本项目遵循 MIT 许可证，详情请参阅仓库源码。
