#!/bin/bash
# TabType build helper.
#   ./Scripts/build.sh eval     — build the tabtype-eval quality harness (release)
#   ./Scripts/build.sh app      — build TabType and bundle TabType.app into dist/
#
# The app is built with xcodebuild (asset catalog); tabtype-eval needs only
# `swift build`. llama.cpp ships its Metal kernels embedded in its framework.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${CONFIG:-Debug}"
DERIVED="$ROOT/.build-xcode"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"

build_scheme() {
    xcrun xcodebuild -scheme TabType -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" \
        -skipPackagePluginValidation build
}

cmd="${1:-app}"
case "$cmd" in
eval)
    swift build -c release --product tabtype-eval
    echo "Built: $ROOT/.build/release/tabtype-eval"
    ;;
app)
    build_scheme

    APP="$ROOT/dist/TabType.app"
    echo "Bundling $APP …"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

    # Executable
    cp "$PRODUCTS/TabType" "$APP/Contents/MacOS/TabType"

    # llama.cpp (binary XCFramework via TabTypeKit) — embed and point the
    # executable's rpath at Contents/Frameworks.
    mkdir -p "$APP/Contents/Frameworks"
    LLAMA_FW="$(find "$PRODUCTS" -maxdepth 2 -name "llama.framework" -type d | head -1)"
    if [ -n "$LLAMA_FW" ]; then
        cp -R "$LLAMA_FW" "$APP/Contents/Frameworks/"
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/TabType" 2>/dev/null || true
    else
        echo "WARNING: llama.framework not found in build products — the app will not launch." >&2
    fi

    # SwiftPM resource bundles (emoji.json, model catalog, fonts, …). These are
    # found at runtime via `Bundle.module`, whose accessor searches
    # Bundle.main.resourceURL (Contents/Resources) and the .app root — NOT
    # Contents/MacOS. So they go in Contents/Resources.
    find "$PRODUCTS" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

    # Info.plist & Icon
    cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
    if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
        cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    fi

    # Code signature. Prefer the stable self-signed "TabType Dev" identity (set up via
    # Scripts/setup-signing.sh) so macOS keeps Accessibility/Screen Recording grants
    # across rebuilds; fall back to ad-hoc if it isn't installed.
    IDENTITY="${SIGN_IDENTITY:-TabType Dev}"
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
        echo "Signing with \"$IDENTITY\" (stable — permissions persist)."
        codesign --force --deep --sign "$IDENTITY" \
            --identifier app.tabtype.TabType \
            --entitlements "$ROOT/Resources/TabType.entitlements" \
            "$APP"
    else
        echo "Signing ad-hoc (run Scripts/setup-signing.sh to persist permissions)."
        codesign --force --deep --sign - \
            --identifier app.tabtype.TabType \
            --entitlements "$ROOT/Resources/TabType.entitlements" \
            "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"
    fi

    echo "Done: $APP"
    echo "Run:  open \"$APP\"   (or: \"$APP/Contents/MacOS/TabType\" to see logs)"
    ;;
*)
    echo "usage: $0 {eval|app}" >&2
    exit 1
    ;;
esac
