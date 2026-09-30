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
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Bundling Sparkle.framework (for Check for Updates)..."
# SwiftPM links the executable against Sparkle (see the rpath linker setting in
# Package.swift) but, unlike an Xcode build phase, never copies the framework itself
# anywhere -- it has to be copied into Contents/Frameworks by hand, here, or the app
# fails to launch (dyld: Library not loaded) on any machine but this one.
rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
cp -R ".build/release/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

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
