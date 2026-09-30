#!/usr/bin/env bash
#
# Cuts a new signed, auto-updatable release: bumps the version, builds + packages
# the DMG, EdDSA-signs it for Sparkle, and adds the new entry to appcast.xml.
#
# It does NOT commit, tag, push, or upload to GitHub -- those are still separate,
# deliberate steps (see the printed instructions at the end), same as before.
#
# Usage: ./release.sh 1.12.0 "Short release notes shown in the update dialog."
#
# Requires sparkle-tools/bin/sign_update, from the Sparkle release tarball:
#   mkdir -p sparkle-tools && cd sparkle-tools
#   curl -fsSL -o Sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/latest/download/Sparkle-2.10.0.tar.xz
#   tar -xJf Sparkle.tar.xz && rm Sparkle.tar.xz
# (this folder is gitignored -- each machine that cuts a release downloads it once)

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?Usage: ./release.sh <version> \"<release notes>\"}"
NOTES="${2:-}"
REPO="NethukaG/StayAwake"
SIGN_UPDATE="sparkle-tools/bin/sign_update"

if [ ! -x "$SIGN_UPDATE" ]; then
    echo "==> $SIGN_UPDATE not found. See the Requires: note at the top of this script."
    exit 1
fi

echo "==> Bumping version to $VERSION in Info.plist..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Info.plist

echo "==> Building and packaging..."
./build.sh
./make-dmg.sh

echo "==> Signing StayAwake.dmg for Sparkle..."
SIGN_OUTPUT="$("$SIGN_UPDATE" StayAwake.dmg)"
echo "$SIGN_OUTPUT"
# sign_update prints: sparkle:edSignature="..." length="12345"
ED_SIG="$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [ -z "$ED_SIG" ] || [ -z "$LENGTH" ]; then
    echo "==> Could not parse sign_update output, aborting appcast update."
    exit 1
fi

PUB_DATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/StayAwake.dmg"

echo "==> Updating appcast.xml..."
python3 - "$VERSION" "$NOTES" "$PUB_DATE" "$DOWNLOAD_URL" "$ED_SIG" "$LENGTH" << 'PYEOF'
import sys, re, html

version, notes, pub_date, url, ed_sig, length = sys.argv[1:7]
path = "appcast.xml"

with open(path) as f:
    src = f.read()

notes_html = f"<ul><li>{html.escape(notes)}</li></ul>" if notes else "<ul><li>Bug fixes and improvements.</li></ul>"

item = f'''        <item>
            <title>Version {version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{version}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <description><![CDATA[{notes_html}]]></description>
            <enclosure
                url="{url}"
                sparkle:edSignature="{ed_sig}"
                length="{length}"
                type="application/octet-stream" />
        </item>
'''

marker = "<!-- RELEASES -->"
assert marker in src, "appcast.xml is missing the <!-- RELEASES --> marker"
src = src.replace(marker, marker + "\n" + item)

with open(path, "w") as f:
    f.write(src)
print("appcast.xml updated")
PYEOF

echo
echo "==> Done. Next steps (not automated, on purpose):"
echo "    git add -A && git commit -m 'Release v${VERSION}'"
echo "    git tag -f v${VERSION} HEAD && git push origin main && git push -f origin v${VERSION}"
echo "    gh release create v${VERSION} StayAwake.dmg --title 'StayAwake v${VERSION}' --notes '${NOTES}'"
echo "    (or gh release upload v${VERSION} StayAwake.dmg --clobber for an existing release)"
