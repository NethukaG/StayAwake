#!/bin/bash
# Builds a distributable StayAwake.dmg with a custom background image that
# visually walks a non-technical user through: (1) drag to Applications,
# (2) the one-time Gatekeeper "Open Anyway" step for this ad-hoc-signed build.
#
# This does NOT notarize the app (that needs a paid $99/yr Apple Developer
# account). Ad-hoc signing + this guided DMG is the free distribution path.
#
# Usage: ./make-dmg.sh
# Produces: StayAwake.dmg in the project root.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="StayAwake"
APP_PATH="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
VOL_NAME="Install ${APP_NAME}"
STAGE_DIR="$(mktemp -d)"
TMP_DMG="$(mktemp -u /tmp/${APP_NAME}-XXXXXX).dmg"

if [ ! -d "$APP_PATH" ]; then
    echo "==> ${APP_PATH} not found, building it first..."
    ./build.sh
fi

echo "==> Staging DMG contents..."
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
mkdir "$STAGE_DIR/.background"
cp dmg-assets/background.png "$STAGE_DIR/.background/background.png"

echo "==> Creating temporary read-write disk image..."
rm -f "$TMP_DMG"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE_DIR" -ov -format UDRW "$TMP_DMG" -fs HFS+ >/dev/null

echo "==> Mounting and laying out the Finder window..."
MOUNT_DIR="/Volumes/${VOL_NAME}"
hdiutil attach "$TMP_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet

# Spotlight indexing a freshly-written volume is what actually holds it busy for
# the detach later; tell it not to bother rather than fighting that after the fact.
touch "$MOUNT_DIR/.metadata_never_index"
mdutil -i off "$MOUNT_DIR" >/dev/null 2>&1 || true

osascript <<OSAEOF
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 560}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {165, 190}
        set position of item "Applications" of container window to {495, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
OSAEOF

echo "==> Unmounting..."
sync
sleep 1
# Finder can briefly hold the volume open right after the AppleScript closes its
# window. hdiutil detach alone can get stuck on this even with -force; when it
# does, fall back to diskutil unmountDisk (which clears the Finder-side lock)
# and then hdiutil detach the whole device to make sure it's actually released,
# not just unmounted -- a device left attached-but-unmounted still blocks the
# hdiutil convert step below with "Resource temporarily unavailable".
DISK_ID=$(diskutil info "$MOUNT_DIR" | awk -F': *' '/Part of Whole/{print $2}')
DETACHED=0
for attempt in 1 2 3; do
    if hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null; then
        DETACHED=1
        break
    fi
    sleep 2
done
if [ "$DETACHED" -ne 1 ] && [ -n "$DISK_ID" ]; then
    echo "==> Normal detach didn't clear it, forcing via diskutil..."
    diskutil unmountDisk force "$DISK_ID" || true
    sleep 2
    for attempt in 1 2 3 4 5; do
        if hdiutil detach "/dev/$DISK_ID" -force -quiet 2>/dev/null; then
            DETACHED=1
            break
        fi
        sleep 3
    done
fi
if [ "$DETACHED" -ne 1 ]; then
    echo "==> Could not fully detach /dev/$DISK_ID, aborting."
    exit 1
fi

# A forced unmount needs a beat before the backing image file is free to read again.
sleep 3

echo "==> Compressing final DMG..."
rm -f "$DMG_NAME"
CONVERTED=0
for attempt in 1 2 3; do
    if hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME" >/dev/null 2>/tmp/dmg_convert_err.log; then
        CONVERTED=1
        break
    fi
    sleep 3
done
if [ "$CONVERTED" -ne 1 ]; then
    echo "==> hdiutil convert failed after retries:"
    cat /tmp/dmg_convert_err.log
    exit 1
fi
rm -f "$TMP_DMG"
rm -rf "$STAGE_DIR"

echo "==> Built: $(pwd)/${DMG_NAME}"
