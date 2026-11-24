# AirMuse Icon & Logo Generator

This directory contains the logo generation script and output assets for **AirMuse**.

The logo concept: **4 eighth notes (八分音符) with their bottom noteheads ("豆子") clustered together at the center base, and their tails/flags ("尾巴") fanning out across 120°**, featuring the AirMuse Aurora gradient aesthetic.

---

## Visual Concept & Geometry

- **豆子集中 (Noteheads Clustered)**: 4 个八分音符的符头紧密聚集在底部中心（如花托/声学核心节点），各个音符之间有清晰细腻的边线与色阶渐变区分。
- **尾巴散成 120 度 (Tails Fanning 120°)**: 4 支符干与符尾分别沿 **-60°、-20°、+20°、+60°** 向上方和两侧展开，形成总跨度为 **120°** 的对称羽翼/声波放射扇形。
- **极光流光色系 (Aurora Gradient)**: 左侧青蓝（Cyan）→ 薄荷绿（Mint）→ 皇家紫（Royal Purple）→ 霓虹品红（Hot Magenta），与 AirMuse 的极光玻璃设计语言保持一致。

---

## Generated Files

- **`app_icon.svg` / `app_icon.png`**: 1024×1024 macOS squircle app icon (with glass border and atmospheric glow).
- **`logo_transparent.svg` / `logo_transparent.png`**: 1024×1024 transparent background logo.
- **`logo_glyph.svg`**: Flat vector monochrome glyph (suitable for toolbars, menu bar icons, or printing).
- **`AirMuse.icns`**: macOS system icon bundle (contains 16×16 through 1024×1024 @2x resolutions, ready for Xcode).
- **`AppIcon.iconset/`**: Standard Apple iconset folder.

---

## How to Run / Customize

```bash
# 1. Default generation (豆子集中, 尾巴散成120度, 极光渐变)
python3 generate_logo.py

# 2. 调节发散角度 (例如改为 100 度或 140 度)
python3 generate_logo.py --span 100

# 3. 调节豆子聚拢紧密程度 (默认 16，0 为完全重合)
python3 generate_logo.py --cluster-radius 0

# 4. 切换配色主题 (aurora | neon_cyan | apple_music | gold | monochrome)
python3 generate_logo.py --theme neon_cyan
python3 generate_logo.py --theme apple_music

# 5. 传统非镜像符尾 (保持全部向右的传统乐理符尾)
python3 generate_logo.py --standard-flags
```
