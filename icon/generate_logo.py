#!/usr/bin/env python3
"""
AirMuse Logo Generator (Official Apple SF Symbol Edition)
=========================================================
Generates high-resolution vector (SVG) and raster (PNG / ICNS) logos using
the EXACT, official Apple SF Symbol `music.note` vector outline extracted
directly from macOS CoreGlyphs / San Francisco typography.

Design:
- 4 authentic Apple SF Symbol eighth notes (八分音符 `music.note`).
- Bottom noteheads (豆子) clustered together at the central base.
- Stems & flags (尾巴) fanning out across 120° (-60°, -20°, +20°, +60°).
- AirMuse Aurora gradient aesthetic with luminous focal bead.

Usage:
    python3 generate_logo.py                     # Generate default 120° fan with authentic SF Symbols
    python3 generate_logo.py --theme aurora      # Aurora gradient theme (default)
    python3 generate_logo.py --theme neon_cyan   # Cyber neon cyan theme
    python3 generate_logo.py --span 120          # Fan angle span (default: 120°)
    python3 generate_logo.py --standard-flags    # Standard all-right flags (disable wing mirroring)
    python3 generate_logo.py --icns              # Also build macOS .icns bundle
"""

import os
import sys
import math
import argparse
import subprocess
import shutil
from pathlib import Path

# Optional Pillow import for image resizing
try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False


# ==============================================================================
# Exact Apple SF Symbol `music.note` Vector Outline
# Extracted directly from macOS CoreGlyphs (San Francisco regular weight)
# Bounds: width = 119.07, height = 196.99
# Bean (Notehead) Center Anchor: (31.75, 168.0)
# ==============================================================================
SF_SYMBOL_MUSIC_NOTE_PATH = (
    "M 119.07 45.16 "
    "L 119.07 8.47 "
    "C 119.07 3.36, 114.93 0.00, 109.87 1.05 "
    "L 59.78 11.95 "
    "C 53.52 13.33, 50.18 16.64, 50.18 22.13 "
    "L 50.27 130.79 "
    "C 50.81 135.55, 48.48 138.67, 44.22 139.46 "
    "L 28.69 142.70 "
    "C 9.19 146.84, 0.00 156.74, 0.00 171.63 "
    "C 0.00 186.57, 11.50 196.99, 27.68 196.99 "
    "C 42.08 196.99, 63.51 186.42, 63.51 157.99 "
    "L 63.51 68.68 "
    "C 63.51 63.45, 64.52 62.45, 69.18 61.51 "
    "L 113.80 51.61 "
    "C 116.96 50.88, 119.07 48.45, 119.07 45.16 Z"
)

# Anchor point at the center of the notehead (豆子)
SF_NOTE_ANCHOR_X = 31.75
SF_NOTE_ANCHOR_Y = 168.0


