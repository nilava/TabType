#!/bin/bash
# TabType release packager.
#   ./Scripts/release.sh <version>       e.g. ./Scripts/release.sh 0.1.0
#
# Builds a signed .app, verifies it is signed with the STABLE self-signed identity
# (never ad-hoc — ad-hoc changes the code identity every build, which resets users'
# Accessibility/Screen Recording grants on every update), then packages a
# drag-to-Applications DMG for the GitHub Releases page.
#
# No Apple Developer account / no notarization: the DMG is signed but unnotarized,
# so first-run users must approve it in System Settings ▸ Privacy & Security
# ("Open Anyway"). See README ▸ Install and RELEASING.md.
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then echo "usage: $0 <version>   (e.g. 0.1.0)" >&2; exit 1; fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/dist/TabType.app"
PLIST="$ROOT/Resources/Info.plist"
IDENTITY="${SIGN_IDENTITY:-TabType Dev}"

# 1) Stamp version + bump build number.
CURRENT_BUILD="$(plutil -extract CFBundleVersion raw "$PLIST" 2>/dev/null || echo 0)"
NEXT_BUILD=$(( CURRENT_BUILD + 1 ))
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$NEXT_BUILD" "$PLIST"
echo "Version $VERSION (build $NEXT_BUILD)"

# 2) Build the bundle.
CONFIG=Release ./Scripts/build.sh app

# 3) Refuse to ship an ad-hoc build (would reset user permissions each update).
SIGINFO="$(codesign -dvv "$APP" 2>&1 || true)"
if echo "$SIGINFO" | grep -q "Signature=adhoc"; then
    echo "ERROR: $APP is ad-hoc signed. Install the stable \"$IDENTITY\" identity" >&2
    echo "       (Scripts/setup-signing.sh) and re-run — ad-hoc builds reset users'" >&2
    echo "       Accessibility/Screen Recording grants on every update." >&2
    exit 1
fi
echo "Signed with a stable identity ✔"

# 4) Package a drag-to-Applications DMG (hdiutil — no external tooling).
STAGING="$ROOT/dist/dmg"
DMG="$ROOT/dist/TabType-$VERSION.dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "TabType $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

# 5) Report.
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(du -h "$DMG" | awk '{print $1}')"
echo ""
echo "Built: $DMG ($SIZE)"
echo "SHA-256: $SHA"
echo ""
echo "Next steps:"
echo "  1. git tag v$VERSION && git push --tags"
echo "  2. Create a GitHub Release for v$VERSION and upload the DMG above."
echo "  3. Paste the install notes from RELEASING.md (Gatekeeper 'Open Anyway')."
