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

# ── 1. Stop currently running AirMuse process ────────────────────────────────
stop_running_app() {
  local pids
  pids="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
  if [[ -z "$pids" ]]; then
    # Fallback for restricted shells where pgrep cannot query sysmond
    killall -TERM "$APP_NAME" >/dev/null 2>&1 && sleep 0.5 || true
    killall -KILL "$APP_NAME" >/dev/null 2>&1 || true
    return 0
  fi

  echo "🛑 Stopping running $APP_NAME (PID: $(echo "$pids" | tr '\n' ' ' | sed 's/ *$//')) …"
  pkill -TERM -x "$APP_NAME" >/dev/null 2>&1 || true

  local waited=0
  while pgrep -x "$APP_NAME" >/dev/null 2>&1 && [[ "$waited" -lt 15 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "⚠️ Force killing $APP_NAME …"
    pkill -KILL -x "$APP_NAME" >/dev/null 2>&1 || true
    sleep 0.2
  fi

  echo "✅ Previous $APP_NAME process stopped"
}

stop_running_app

# ── 2. Build & bundle ────────────────────────────────────────────────────────
echo "🔨 Building AirMuse (${CONFIG}) …"
swift build --disable-sandbox -c "$CONFIG" --product "$APP_NAME" 2>&1
echo "✅ Build succeeded (${CONFIG})"

# ── Locate the compiled binary & resource bundles ────────────────────────────
BIN_DIR="$(swift build --disable-sandbox -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "❌ Binary not found at $BIN"
  exit 1
fi

# ── Create .app bundle structure ─────────────────────────────────────────────
APP_BUNDLE="$PKG_DIR/build/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN" "$MACOS_DIR/$APP_NAME"

# Copy SwiftPM resource bundles (e.g., AirMuse_DesignSystem.bundle)
for bundle in "$BIN_DIR"/*.bundle; do
  if [[ -d "$bundle" ]]; then
    cp -R "$bundle" "$RESOURCES_DIR/"
    echo "📎 Bundled resource: $(basename "$bundle")"
  fi
done

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

# Ad-hoc sign bundle so macOS allows launching when double-clicked
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

# Refresh LaunchServices registration so macOS does not reuse a stale bundle cache
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "📦 App bundle created at: $APP_BUNDLE"

# ── 3. Launch ────────────────────────────────────────────────────────────────
if $AUTO_OPEN; then
  echo "🚀 Launching $APP_NAME …"
  open -n "$APP_BUNDLE"
fi
