# AirMuse 🎵

AirMuse 是专为 Windows 平台打造的高性能 Apple Music 桌面微型悬浮控制器与音乐套件。基于现代 C++20 与原生 Windows API 重构，具备极低资源占用、原生毛玻璃磨砂视觉效果与 4K 高清矢量重制。

---

## 🌟 核心特性

- **现代 C++20 架构**：无臃肿运行时，启动迅速，内存占用极小。
- **SMTC (System Media Transport Controls) 原生集成**：支持双向媒体控制（播放、暂停、上一曲、下一曲、音量、进度获取）。
- **Acrylic / Frosted Glass 视觉美学**：Windows 10/11 原生毛玻璃窗口与圆角阴影渲染。
- **4K 高清矢量化 (SVG Re-mastered)**：全部界面控件、像素点阵字体、按钮图标均经过高精度矢量重绘，完美适配 100% ~ 400% 任意高 DPI 屏幕。
- **模块化项目结构**：
  - `AirMuse_Windows_Native`: 超轻量原生单文件微型控制器 (<600KB)，极简性能首选。
  - `AirMuse_4K_Remastered`: 增强版，集成动态歌词渲染（LyricsProvider）与 WebView2 WebLibraryPanel 媒体库交互。
  - `assets` / `assests`: 15 个高清矢量化 SVG 素材与可视化预览套件。
  - `unpacked_assets`: 逆向工程提取的原始皮肤与点阵资源包。

---

## 📁 目录结构

```text
AirMuse/
├── AirMuse_Windows_Native/       # 原生 C++20 极简微型控制器
│   ├── CMakeLists.txt
│   ├── assets/
│   └── src/
├── AirMuse_4K_Remastered/        # 4K 重制增强版 (WebView2 + 歌词)
│   ├── CMakeLists.txt
│   ├── assets/
│   └── src/
├── assets/                       # 高清矢量化 SVG 素材库 (带预览 HTML)
│   ├── AUDIO.svg
│   ├── MAINCONTROL.svg
│   ├── MINICONTROL.svg
│   ├── preview.html
│   └── ...
├── unpacked_assets/              # 逆向提取的原始资源
└── AIRPLAY-zion.exe              # 原型可执行文件
```

---

## 🛠️ 构建与编译

### 前置要求
- Windows 10 (1809+) 或 Windows 11
- CMake 3.20+
- MSVC 2022 (支持 C++20，安装有 Windows SDK 10.0.19041+)

### 编译步骤

```powershell
# 1. 编译 AirMuse Windows Native (极简版)
cd AirMuse_Windows_Native
cmake -B build -A x64
cmake --build build --config Release

# 2. 编译 AirMuse 4K Remastered (增强版)
cd ../AirMuse_4K_Remastered
cmake -B build -A x64
cmake --build build --config Release
```

编译输出的二进制位于各自目录下的 `build/Release/AirMuse.exe`。

---

## 📄 开源许可证

本项目遵循 MIT 许可证。详情请参阅项目源码。
