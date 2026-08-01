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
APP_BUNDLE="$DIST_DIR/LauncherApp.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

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
    <string>LauncherApp</string>
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

# 3. Ad-hoc codesign
codesign --force --deep --sign - "$APP_BUNDLE"

echo "[pkg] done: $APP_BUNDLE"
