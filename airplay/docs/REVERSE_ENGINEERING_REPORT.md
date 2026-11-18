# AirPlay (Zion Edition) 深度逆向工程分析报告

---

## 1. 目标文件概述 (Executive Summary)

* **目标文件名称**：`AIRPLAY-zion_unpacked.exe`
* **文件大小**：1,945,600 字节 (~1.85 MB)
* **目标架构**：32-bit x86 PE32 (GUI Executable)
* **编译器与工具链**：**Borland Delphi (Win32)**，采用高度手写优化的纯 Win32 API 架构，摒弃了沉重的 VCL Form 机制，直接通过 Windows Layered Window (`WS_EX_LAYERED`) 与自研 32 位 ARGB 双缓冲图形引擎绘制。
* **文件哈希**：
  * **SHA-256**：`1187f1b293ce87823c3ac0c64fca66b3954ae9e8ab5178928b15333420b182f6`
  * **MD5**：`efcfbdcb2750e3fa0cf7ce077a7605e5`

---

## 2. PE 结构与节区分析 (PE Structure & Sections)

| 节区名称 | 虚拟地址 (RVA) | 虚拟大小 | 文件偏移 (Raw Offset) | 节区大小 | 属性标志 | 说明 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`.text`** | `0x00001000` | 1,089,414 字节 | `0x00001000` | 1,089,536 字节 | `0x60000020` (Code, Execute, Read) | 核心代码区、UI 引擎、音频解码管道 |
| **`.rdata`** | `0x0010A000` | 295,471 字节 | `0x0010A000` | 299,008 字节 | `0x40000040` (Initialized Data, Read) | 只读常量、VMT 虚函数表、字符串表 |
| **`.data`** | `0x00153000` | 757,988 字节 | `0x00153000` | 94,208 字节 | `0xC0000040` (Initialized Data, Read, Write) | 全局状态、音频缓存、UI 控件实例 |
| **`.rsrc`** | `0x0020D000` | 462,136 字节 | `0x0016A000` | 462,848 字节 | `0x40000040` (Resources, Read) | 皮肤切片 (RLE)、图标、TAK 解码动态库 |

### 核心导入表 (Imports)
* **USER32.dll**：`UpdateLayeredWindow`、`SetLayeredWindowAttributes`、`CreateWindowExW`、`RegisterClassW`、`DefWindowProcW`、`SetWindowLongW`、`GetWindowLongW`。
* **GDI32.dll**：`CreateFontW`、`SetTextColor`、`TextOutW`、`GetTextExtentPoint32W`。
* **KERNEL32.dll**：内存管理、线程调度、动态库加载 (`LoadLibraryW` / `GetProcAddress`)。
* **WINMM.dll**：高精度定时器 (`timeGetTime`、`timeBeginPeriod`)。

---

## 3. 资源系统与自研 RLE 压缩格式 (Resource Subsystem & RLE Algorithm)

AirPlay 未使用标准 PNG 或 BMP 资源，而是设计了一套极致紧凑的 **32 位 ARGB 游程编码压缩格式 (Magic: `RLE\xf1`)**。

### 3.1 RLE 头部结构 (16 字节)
```c
#pragma pack(push, 1)
struct AirPlayRleHeader {
    char     magic[4];   // 'R', 'L', 'E', 0xF1 (0xF1454C52)
    uint32_t width;      // 图像宽度 (像素)
    uint32_t height;     // 图像高度 (像素)
    uint32_t flags;      // 标志位 (通常为 1)
};
#pragma pack(pop)
```

### 3.2 游程指令解码算法 (逆向自 `0x0049AC50` - `0x0049AE60`)
每次从流中读取 1 字节指令码 `cmd`：
* 若 `cmd == 0xFF`：流结束，退出解码。
* 拆分指令码：`tag = cmd >> 6` (前2位)，`count = (cmd & 0x3F) + 1` (后6位，范围 1..64)。
* **Tag 0 (二进制 `00`)**：透明像素游程。写入 `count` 个全透明像素 `0x00000000`。
* **Tag 1 (二进制 `01`)**：直接像素序列。连续从数据流中读取 `count` 个 32 位 ARGB 像素（每像素 4 字节：B, G, R, A）。
* **Tag 2 (二进制 `10`)**：不透明 RGB 序列。连续从数据流中读取 `count` 个 24 位 RGB 像素（每像素 3 字节：B, G, R），Alpha 自动强制置为 `0xFF`。
* **Tag 3 (二进制 `11`)**：重复像素游程。从数据流中读取 1 个 32 位 ARGB 像素（4 字节），将其连续重复写入 `count` 次。