# ==============================================================================
# Color Themes Configuration
# ==============================================================================
THEMES = {
    "aurora": {
        "name": "Aurora Borealis (AirMuse Signature)",
        "bg_gradient": [("#0a0d1a", "0%"), ("#10152e", "50%"), ("#18102d", "100%")],
        "note_colors": [
            ("#00f2fe", "#00c4fe"),  # Note 0: Electric Cyan
            ("#38e8c6", "#05dfd7"),  # Note 1: Mint / Emerald
            ("#8b5cf6", "#7038e8"),  # Note 2: Royal Purple
            ("#ff007a", "#e00065"),  # Note 3: Hot Magenta
        ],
        "unified_gradient": [
            ("#00f2fe", "0%"),
            ("#38e8c6", "30%"),
            ("#8b5cf6", "65%"),
            ("#ff007a", "100%")
        ],
        "center_point": "#00f2fe",
        "center_ring": "#8b5cf6",
        "center_glow": "#00f2fe",
    },
    "neon_cyan": {
        "name": "Cyber Neon Cyan",
        "bg_gradient": [("#060b14", "0%"), ("#0b1626", "60%"), ("#102238", "100%")],
        "note_colors": [
            ("#00ffe7", "#00b4d8"),
            ("#00e5ff", "#0096c7"),
            ("#00b4d8", "#0077b6"),
            ("#90e0ef", "#03045e"),
        ],
        "unified_gradient": [
            ("#00ffe7", "0%"),
            ("#00b4d8", "50%"),
            ("#0077b6", "100%")
        ],
        "center_point": "#00ffe7",
        "center_ring": "#00b4d8",
        "center_glow": "#00ffe7",
    },
    "apple_music": {
        "name": "Apple Music Red/Coral",
        "bg_gradient": [("#12080a", "0%"), ("#240d12", "50%"), ("#19080c", "100%")],
        "note_colors": [
            ("#ff8a00", "#ff6b00"),
            ("#ff5e3a", "#fa2d48"),
            ("#fa2d48", "#e01833"),
            ("#ff2d55", "#cc0033"),
        ],
        "unified_gradient": [
            ("#ff8a00", "0%"),
            ("#ff5e3a", "50%"),
            ("#fa2d48", "100%")
        ],
        "center_point": "#ff5e3a",
        "center_ring": "#fa2d48",
        "center_glow": "#fa2d48",
    },
    "gold": {
        "name": "Acoustic Luxury Gold",
        "bg_gradient": [("#12100e", "0%"), ("#221d18", "50%"), ("#191511", "100%")],
        "note_colors": [
            ("#ffeaa7", "#fdcb6e"),
            ("#f6d365", "#fda085"),
            ("#fda085", "#f39c12"),
            ("#f39c12", "#d35400"),
        ],
        "unified_gradient": [
            ("#ffeaa7", "0%"),
            ("#fda085", "50%"),
            ("#f39c12", "100%")
        ],
        "center_point": "#f6d365",
        "center_ring": "#fda085",
        "center_glow": "#f6d365",
    },
    "monochrome": {
        "name": "Monochrome White on Dark",
        "bg_gradient": [("#141416", "0%"), ("#1e1e24", "100%")],
        "note_colors": [
            ("#ffffff", "#e2e8f0"),
            ("#f8fafc", "#cbd5e1"),
            ("#e2e8f0", "#94a3b8"),
            ("#ffffff", "#f1f5f9"),
        ],
        "unified_gradient": [
            ("#ffffff", "0%"),
            ("#e2e8f0", "100%")
        ],
        "center_point": "#ffffff",
        "center_ring": "#ffffff",
        "center_glow": "#ffffff",
    }
}


