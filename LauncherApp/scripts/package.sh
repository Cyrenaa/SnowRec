#!/bin/bash
# package.sh — Assemble LauncherApp.app bundle and ad-hoc sign it.
#
# Steps:
#   1. swift build -c release (in the LauncherApp package dir)
#   2. Assemble dist/LauncherApp.app with release binary, PkgInfo, Info.plist
#   3. Ad-hoc codesign (--force --deep --sign -)
#
# SnowRecRepoRoot (repo root) is resolved relative to this script's location
# so the script is location-independent. Bundle id is the stable
# com.snowrec.launcher (notifications + `tccutil reset` depend on it).

set -euo pipefail

# LauncherApp/ dir (this script lives in LauncherApp/scripts/package.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Repo root = LauncherApp/../.. (SnowRecRepoRoot injected into Info.plist)
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DIST_DIR="$APP_DIR/dist"
APP_BUNDLE="$DIST_DIR/SnowRec.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

# App icon source (512x512 PNG). Override via ICON_PNG=/path/to.png.
ICON_PNG="${ICON_PNG:-/Users/wyn/Documents/ic.png}"

echo "[pkg] repo root: $REPO_ROOT"
echo "[pkg] building release binary..."

# 1. Build release binary
(cd "$APP_DIR" && swift build -c release)

BIN_SRC="$APP_DIR/.build/release/LauncherApp"
if [[ ! -x "$BIN_SRC" ]]; then
  echo "[pkg] ERROR: release binary not found at $BIN_SRC" >&2
  exit 1
fi

# 2. Assemble the .app bundle
rm -rf "$APP_BUNDLE"
rm -rf "$DIST_DIR/LauncherApp.app"   # legacy bundle name from before the rename
mkdir -p "$MACOS_DIR"
cp "$BIN_SRC" "$MACOS_DIR/LauncherApp"

# PkgInfo: 4-char signature
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.snowrec.launcher</string>
    <key>CFBundleName</key>
    <string>SnowRec</string>
    <key>CFBundleIconFile</key>
    <string>SnowRec</string>
    <key>CFBundleExecutable</key>
    <string>LauncherApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>SnowRecRepoRoot</key>
    <string>${REPO_ROOT}</string>
</dict>
</plist>
PLIST

# 3. App icon: downscale ICON_PNG into an .icns (skipped gracefully when missing)
if [[ -f "$ICON_PNG" ]]; then
    RESOURCES_DIR="$CONTENTS_DIR/Resources"
    mkdir -p "$RESOURCES_DIR"
    ICONSET_DIR="$DIST_DIR/icon.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"
    for spec in "icon_16x16.png 16" "icon_16x16@2x.png 32" "icon_32x32.png 32" \
                "icon_32x32@2x.png 64" "icon_128x128.png 128" "icon_128x128@2x.png 256" \
                "icon_256x256.png 256" "icon_256x256@2x.png 512" "icon_512x512.png 512" \
                "icon_512x512@2x.png 1024"; do
        name="${spec% *}"
        size="${spec#* }"
        sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/$name" >/dev/null
    done
    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/SnowRec.icns"
    rm -rf "$ICONSET_DIR"
    echo "[pkg] app icon: $RESOURCES_DIR/SnowRec.icns (from $ICON_PNG)"
else
    echo "[pkg] WARN: icon source $ICON_PNG not found; app icon skipped" >&2
fi

# 4. Ad-hoc codesign
codesign --force --deep --sign - "$APP_BUNDLE"

echo "[pkg] done: $APP_BUNDLE"