### 3.3 资源资产清单 (Asset Catalog)
全部资源已提取至 `airplay/resources/`：
| 资源标识 | 资源类别 | 原始尺寸 | 格式 | 描述 |
| :--- | :--- | :--- | :--- | :--- |
| **`WINDOWGLASS`** | RT_RCDATA | 30×40 | RLE (32位 ARGB) | 失焦状态玻璃切片 (9-slice) |
| **`WINDOWGLASSFOCUS`**| RT_RCDATA | 30×40 | RLE (32位 ARGB) | 激活聚焦状态玻璃切片 (高光反光增强) |
| **`MINICONTROL`** | RT_RCDATA | 96×16 | RLE (32位 ARGB) | 迷你模式播放控制按钮条 (6个 16×16 按钮) |
| **`MINIFONT`** | RT_RCDATA | 40×5 | RLE (32位 ARGB) | 极微型像素数字字体 (5×5) |
| **`TIMEFONT`** | RT_RCDATA | 90×14 | RLE (32位 ARGB) | 经典七段数码时间位图字体 (每字符 6×7) |
| **`WINDOWBUTTON`** | RT_RCDATA | 130×26 | RLE (32位 ARGB) | 窗口控制按钮精灵图 (关闭/最小化/最大化) |
| **`MAINCONTROL`** | RT_RCDATA | 192×32 | RLE (32位 ARGB) | 主面板大型控制按钮精灵图 |
| **`ICONBUTTON`** | RT_RCDATA | 165×45 | RLE (32位 ARGB) | 播放列表与面板功能图标按钮 |
| **`MENUGLASS`** | RT_RCDATA | 40×40 | RLE (32位 ARGB) | 弹出菜单水晶玻璃底板 |
| **`HINTGLASS`** | RT_RCDATA | 40×40 | RLE (32位 ARGB) | 浮动提示条 (Tooltip) 水晶底板 |
| **`TAKDECLIB`** | RT_RCDATA | 99,328 B | PE DLL | TAK 无损音频解码器动态链接库 |
| **`PYCODE`** | RT_RCDATA | 262,144 B | 二进制表 | GBK 汉字拼音首字母检索映射表 |
| **`APPICON`** | RT_GROUP_ICON | 多尺寸 | Windows ICO | AirPlay 官方应用程序主图标 |

---

## 4. 窗口架构与分层合成管线 (Window Architecture & Compositor)

### 4.1 窗口类与注册
* 应用程序在启动时注册两类核心窗口类：
  * `AIRPLAY_BASE_WINDOW`：单实例守护与消息代理窗口（反汇编地址 `0x0044AC5A`）。
  * `FAIRPLAY GUI OBJEXT CLASS`：分层半透明 UI 窗口类（反汇编地址 `0x0047DFE3`）。
* **窗口样式配置**（反汇编地址 `0x0046FE87`）：
  * `dwStyle` = `WS_POPUP | WS_CLIPSIBLINGS` (`0x86000000`)
  * `dwExStyle` = `WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST` (`0x88` 并在创建后追加 `0x80000`)

### 4.2 渲染与合成管线
AirPlay 绝不在 `WM_PAINT` 中执行普通 GDI 绘制，而是使用全内存双缓冲 DIB Section：
1. 分配与窗口等大的 32 位 ARGB DIB 位图。
2. 逐层将背景玻璃、按钮状态精灵、波形/频谱、文字图层混合写入内存缓冲区。
3. 调用 `UpdateLayeredWindow` 将整个 32 位 ARGB 表面一次性提交给 Windows DWM 桌面窗口合成器：
   ```c
   BLENDFUNCTION blend = { AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
   UpdateLayeredWindow(hwnd, NULL, &ptDst, &sizeWnd, hdcSrc, &ptSrc, 0, &blend, ULW_ALPHA);
   ```

---

## 5. 迷你模式核心逆向机制 (Mini Mode Mechanics)

### 5.1 窗口尺寸与紧凑结构
* **原版标准高度**：**40 像素**。
* **玻璃条咬合原理**：
  * 原版 `WINDOWGLASS` 高度为 40px。正常模式下截取上 20px 作为顶栏，下 20px 作为底栏，中间为面板。
  * **在迷你模式下，内容区高度为 0，上下两个 20px 玻璃条直接垂直咬合，拼成一个完整的 40px 水晶条**！
  * 当用户需要更紧凑的 30px 迷你模式时，上下玻璃条分别截取 15px 或直接进行等比压缩。
