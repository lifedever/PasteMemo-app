#!/bin/bash
# Shortcuts / Spotlight actions for a SwiftPM-built PasteMemo.app.
#
# Xcode generates `Metadata.appintents` (what Shortcuts reads to list an app's
# actions) in a build phase SwiftPM doesn't have. This file reproduces it:
#
#   source scripts/appintents-metadata.sh
#   swift build ... "${APPINTENTS_SWIFTC_FLAGS[@]}"      # every swift build call
#   ... assemble the .app ...
#   appintents_install_metadata "$BIN_PATH" "$ARCH" "$APP_BUNDLE"   # before codesign
#   appintents_install_strings "$APP_BUNDLE"
#
# The flags make the compiler emit `.swiftconstvalues` for types conforming to the
# App Intents protocols (the list is the one Xcode itself writes as
# `*_const_extract_protocols.json`); `appintentsmetadataprocessor` turns those into
# the metadata bundle. Failure is a warning, never a build failure: the app works
# without it, Shortcuts just doesn't list PasteMemo.

APPINTENTS_PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPINTENTS_SWIFTC_FLAGS=(
    -Xswiftc -emit-const-values
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
    -Xswiftc -Xfrontend -Xswiftc "$APPINTENTS_PKG_DIR/scripts/appintents-const-protocols.json"
)

appintents_install_metadata() {
    local BIN_PATH=$1 ARCH=$2 APP_BUNDLE=$3
    local MODULE=PasteMemo
    local OUT="$APP_BUNDLE/Contents/Resources"
    local WORK
    WORK=$(mktemp -d)
    rm -rf "$OUT/Metadata.appintents"

    find "$APPINTENTS_PKG_DIR/Sources" -name '*.swift' -not -path '*/MCPProxy/*' | sort > "$WORK/sources.txt"
    # Release (whole-module) builds write one <Module>.swiftconstvalues; debug builds
    # write one per file. Per-file leftovers of deleted sources are dropped so a
    # removed intent can't come back from a stale build directory.
    : > "$WORK/constvals.txt"
    local f name
    while IFS= read -r f; do
        name=$(basename "$f" .swiftconstvalues)
        if [ "$name" = "$MODULE" ] || grep -q "/${name}\$" "$WORK/sources.txt"; then
            echo "$f" >> "$WORK/constvals.txt"
        fi
    done < <(find "$BIN_PATH/$MODULE.build" -name '*.swiftconstvalues' 2>/dev/null)

    if [ ! -s "$WORK/constvals.txt" ]; then
        echo "  ⚠️  No .swiftconstvalues under $BIN_PATH/$MODULE.build (built without APPINTENTS_SWIFTC_FLAGS?) — app ships without Shortcuts actions."
        rm -rf "$WORK"
        return 0
    fi

    local SDK TOOLCHAIN XCODE_BUILD
    SDK=$(xcrun --sdk macosx --show-sdk-path)
    TOOLCHAIN=$(cd "$(dirname "$(xcrun --find swift)")/../.." && pwd)
    XCODE_BUILD=$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')

    if xcrun appintentsmetadataprocessor \
        --output "$OUT" \
        --toolchain-dir "$TOOLCHAIN" \
        --module-name "$MODULE" \
        --sdk-root "$SDK" \
        --xcode-version "${XCODE_BUILD:-unknown}" \
        --platform-family macOS \
        --deployment-target 14.0 \
        --target-triple "$ARCH-apple-macos14.0" \
        --source-file-list "$WORK/sources.txt" \
        --swift-const-vals-list "$WORK/constvals.txt" \
        > "$WORK/log" 2>&1 \
        && [ -f "$OUT/Metadata.appintents/extract.actionsdata" ]; then
        local COUNT
        COUNT=$(/usr/bin/python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("actions", {})))' \
            "$OUT/Metadata.appintents/extract.actionsdata" 2>/dev/null || echo "?")
        echo "  ✓ Shortcuts actions: $COUNT"
    else
        echo "  ⚠️  appintentsmetadataprocessor failed — app ships without Shortcuts actions:"
        tail -20 "$WORK/log" | sed 's/^/     /'
        rm -rf "$OUT/Metadata.appintents"
    fi
    rm -rf "$WORK"
}

# Action titles are read by Shortcuts from the app bundle's own lproj folders, so the
# AppIntents / AppShortcuts tables are copied there (the rest of the UI strings stay
# in the SwiftPM resource bundle).
appintents_install_strings() {
    local APP_BUNDLE=$1
    local lproj dest table
    for lproj in "$APPINTENTS_PKG_DIR"/Sources/Localization/*.lproj; do
        [ -d "$lproj" ] || continue
        dest="$APP_BUNDLE/Contents/Resources/$(basename "$lproj")"
        mkdir -p "$dest"
        for table in AppIntents AppShortcuts; do
            [ -f "$lproj/$table.strings" ] && cp -f "$lproj/$table.strings" "$dest/"
        done
    done
}
