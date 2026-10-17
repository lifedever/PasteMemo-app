#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PasteMemo"
EXECUTABLE_NAME="PasteMemo"
DEFAULT_BUNDLE_ID="com.lifedever.pastememo"
MIN_SYSTEM_VERSION="14.0"

ARCH="${ARCH:-$(uname -m)}"
CONFIGURATION="${CONFIGURATION:-release}"
BUNDLE_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
ICON_FILE="$ROOT_DIR/Sources/Resources/AppIcon.icns"

resolve_version() {
  if [[ -n "${VERSION:-}" ]]; then
    printf '%s\n' "$VERSION"
    return 0
  fi

  if git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    local tag
    tag="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
    tag="${tag#v}"
    if [[ -n "$tag" ]]; then
      printf '%s\n' "$tag"
      return 0
    fi
  fi

  echo "VERSION is not set, and no git tag was found." >&2
  echo "Use: make package VERSION=1.2.3" >&2
  exit 1
}

VERSION="$(resolve_version)"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-${ARCH}.dmg"
STAGING_DIR="$DIST_DIR/.dmg-staging"

# Shortcuts / Spotlight actions: compiler flags + metadata step (see the script).
source "$ROOT_DIR/scripts/appintents-metadata.sh"

# --build-system native, same as ci-build-dmg.sh: Xcode 27 / Swift 6.4's default
# swiftbuild backend writes the deployment target into LC_BUILD_VERSION's sdk field
# (the app then renders with macOS 14-era window chrome) and puts its products under
# .build/out/Products/ instead. The bin path is asked from SwiftPM, never hard-coded:
# with a stale hard-coded path the old binary left there gets packaged without a
# single error.
SWIFT_BUILD=(swift build -c "$CONFIGURATION" --arch "$ARCH" --build-system native)
BUILD_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
PRODUCT_BINARY="$BUILD_DIR/$EXECUTABLE_NAME"

printf '[package] building %s %s (%s)\n' "$APP_NAME" "$VERSION" "$ARCH"
# Removed first so a build that produced nothing fails here instead of shipping the
# previous binary.
rm -f "$PRODUCT_BINARY"
"${SWIFT_BUILD[@]}" "${APPINTENTS_SWIFTC_FLAGS[@]}"

if [[ ! -x "$PRODUCT_BINARY" ]]; then
  echo "Built binary not found: $PRODUCT_BINARY" >&2
  exit 1
fi
if ! lipo -archs "$PRODUCT_BINARY" | tr ' ' '\n' | grep -qx "$ARCH"; then
  echo "Built binary is $(lipo -archs "$PRODUCT_BINARY"), expected $ARCH: $PRODUCT_BINARY" >&2
  exit 1
fi
EXPECTED_SDK="$(xcrun --show-sdk-version)"
LINKED_SDK="$(otool -l "$PRODUCT_BINARY" | awk '/LC_BUILD_VERSION/{f=1} f && /sdk/{print $2; exit}')"
if [[ "$LINKED_SDK" != "$EXPECTED_SDK" ]]; then
  echo "LC_BUILD_VERSION sdk=$LINKED_SDK, expected $EXPECTED_SDK (legacy window chrome otherwise)" >&2
  exit 1
fi

# Glob every *.bundle produced by SwiftPM resource targets. Hard-coding names
# silently misses new SPM dependencies and crashes Bundle.module at runtime.
RESOURCE_BUNDLES=("$BUILD_DIR"/*.bundle)
if [[ ! -d "${RESOURCE_BUNDLES[0]}" ]]; then
  echo "No SwiftPM resource bundles found in $BUILD_DIR" >&2
  exit 1
fi

if [[ ! -f "$ICON_FILE" ]]; then
  echo "App icon not found: $ICON_FILE" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$STAGING_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DIST_DIR"

cp "$PRODUCT_BINARY" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ICON_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"
for bundle in "${RESOURCE_BUNDLES[@]}"; do
  cp -R "$bundle" "$APP_DIR/"
done
# lproj per language (also carries the Shortcuts action titles), then the Shortcuts
# metadata. Before codesign.
appintents_install_strings "$APP_DIR"
appintents_install_metadata "$BUILD_DIR" "$ARCH" "$APP_DIR"

CURRENT_YEAR="$(date +%Y)"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM_VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © ${CURRENT_YEAR} lifedever. All rights reserved.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>PasteMemo needs to communicate with Finder to save images to folders.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
EOF

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  printf '[package] codesigning app bundle\n'
  codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP_DIR"
fi

mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"

printf '[package] creating dmg %s\n' "$(basename "$DMG_PATH")"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGING_DIR"

printf '[package] app: %s\n' "$APP_DIR"
printf '[package] dmg: %s\n' "$DMG_PATH"
