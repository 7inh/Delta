#!/bin/bash
# Usage: run-ios-smoke.sh <booted simulator UDID> <Debug-iphonesimulator products directory>
set -euo pipefail
cd "$(dirname "$0")/../.."
TASK_SIMULATOR=${1:?Pass a booted simulator UDID}
TASK_PRODUCTS=${2:?Pass the workspace simulator products directory}
TASK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/deltaswipe-smoke.XXXXXX")
trap 'rm -rf "$TASK_DIR"' EXIT
TASK_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
for TASK_KIND in Media Controller Replica; do
    TASK_BUNDLE="com.deltaswipe.tests.$(printf %s "$TASK_KIND" | tr '[:upper:]' '[:lower:]')"
    TASK_APP="$TASK_DIR/$TASK_KIND.app"
    mkdir -p "$TASK_APP"
    python3 - "$TASK_APP/Info.plist" "$TASK_KIND" "$TASK_BUNDLE" <<'PY'
import plistlib, sys
plistlib.dump({'CFBundleExecutable': sys.argv[2], 'CFBundleIdentifier': sys.argv[3],
              'CFBundleName': sys.argv[2], 'CFBundleVersion': '1', 'CFBundlePackageType': 'APPL',
              'MinimumOSVersion': '17.4', 'UIDeviceFamily': [1, 2], 'UILaunchScreen': {}}, open(sys.argv[1], 'wb'))
PY
    TASK_SOURCES=(Delta/Multiplayer/MultiplayerProtocol.swift)
    TASK_FLAGS=(-module-cache-path "$TASK_DIR/cache")
    if [[ "$TASK_KIND" == Media ]]; then
        TASK_SOURCES+=(Delta/Multiplayer/MultiplayerMedia.swift Tests/Multiplayer/MediaSmoke/main.swift)
    else
        TASK_SOURCES+=(Delta/Multiplayer/MultiplayerControllers.swift Tests/Multiplayer/ControllerSmoke/main.swift)
        if [[ "$TASK_KIND" == Replica ]]; then
            TASK_SOURCES=(Delta/Multiplayer/MultiplayerProtocol.swift Delta/Multiplayer/MultiplayerLocalGame.swift Tests/Multiplayer/TestROM.swift Tests/Multiplayer/ReplicaSmoke/main.swift)
        fi
        TASK_FLAGS+=(-F "$TASK_PRODUCTS" -framework DeltaCore -framework NESDeltaCore -Xlinker -rpath -Xlinker @executable_path/Frameworks)
        mkdir -p "$TASK_APP/Frameworks"
        for TASK_FRAMEWORK in DeltaCore NESDeltaCore ZIPFoundation; do
            cp -R "$TASK_PRODUCTS/Delta.app/Frameworks/$TASK_FRAMEWORK.framework" "$TASK_APP/Frameworks/"
        done
    fi
    xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.4-simulator -sdk "$TASK_SDK" \
        "${TASK_FLAGS[@]}" "${TASK_SOURCES[@]}" -o "$TASK_APP/$TASK_KIND"
    codesign --force --sign - "$TASK_APP"
    xcrun simctl terminate "$TASK_SIMULATOR" "$TASK_BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl install "$TASK_SIMULATOR" "$TASK_APP"
    TASK_CONTAINER=$(xcrun simctl get_app_container "$TASK_SIMULATOR" "$TASK_BUNDLE" data)
    rm -f "$TASK_CONTAINER/Documents/result.txt"
    xcrun simctl launch "$TASK_SIMULATOR" "$TASK_BUNDLE"
    for ((TASK_ATTEMPT=0; TASK_ATTEMPT<20; TASK_ATTEMPT++)); do
        [[ -f "$TASK_CONTAINER/Documents/result.txt" ]] && break
        sleep 1
    done
    cat "$TASK_CONTAINER/Documents/result.txt"
    if [[ "$TASK_KIND" == Media ]]; then
        rg -q MEDIA_SMOKE_PASS "$TASK_CONTAINER/Documents/result.txt"
    elif [[ "$TASK_KIND" == Controller ]]; then
        rg -q 'CONTROLLER_SMOKE 10/10 passed' "$TASK_CONTAINER/Documents/result.txt"
    else
        rg -q 'REPLICA_SMOKE 13/13 passed' "$TASK_CONTAINER/Documents/result.txt"
    fi
done