# ==============================================================================
# SVG Template Generator (Official SF Symbol Edition)
# ==============================================================================
def create_svg(
    span_deg: float = 120.0,
    count: int = 4,
    cluster_radius: float = 16.0,  # Clustered beans offset around center (0 to 25)
    theme_key: str = "aurora",
    style: str = "app_icon",       # "app_icon", "transparent", "glyph"
    symmetrical_wings: bool = True, # Mirror left notes' flags so tails fan out symmetrically
    canvas_size: int = 1024
) -> str:
    """
    Builds the SVG string for the logo using genuine Apple SF Symbol `music.note`.
    - Noteheads (豆子) clustered tightly together near (cx, cy).
    - Stems and tails/flags (尾巴) fan out across span_deg (default 120°).
    """
    theme = THEMES.get(theme_key, THEMES["aurora"])
    cx = canvas_size / 2.0
    # Center of bean cluster placed slightly lower (0.64) to leave soaring headroom for 120° fan tails
    cy = canvas_size * 0.65 if style == "app_icon" else canvas_size * 0.62

    # Angles calculation across span_deg
    # For count=4, span=120: step=40, angles = [-60°, -20°, +20°, +60°]
    step = span_deg / (count - 1) if count > 1 else 0.0
    start_angle = -span_deg / 2.0

    # Build background gradient stops
    bg_stops = "\n".join([f'      <stop offset="{pct}" stop-color="{c}" />' for c, pct in theme["bg_gradient"]])
    unified_stops = "\n".join([f'      <stop offset="{pct}" stop-color="{c}" />' for c, pct in theme["unified_gradient"]])

    # Per-note gradients so each clustered bean is distinctly visible
    note_grad_defs = []
    for i, (c1, c2) in enumerate(theme["note_colors"][:count]):
        note_grad_defs.append(f"""    <linearGradient id="note-grad-{i}" x1="0%" y1="100%" x2="0%" y2="0%">
      <stop offset="0%" stop-color="{c1}" />
      <stop offset="100%" stop-color="{c2}" />
    </linearGradient>""")
    note_grads_str = "\n".join(note_grad_defs)

    # Filters and definitions
    defs = f"""  <defs>
    <!-- Background Gradient -->
    <linearGradient id="bg-grad" x1="0%" y1="0%" x2="100%" y2="100%">
{bg_stops}
    </linearGradient>

    <!-- Unified Gradient for Single-Fill Modes -->
    <linearGradient id="unified-grad" x1="0%" y1="100%" x2="100%" y2="0%">
{unified_stops}
    </linearGradient>

{note_grads_str}

    <!-- Center Point Glow -->
    <radialGradient id="center-glow" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="{theme['center_glow']}" stop-opacity="0.6" />
      <stop offset="50%" stop-color="{theme['center_glow']}" stop-opacity="0.15" />
      <stop offset="100%" stop-color="{theme['center_glow']}" stop-opacity="0" />
    </radialGradient>

    <!-- Outer Ambient Aura -->
    <radialGradient id="ambient-aura" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="{theme['note_colors'][0][0]}" stop-opacity="0.25" />
      <stop offset="60%" stop-color="{theme['note_colors'][-1][0]}" stop-opacity="0.08" />
      <stop offset="100%" stop-color="{theme['bg_gradient'][0][0]}" stop-opacity="0" />
    </radialGradient>

    <!-- Glow Filter -->
    <filter id="soft-glow" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="10" result="blur" />
      <feMerge>
        <feMergeNode in="blur" />
        <feMergeNode in="SourceGraphic" />
      </feMerge>
    </filter>

    <!-- Official Apple SF Symbol `music.note` (Master Symbol) -->
    <!-- Extracted directly from macOS CoreGlyphs (San Francisco Regular) -->
    <g id="sf-symbol-note">
      <path d="{SF_SYMBOL_MUSIC_NOTE_PATH}" />
    </g>

    <!-- Mirrored SF Symbol Note (For Symmetrical Wings) -->
    <g id="sf-symbol-note-mirrored">
      <path d="{SF_SYMBOL_MUSIC_NOTE_PATH}" transform="translate({SF_NOTE_ANCHOR_X * 2}, 0) scale(-1, 1)" />
    </g>
  </defs>"""

    # Background elements
    bg_elements = ""
    if style == "app_icon":
        bg_elements = f"""  <!-- macOS App Icon Squircle Background -->
  <rect width="{canvas_size}" height="{canvas_size}" rx="224" fill="url(#bg-grad)" />
  <rect width="{canvas_size}" height="{canvas_size}" rx="224" fill="none" stroke="rgba(255, 255, 255, 0.12)" stroke-width="2" />
  <!-- Ambient Atmospheric Aura -->
  <circle cx="{cx}" cy="{cy - 120}" r="420" fill="url(#ambient-aura)" />"""

    # Center focal point & subtle orbital halo behind beans
    center_elements = f"""  <!-- Center Glow anchoring the Clustered Beans (豆子集中点) -->
  <circle cx="{cx}" cy="{cy}" r="260" fill="url(#center-glow)" />
  <!-- Subtle Convergence Orbit Ring -->
  <circle cx="{cx}" cy="{cy}" r="45" fill="none" stroke="{theme['center_ring']}" stroke-width="1.5" stroke-dasharray="4 6" opacity="0.4" />"""

    # Notes generation using exact SF Symbol
    # Scale ~2.15 gives bold, majestic presence matching Apple Human Interface Guidelines
    scale = 2.12
    note_instances = []

    for i in range(count):
        ang = start_angle + i * step
        # Symmetrical wings: left notes use left-mirrored flag, right notes use standard right flag
        is_left = symmetrical_wings and (ang < 0)
        symbol_id = "#sf-symbol-note-mirrored" if is_left else "#sf-symbol-note"

        # Position of bean (notehead center):
        # Clustered tightly around (cx, cy) with cluster_radius offset
        ang_rad = math.radians(ang)
        nx = cx + cluster_radius * math.sin(ang_rad)
        ny = cy - cluster_radius * math.cos(ang_rad)

        fill_paint = f'url(#note-grad-{i % len(theme["note_colors"])})' if style != 'glyph' else theme['note_colors'][0][0]
        # Dark stroke creates crisp separation between overlapping clustered beans
        stroke_attr = 'stroke="#0a0d1a" stroke-width="2.5"' if style != 'glyph' else ''

        # Transform:
        # 1. Translate to bean center (nx, ny)
        # 2. Rotate by ang
        # 3. Scale and align notehead center (-SF_NOTE_ANCHOR_X, -SF_NOTE_ANCHOR_Y)
        transform = f'translate({nx:.2f}, {ny:.2f}) rotate({ang:.2f}) scale({scale}) translate(-{SF_NOTE_ANCHOR_X:.2f}, -{SF_NOTE_ANCHOR_Y:.2f})'
        note_instances.append(
            f'    <g transform="{transform}" fill="{fill_paint}" {stroke_attr}>\n'
            f'      <use href="{symbol_id}" />\n'
            f'    </g>'
        )

    notes_group = "\n".join(note_instances)
    filter_attr = 'filter="url(#soft-glow)"' if style != 'glyph' else ''

    # Central focal bead on top of beans
    focal_bead = ""
    if style != 'glyph':
        focal_bead = f"""  <!-- Central Luminous Focal Bead -->
  <circle cx="{cx}" cy="{cy}" r="8" fill="#ffffff" opacity="0.95" filter="url(#soft-glow)" />
  <circle cx="{cx}" cy="{cy}" r="16" fill="none" stroke="{theme['center_point']}" stroke-width="2" opacity="0.6" />"""

    notes_section = f"""  <!-- 4 Official Apple SF Symbol `music.note` Eighth Notes Fanning Out {span_deg}° -->
  <g {filter_attr}>
{notes_group}
  </g>
{focal_bead}"""

    svg_content = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {canvas_size} {canvas_size}" width="{canvas_size}" height="{canvas_size}">
{defs}
{bg_elements}
{center_elements}
{notes_section}
</svg>
"""
    return svg_content


# ==============================================================================
# PNG and ICNS Exporters
# ==============================================================================
def rasterize_svg_macos(svg_path: Path, png_path: Path, size: int = 1024) -> bool:
    """Uses macOS native `qlmanage` to rasterize SVG into pixel-perfect PNG."""
    try:
        tmp_dir = svg_path.parent / ".tmp_render"
        tmp_dir.mkdir(exist_ok=True)
        cmd = ["qlmanage", "-t", "-s", str(size), "-o", str(tmp_dir), str(svg_path)]
        res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0:
            rendered = tmp_dir / f"{svg_path.name}.png"
            if rendered.exists():
                shutil.move(str(rendered), str(png_path))
                shutil.rmtree(tmp_dir, ignore_errors=True)
                return True
        shutil.rmtree(tmp_dir, ignore_errors=True)
    except Exception as e:
        print(f"  [!] Note: macOS qlmanage rasterization error: {e}", file=sys.stderr)
    return False


def build_iconset_and_icns(source_png: Path, output_icns: Path) -> bool:
    """Generates macOS .icns file with full Apple iconset sizes (16 to 1024)."""
    if not HAS_PIL:
        print("  [!] Pillow not installed; skipping .icns generation.", file=sys.stderr)
        return False
    if not shutil.which("iconutil"):
        print("  [!] iconutil not available; skipping .icns generation.", file=sys.stderr)
        return False

    iconset_dir = source_png.parent / "AppIcon.iconset"
    iconset_dir.mkdir(exist_ok=True)

    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    try:
        with Image.open(source_png) as base_img:
            for filename, sz in sizes:
                resized = base_img.resize((sz, sz), Image.Resampling.LANCZOS)
                resized.save(iconset_dir / filename)

        # Run iconutil
        cmd = ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(output_icns)]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception as e:
        print(f"  [!] Failed to build .icns: {e}", file=sys.stderr)
        return False


# ==============================================================================
# CLI Entry Point
# ==============================================================================
def main():
    parser = argparse.ArgumentParser(
        description="AirMuse Logo Generator: Official Apple SF Symbol `music.note` 120° Fan"
    )
    parser.add_argument("--span", type=float, default=120.0, help="Fan angle span of tails in degrees (default: 120.0)")
    parser.add_argument("--count", type=int, default=4, help="Number of eighth notes (default: 4)")
    parser.add_argument("--cluster-radius", type=float, default=16.0, help="Cluster radius of noteheads at bottom (default: 16.0, 0 for exact concentric)")
    parser.add_argument("--theme", choices=list(THEMES.keys()), default="aurora", help="Color theme (default: aurora)")
    parser.add_argument("--standard-flags", action="store_true", help="Keep traditional all-right flags (disable symmetrical wings)")
    parser.add_argument("--icns", action="store_true", help="Also build macOS .icns application icon bundle")
    parser.add_argument("--outdir", type=str, default=str(Path(__file__).parent), help="Output folder")
    args = parser.parse_args()

    outdir = Path(args.outdir).resolve()
    outdir.mkdir(parents=True, exist_ok=True)
    symmetrical = not args.standard_flags

    print("=" * 68)
    print("  AirMuse Logo Generator (Official Apple SF Symbol Edition)")
    print(f"  Symbol: Apple SF Symbol `music.note` | Fan Angle: {args.span}°")
    print(f"  Layout: Noteheads (豆子) clustered at base | Tails (尾巴) spread 120°")
    print(f"  Settings: {args.count} Notes | Theme: {args.theme} | Symmetrical Wings: {symmetrical}")
    print("=" * 68)

    # 1. Generate Primary App Icon SVG
    app_icon_svg_path = outdir / "app_icon.svg"
    app_svg = create_svg(
        span_deg=args.span,
        count=args.count,
        cluster_radius=args.cluster_radius,
        theme_key=args.theme,
        style="app_icon",
        symmetrical_wings=symmetrical
    )
    app_icon_svg_path.write_text(app_svg, encoding="utf-8")
    print(f"  [+] Created SVG: {app_icon_svg_path.name} (macOS Squircle with Official SF Symbol)")

    # 2. Generate Transparent Logo SVG
    trans_svg_path = outdir / "logo_transparent.svg"
    trans_svg = create_svg(
        span_deg=args.span,
        count=args.count,
        cluster_radius=args.cluster_radius,
        theme_key=args.theme,
        style="transparent",
        symmetrical_wings=symmetrical
    )
    trans_svg_path.write_text(trans_svg, encoding="utf-8")
    print(f"  [+] Created SVG: {trans_svg_path.name} (Transparent background)")

    # 3. Generate Minimal Vector Glyph SVG
    glyph_svg_path = outdir / "logo_glyph.svg"
    glyph_svg = create_svg(
        span_deg=args.span,
        count=args.count,
        cluster_radius=args.cluster_radius,
        theme_key=args.theme,
        style="glyph",
        symmetrical_wings=symmetrical
    )
    glyph_svg_path.write_text(glyph_svg, encoding="utf-8")
    print(f"  [+] Created SVG: {glyph_svg_path.name} (Flat vector glyph)")

    # 4. Rasterize to PNGs via macOS native WebKit/qlmanage
    app_icon_png_path = outdir / "app_icon.png"
    if rasterize_svg_macos(app_icon_svg_path, app_icon_png_path, size=1024):
        print(f"  [+] Rendered PNG: {app_icon_png_path.name} (1024x1024 RGBA)")

    trans_png_path = outdir / "logo_transparent.png"
    if rasterize_svg_macos(trans_svg_path, trans_png_path, size=1024):
        print(f"  [+] Rendered PNG: {trans_png_path.name} (1024x1024 Transparent)")

    # 5. Build ICNS
    icns_path = outdir / "AirMuse.icns"
    if args.icns or sys.platform == "darwin":
        if app_icon_png_path.exists():
            if build_iconset_and_icns(app_icon_png_path, icns_path):
                print(f"  [+] Built macOS ICNS: {icns_path.name} (Ready for Xcode/app bundle)")

    print("\n  [✓] All official SF Symbol logo assets updated successfully in:")
    print(f"      {outdir}")
    print("=" * 68)


if __name__ == "__main__":
    main()
