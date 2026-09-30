#!/bin/bash
# End-to-end local-ROM session check across two booted simulators:
# a protocol-level mini host plays against the REAL guest MultiplayerSession stack
# (browse/join, digest negotiation, state load, deterministic replay, pause/resume).
# Both apps must stay foreground, so they run on separate simulators.
# Usage: run-ios-integration.sh <host simulator UDID> <guest simulator UDID> <Debug-iphonesimulator products directory> [code]
set -euo pipefail
cd "$(dirname "$0")/../.."
HOST_SIM=${1:?Pass the host simulator UDID}
GUEST_SIM=${2:?Pass the guest simulator UDID}
PRODUCTS=${3:?Pass the workspace simulator products directory}
CODE=${4:-$((100000 + RANDOM % 900000))}
DIR=$(mktemp -d "${TMPDIR:-/tmp}/deltaswipe-integration.XXXXXX")
trap 'rm -rf "$DIR"' EXIT
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

build_app() {
    local NAME=$1 BUNDLE=$2 SIM=$3; shift 3
    local APP="$DIR/$NAME.app"
    mkdir -p "$APP/Frameworks"
    python3 - "$APP/Info.plist" "$NAME" "$BUNDLE" <<'PY'
import plistlib, sys
plistlib.dump({'CFBundleExecutable': sys.argv[2], 'CFBundleIdentifier': sys.argv[3],
              'CFBundleName': sys.argv[2], 'CFBundleVersion': '1', 'CFBundlePackageType': 'APPL',
              'NSBonjourServices': ['_deltaswipe._tcp', '_deltaswipe-r._tcp'],
              'NSLocalNetworkUsageDescription': 'Test nearby multiplayer between simulators.',
              'MinimumOSVersion': '17.4', 'UIDeviceFamily': [1, 2], 'UILaunchScreen': {}}, open(sys.argv[1], 'wb'))
PY
    for FRAMEWORK in DeltaCore NESDeltaCore ZIPFoundation; do
        cp -R "$PRODUCTS/Delta.app/Frameworks/$FRAMEWORK.framework" "$APP/Frameworks/"
    done
    xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.4-simulator -sdk "$SDK" \
        -module-cache-path "$DIR/cache" -F "$PRODUCTS" -framework DeltaCore -framework NESDeltaCore \
        -Xlinker -rpath -Xlinker @executable_path/Frameworks "$@" -o "$APP/$NAME" > "$DIR/$NAME-build.log" 2>&1 || { cat "$DIR/$NAME-build.log"; return 1; }
    codesign --force --sign - "$APP" >/dev/null 2>&1
    xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl install "$SIM" "$APP"
}

build_app Host com.deltaswipe.tests.inthost "$HOST_SIM" \
    Delta/Multiplayer/MultiplayerProtocol.swift Delta/Multiplayer/MultiplayerTransport.swift \
    Delta/Multiplayer/MultiplayerLocalGame.swift Tests/Multiplayer/TestROM.swift Tests/Multiplayer/IntegrationHost/main.swift
build_app Guest com.deltaswipe.tests.intguest "$GUEST_SIM" \
    Delta/Multiplayer/MultiplayerProtocol.swift Delta/Multiplayer/MultiplayerTransport.swift \
    Delta/Multiplayer/MultiplayerMedia.swift Delta/Multiplayer/MultiplayerControllers.swift \
    Delta/Multiplayer/MultiplayerLocalGame.swift Delta/Multiplayer/MultiplayerSession.swift \
    Tests/Multiplayer/TestROM.swift Tests/Multiplayer/IntegrationGuest/main.swift

HOST_DATA=$(xcrun simctl get_app_container "$HOST_SIM" com.deltaswipe.tests.inthost data)
GUEST_DATA=$(xcrun simctl get_app_container "$GUEST_SIM" com.deltaswipe.tests.intguest data)
rm -f "$HOST_DATA/Documents/result.txt" "$HOST_DATA/Documents/status.txt" "$GUEST_DATA/Documents/result.txt"
xcrun simctl launch "$HOST_SIM" com.deltaswipe.tests.inthost -code "$CODE" >/dev/null
for _ in $(seq 1 20); do [[ -f "$HOST_DATA/Documents/status.txt" ]] && break; sleep 1; done
[[ -f "$HOST_DATA/Documents/status.txt" ]] || { echo "HOST never started listening"; exit 1; }
xcrun simctl launch "$GUEST_SIM" com.deltaswipe.tests.intguest -code "$CODE" >/dev/null

for _ in $(seq 1 45); do
    [[ -f "$HOST_DATA/Documents/result.txt" && -f "$GUEST_DATA/Documents/result.txt" ]] && break
    sleep 1
done
HOST_RESULT=$(cat "$HOST_DATA/Documents/result.txt" 2>/dev/null || echo "HOST result missing")
GUEST_RESULT=$(cat "$GUEST_DATA/Documents/result.txt" 2>/dev/null || echo "GUEST result missing")
echo "$HOST_RESULT"
echo "$GUEST_RESULT"
[[ "$HOST_RESULT" == HOST_PASS* ]]
[[ "$GUEST_RESULT" == GUEST_PASS* ]]
