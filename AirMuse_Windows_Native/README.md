# AirMuse Windows Native (C++20 + Win32 Layered Window + C++/WinRT SMTC)

基于原版 AirPlay (飞乐) 2.0 Zion 解码切图构建的极简 Windows 原生 Apple Music 悬浮控制端。
零外部运行时依赖，静态链接 CRT，Release 编译后单文件 `.exe` 仅约 **350 KB – 600 KB**。

## 功能特性
- **原生水晶异形窗体**：使用 `WS_EX_LAYERED` + `UpdateLayeredWindow` + GDI+ 9-Slice 绘制原版 `WINDOWGLASS.png` 透明质感，支持鼠标左键拖拽与迷你模式切换。
- **零轮询 Apple Music 同步**：通过 C++/WinRT `GlobalSystemMediaTransportControlsSessionManager` 自动锁定 `AppleMusic` 会话，实时同步歌名、歌手、专辑封面与播放进度。
- **完整播控与托盘**：支持播放/暂停、停止、上/下一首、滚轮调节系统音量，以及系统托盘常驻。

## 编译方法（Windows / Visual Studio 2022）
在 **Developer Command Prompt for VS 2022** 中执行：

```bat
cmake -B build -A x64
cmake --build build --config Release
```

生成的单文件可执行程序位于 `build\Release\AirMuse.exe`。如需进一步压缩体积至 ~300KB 左右，可执行：

```bat
upx --best --lzma build\Release\AirMuse.exe
```
