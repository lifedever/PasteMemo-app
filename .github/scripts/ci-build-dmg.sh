#!/bin/bash
# CI packaging: build both architecture DMGs, Developer ID sign, notarize and
# staple. Runs on GitHub Actions macos-26 (see .github/workflows/build-sign.yml);
# the repo root is the Swift package root.
#
# Required env (set up by the workflow):
#   SIGN_IDENTITY    — "Developer ID Application: ..." present in the keychain
#   NOTARY_KEY_PATH  — App Store Connect API key (.p8) file path
#   NOTARY_KEY_ID    — API key ID
#   NOTARY_ISSUER_ID — API key issuer ID
#
# Usage: ci-build-dmg.sh <version>
set -euo pipefail

APP_NAME="PasteMemo"
BUNDLE_ID="com.lifedever.pastememo"
VERSION="${1:?Usage: ci-build-dmg.sh <version>}"

: "${SIGN_IDENTITY:?SIGN_IDENTITY is required}"
: "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH is required}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required}"

# The version lands in Info.plist and DMG file names; reject anything that
# isn't a plain SemVer (optionally with a pre-release tag) before it reaches
# a shell interpolation.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "Error: '$VERSION' is not a valid version (expected e.g. 1.7.13 or 1.7.13-beta.1)" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RELEASE_DIR="$ROOT_DIR/.release"
ENTITLEMENTS="$ROOT_DIR/.github/scripts/release-entitlements.plist"

cd "$ROOT_DIR"

echo "📦 Building $APP_NAME v$VERSION (signed) ..."

# Clean every intermediate output, including the dmg staging dirs — a stale
# dmg-<arch>/PasteMemo.app would make cp -R nest the fresh app inside the old
# one (the v1.7.12-beta.6 incident).
mkdir -p "$RELEASE_DIR"
rm -f "$RELEASE_DIR/$APP_NAME-"*".dmg"
rm -rf "$RELEASE_DIR/$APP_NAME-arm64.app" "$RELEASE_DIR/$APP_NAME-x86_64.app"
rm -rf "$RELEASE_DIR/dmg-arm64" "$RELEASE_DIR/dmg-x86_64"

notarize_dmg() {
    local DMG=$1
    echo "  ☁️  Notarizing $(basename "$DMG") ..."
    local SUBMIT_JSON
    SUBMIT_JSON=$(xcrun notarytool submit "$DMG" \
        --key "$NOTARY_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" \
        --wait --output-format json)
    echo "$SUBMIT_JSON"
    local STATUS SUBMISSION_ID
    STATUS=$(echo "$SUBMIT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
    SUBMISSION_ID=$(echo "$SUBMIT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
    if [ "$STATUS" != "Accepted" ]; then
        echo "❌ Notarization failed (status: $STATUS). Fetching log:" >&2
        xcrun notarytool log "$SUBMISSION_ID" \
            --key "$NOTARY_KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" >&2 || true
        exit 1
    fi
    xcrun stapler staple "$DMG"
}

build_arch() {
    local ARCH=$1
    local APP_BUNDLE="$RELEASE_DIR/$APP_NAME-$ARCH.app"

    echo "  Building for $ARCH..."
    # -Osize: workaround for Swift 6.3 compiler crash in CopyPropagation pass (Xcode 26 beta)
    swift build -c release --arch "$ARCH" -Xswiftc -Osize 2>&1

    local BIN_PATH
    BIN_PATH=$(swift build -c release --arch "$ARCH" -Xswiftc -Osize --show-bin-path)
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    cp "$BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

    # Build and install the MCP CLI proxy alongside the main binary.
    swift build -c release --arch "$ARCH" -Xswiftc -Osize --product pastememo-mcp 2>&1
    cp "$BIN_PATH/pastememo-mcp" "$APP_BUNDLE/Contents/MacOS/pastememo-mcp"
    chmod +x "$APP_BUNDLE/Contents/MacOS/pastememo-mcp"

    cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 lifedever. All rights reserved.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>PasteMemo needs to communicate with Finder to save images to folders.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

    mkdir -p "$APP_BUNDLE/Contents/Resources"
    cp "Sources/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

    # Empty <lang>.lproj markers advertise supported localizations to macOS.
    # Enumerate them from the source tree instead of a hardcoded list.
    for lproj in Sources/Localization/*.lproj; do
        [ -d "$lproj" ] && mkdir -p "$APP_BUNDLE/Contents/Resources/$(basename "$lproj")"
    done

    # Copy every SwiftPM resource bundle (main target + deps like PermissionFlow;
    # missing one SIGTRAPs at Bundle.module — issue #34). Unlike the local
    # ad-hoc build these go under Contents/Resources, NOT the .app root:
    # anything outside Contents/ breaks the signature seal ("unsealed contents")
    # and notarization rejects it. Bundle.module's generated accessor checks
    # Bundle.main.resourceURL first, so the bundles are still found at runtime.
    for bundle in "$BIN_PATH"/*.bundle; do
        [ -d "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
    done

    # Sign inner → outer: the secondary executable first (app-level codesign
    # only seals the main executable), then the app bundle itself. Hardened
    # runtime + secure timestamp are notarization requirements.
    echo "  🔏 Signing ($ARCH) as: $SIGN_IDENTITY"
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/pastememo-mcp"
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
    codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE"

    local DMG_NAME="$APP_NAME-$VERSION-$ARCH.dmg"
    local DMG_DIR="$RELEASE_DIR/dmg-$ARCH"
    rm -rf "$DMG_DIR"   # 双保险：无论何种残留，打包前必须是干净目录
    mkdir -p "$DMG_DIR"
    cp -R "$APP_BUNDLE" "$DMG_DIR/$APP_NAME.app"
    ln -s /Applications "$DMG_DIR/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$RELEASE_DIR/$DMG_NAME"
    rm -rf "$DMG_DIR"

    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$RELEASE_DIR/$DMG_NAME"
    notarize_dmg "$RELEASE_DIR/$DMG_NAME"

    # Gatekeeper's own verdict on the stapled DMG — fail loudly here rather
    # than on a user's machine.
    spctl -a -t open --context context:primary-signature -v "$RELEASE_DIR/$DMG_NAME"

    echo "  ✅ $DMG_NAME (signed + notarized + stapled)"
}

build_arch arm64
build_arch x86_64

echo ""
echo "📦 Signed DMGs ready in $RELEASE_DIR/"
shasum -a 256 "$RELEASE_DIR/$APP_NAME-$VERSION-arm64.dmg" "$RELEASE_DIR/$APP_NAME-$VERSION-x86_64.dmg"
