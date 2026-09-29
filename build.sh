#!/usr/bin/env bash
#
# Builds StayAwake.app from source and (optionally) installs it to /Applications.
#
# Usage:
#   ./build.sh            Build StayAwake.app in this folder
#   ./build.sh --install  Build, then replace /Applications/StayAwake.app and launch it
#
set -euo pipefail

APP_NAME="StayAwake"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
MODE="${1:-}"

cd "$ROOT_DIR"

echo "==> Building release binary..."
swift build -c release

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Built: $APP_BUNDLE"

if [ "$MODE" = "--install" ]; then
  echo "==> Installing to /Applications..."
  killall "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "==> Installed and launched."
fi

cat <<'NOTE'

Note: this build is ad-hoc signed, not notarized by Apple (that costs a paid
Apple Developer account). The first time you open it from Finder, macOS
Gatekeeper will likely refuse a normal double-click. Right-click the app and
choose "Open" once -- after that, normal double-clicks work fine.
NOTE
