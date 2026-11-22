#!/usr/bin/env bash
# AirMuse macOS – Build & bundle script
# Usage:
#   bash scripts/build.sh            # debug build, bundle and launch
#   bash scripts/build.sh --release  # release build, bundle and launch
#   bash scripts/build.sh --no-open  # build + bundle, don't auto-launch
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="AirMuse"
BUNDLE_ID="com.airmuse.macos"

CONFIG="debug"
AUTO_OPEN=true

for arg in "$@"; do
  case "$arg" in
    --release)  CONFIG="release" ;;
    --no-open)  AUTO_OPEN=false ;;
  esac
done

cd "$PKG_DIR"

echo "🔨 Building AirMuse (${CONFIG}) …"
swift build -c "$CONFIG" 2>&1
echo "✅ Build succeeded (${CONFIG})"

# ── Locate the compiled binary ──────────────────────────────────────────────
if [[ "$CONFIG" == "release" ]]; then
  BIN="$PKG_DIR/.build/release/$APP_NAME"
else
  BIN="$PKG_DIR/.build/debug/$APP_NAME"
fi

# ── Create .app bundle structure ─────────────────────────────────────────────
APP_BUNDLE="$PKG_DIR/build/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN" "$MACOS_DIR/$APP_NAME"

# ── Write Info.plist ──────────────────────────────────────────────────────────
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>AirMuse</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleMusicUsageDescription</key>
  <string>AirMuse needs access to Apple Music to play and browse your music library.</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>AirMuse Callback</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>airmuse</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "📦 App bundle created at: $APP_BUNDLE"

if $AUTO_OPEN; then
  echo "🚀 Launching $APP_NAME …"
  open "$APP_BUNDLE"
fi