* **深色横条问题溯源**：原版完全没有不透明背景色填充，其深色晶莹质感完全来自于 `WINDOWGLASS` 内部自带的半透明高光反光灰度纹理。任何额外的 `FillRect` 或渐变色绘制都会破坏透明通道，产生死板的“深色横条”。

### 5.2 控件排列与命中测试
反汇编函数 `0x004576C4` 揭示了迷你条的绘制序列：
1. **背景玻璃切片** (`call 0x00457B91`)
2. **状态与频谱条** (`call 0x004573B0`)
3. **曲目滚动标题** (`call 0x00458036`)
4. **数字时间** (`call 0x0045797D`)
5. **控制按钮** (`call 0x00457498`)：
   * 按钮 0：上一曲 (Prev)
   * 按钮 1/2：播放/暂停切换 (Play/Pause)
   * 按钮 4：下一曲 (Next)
   * 按钮 5：停止 (Stop)
   * 按钮 6/7：最小化/关闭 (Min/Close)

---

## 6. 音频引擎管线 (Audio Engine Pipeline)

AirPlay 采用了极其精炼高效的混合音频解码管线：
1. **静态内置解码器**：
   * `libFLAC 1.2.1`（FLAC 无损解码）
   * `Ogg Vorbis (Xiph.Org)`
   * MP3 (MAD/Fraunhofer)
   * Monkey's Audio (APE v2 标签与音频流)
2. **动态插件扩展**：
   * 启动时将 `TAKDECLIB` 资源释出并加载为 `tak_deco_lib.dll`，动态解析 `tak_SSD_Create_FromFile`、`tak_SSD_ReadAudio` 等无损流接口。
3. **输出抽象**：
   * 支持 DirectSound 缓冲环形队列及 WASAPI 独占输出，配合高精度多媒体定时器（`timeBeginPeriod(1)`）实现极低音频延迟。

---

## 7. 交付文件树 (Deliverables)

所有解密资源与重建代码均已完整交付至 `airplay/` 目录：
```
e:\Codes\Github\AirMuse\airplay\
├── resources\
│   ├── manifest.json            # 资源完整元数据清单
│   ├── bitmaps\                 # 全部解密后的 32位 ARGB PNG 图像
│   │   ├── HINTGLASS.png
│   │   ├── ICONBUTTON.png
│   │   ├── MAINCONTROL.png
│   │   ├── MENUGLASS.png
│   │   ├── MENUICON.png
│   │   ├── MINICONTROL.png
│   │   ├── MINIFONT.png
│   │   ├── PACKHINT.png
│   │   ├── QUADFONT.png
│   │   ├── RATING.png
│   │   ├── TIMEFONT.png
│   │   ├── WINDOWBUTTON.png
│   │   ├── WINDOWGLASS.png
│   │   └── WINDOWGLASSFOCUS.png
│   ├── icons\                   # 提取的图标文件 (.ico)
│   │   ├── icon_app.ico
│   │   ├── icon_audio_file.ico
│   │   └── icon_playlist_file.ico
│   ├── binaries\                # 原生 DLL 与数据表
│   │   ├── tak_deco_lib.dll
│   │   └── pinyin_index_table.dat
│   └── raw_rcdata\              # PE 资源原始二进制转储 (.bin)
├── tools\
│   ├── unpack_resources.py      # 自动化资源提取与转换工具
│   └── rle_converter.py         # RLE\xf1 编解码命令行工具
├── src\
│   ├── AirPlayTypes.hpp         # 常量、消息映射、几何规范
│   ├── AirPlayRleCodec.hpp      # RLE\xf1 编解码 C++ 完整实现
│   ├── AirPlayGlassRenderer.hpp # 玻璃切片与文字光晕渲染器头文件
│   ├── AirPlayGlassRenderer.cpp # 玻璃条 9-slice 合成与光晕实现
│   ├── AirPlayMiniPlayer.hpp    # 迷你模式窗口与控件头文件
│   ├── AirPlayMiniPlayer.cpp    # 迷你模式完整交互、布局与绘制实现
│   ├── AirPlayMainWindow.hpp    # 主窗口架构与模式切换头文件
│   ├── AirPlayMainWindow.cpp    # 主窗口实现与任务栏吸附机制
│   ├── AirPlayAudioEngine.hpp   # 音频解码与 TAK 库包装头文件
│   └── AirPlayAudioEngine.cpp   # 音频引擎实现
└── docs\
    ├── REVERSE_ENGINEERING_REPORT.md # 深度逆向工程分析报告 (本文档)
    └── MINI_MODE_SPECIFICATION.md    # 迷你模式像素级规格说明书
```
