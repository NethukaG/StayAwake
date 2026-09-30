#!/usr/bin/env bash
#
# Installs StayAwake without triggering macOS Gatekeeper's "Apple could not verify"
# warning.
#
# That warning isn't about this app specifically -- it's Gatekeeper's full identity
# check, and macOS only runs it on files carrying the com.apple.quarantine flag.
# Safari, Chrome, Mail, and Messages all attach that flag automatically to anything
# they download. curl does not. Piping this script into a Terminal, or running it
# after cloning the repo, installs the exact same app, just without that flag ever
# getting attached in the first place -- nothing is hidden, bypassed, or disabled,
# there is simply nothing for Gatekeeper to react to.
#
# If you'd rather download by hand in a browser, that still works -- see the
# "Direct download" section in README.md for the right-click-Open steps that
# path needs.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/NethukaG/StayAwake/main/install.sh | bash
#
set -euo pipefail

REPO="NethukaG/StayAwake"
DMG_URL="https://github.com/${REPO}/releases/latest/download/StayAwake.dmg"
APP_NAME="StayAwake"
TMP_DMG="$(mktemp -u "/tmp/${APP_NAME}-install-XXXXXX").dmg"

cleanup() {
    if [ -n "${MOUNT_DIR:-}" ] && [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    fi
    rm -f "$TMP_DMG"
}
trap cleanup EXIT

echo "==> Downloading ${APP_NAME}..."
curl -fsSL -o "$TMP_DMG" "$DMG_URL"

echo "==> Mounting..."
MOUNT_DIR=$(hdiutil attach "$TMP_DMG" -nobrowse -plist | \
    python3 -c "import sys, plistlib; d = plistlib.loads(sys.stdin.buffer.read()); print([e['mount-point'] for e in d['system-entities'] if 'mount-point' in e][0])")

if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR/${APP_NAME}.app" ]; then
    echo "==> Could not find ${APP_NAME}.app on the mounted image." >&2
    exit 1
fi

echo "==> Installing to /Applications..."
killall "$APP_NAME" 2>/dev/null || true
rm -rf "/Applications/${APP_NAME}.app"
cp -R "$MOUNT_DIR/${APP_NAME}.app" /Applications/

echo "==> Launching ${APP_NAME}..."
open "/Applications/${APP_NAME}.app"

echo "==> Done. ${APP_NAME} is installed and running, no Gatekeeper prompt needed."
