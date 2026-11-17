# AirMuse 🎵

AirMuse 是专为 Windows 平台打造的高性能 Apple Music 桌面微型悬浮控制器与音乐套件。基于现代 C++20 与原生 Windows API 重构，具备极低资源占用、原生毛玻璃磨砂视觉美学与 4K 高清矢量重制。

---

## 🌟 核心特性

- **现代 C++20 核心**：无臃肿庞大框架，启动迅速，常驻内存与 CPU 占用极低。
- **SMTC (System Media Transport Controls) 原生集成**：深度对接 Windows 系统媒体传输控制，支持双向播放控制（播放、暂停、上一曲、下一曲、音量与播放状态同步）。
- **Acrylic / Frosted Glass 视觉美学**：Windows 10/11 原生毛玻璃窗口与圆角阴影渲染，精准保留上 24px、下 20px 磨砂边框 Chrome，拒绝内容覆盖。
- **4K 高清矢量化 (SVG Re-mastered)**：全部界面控件、像素点阵字体、按钮图标均经过高精度矢量重绘，完美适配 100% ~ 400% 任意高 DPI 屏幕。
- **解耦式音源架构 (Multi-Provider Architecture)**：
  - 音源接口标准化 (`IWebAdapter`)，已支持 Apple Music、QQ 音乐、Spotify 等多源扩展。
  - 数据获取与界面渲染深度解耦，支持离线/热启缓存与静默后台并发拉取。
- **高性能 Amp-API 官方直连引擎 (`airmuse_apple_engine.js`)**：
  - **IndexedDB 极速直出**：告别 LocalStorage 大小限制，毫秒级冷启动，支持多数据集增量存储与后台静默拉取。
  - **居中导航与便捷操作**：顶部居中集成五大核心模块（`主页`、`新发现`、`广播`、`资料库`、`歌单`），左侧快捷刷新（`⟳`），右侧提供单/双栏栅格切换（`⚏`/`☰`）与实时全局检索（`🔍`）。
  - **紧凑高密设计与角标系统**：封面右上角微型数据类型角标（`am-cover-badge`），去除冗余调试数字与眉标干扰。
  - **歌单分类与专属角标**：按 `所有歌单` $\rightarrow$ `收藏歌单` $\rightarrow$ `为你推荐` $\rightarrow$ `自建歌单` 精细化排列，右上角自建（蔚蓝）与收藏（粉红）角标清晰标识。
  - **资料库精细分类与高清艺人写真**：按 `最近添加` $\rightarrow$ `喜爱歌曲` $\rightarrow$ `专辑` $\rightarrow$ `艺人` $\rightarrow$ `已存单曲` 顺序呈现；通过 Amp-API Catalog 关联，完美解决官方资料库艺人缺失封面问题，展现高清官方艺人写真。
  - **内嵌式详情页浏览**：点击歌单与专辑时，曲目详情严格于右侧内容栏展现，左侧分类侧边栏始终保持可见与交互。
  - **沉浸式搜索与双域切换引擎**：
    - 点击顶部搜索按钮（`🔍`）后，标签栏原地无缝替换为精致搜索栏（保持 32px 高度不变），支持 `‹` 返回按钮或按 `Esc` 键一键恢复；
    - 搜索框右侧集成胶囊型范围开关（`[ Apple Music | 资料库 ]`），支持自由在 Apple Music 全球曲库与用户个人资料库之间切换检索；
    - 搜索结果严格采用双栏架构：左侧智能归类（`最佳结果`、`歌曲`、`艺人`、`专辑`、`歌单`），右侧卡片网格呈现，支持直接切歌、专辑专区展开与触底无限加载。
  - **触底无限滚动加载与 SPA 稳定守护**：基于 Apple Music `nextUrl` 的自动分页加载机制，配合 DOM 守护进程与安全的脚本注入引擎，告别白屏与内存越界隐患。

---

## 📁 目录结构

```text
AirMuse/
├── AirMuse_Remastered/           # 🔥 最新重制版 (C++20 + WebView2 + 极速直连引擎)
│   ├── CMakeLists.txt            # CMake 构建脚本 (自动同步前端引擎资源)
│   ├── run.ps1                   # 一键编译、终止旧实例并启动的 PowerShell 脚本
│   ├── assets/                   # 矢量皮肤与界面素材
│   └── src/
│       ├── core/                 # AppController、WinCommon 等核心控制流
│       ├── media/                # WebSourceProvider、WebAdapters 与 provider/ 模块
│       │   ├── airmuse_apple_engine.js  # Apple Music 官方直连前端渲染引擎
│       │   └── provider/         # AppleMusicAdapter、QQMusicAdapter、SpotifyAdapter
│       └── ui/                   # MainWindow、LyricsWindow、LibraryWindow、GlassRenderer
├── AMW/                          # Apple Music Web 极速数据采集引擎与调试工具箱
│   ├── fetch_data.js             # 官方 Amp-API 并发采集脚本
│   ├── render.js                 # 独立 400x400 视窗渲染器
│   ├── index.html                # 单文件静态测试页面
│   └── README.md
├── AirMuse_Windows_Native/       # 原生 C++20 极简微型控制器 (<600KB)
├── AirMuse_4K_Remastered/        # 4K 重制增强版初期工程
├── assets/                       # 高清矢量化 SVG 素材库 (带 preview.html 预览)
├── unpacked_assets/              # 逆向工程提取的原始皮肤与点阵资源包
└── AIRPLAY-zion.exe              # 原型可执行文件
```

---

## 🛠️ 构建与运行

### 前置要求
- Windows 10 (1809+) 或 Windows 11
- CMake 3.20+ 与 Ninja
- Visual Studio 2022 (或 VS 2022 Build Tools，安装有 MSVC v143、Windows SDK 10.0.19041+)

### 快速一键编译与启动 (推荐)

进入 `AirMuse_Remastered` 目录，直接运行配套的构建脚本：

```powershell
cd AirMuse_Remastered
.\run.ps1
```

该脚本将自动：
1. 导入 VS2022 x64 构建工具链环境变量；
2. 安全终止后台可能存在的运行实例；
3. 执行增量 CMake / Ninja 编译；
4. 保证将最新的前端引擎脚本同步至执行目录；
5. 自动拉起全新的 `AirMuse.exe`。

### 手动命令行编译

```powershell
cd AirMuse_Remastered
cmake -B build -G "Ninja" -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

---

## 📄 开源许可证

本项目遵循 MIT 许可证。详情请参阅项目源码。
