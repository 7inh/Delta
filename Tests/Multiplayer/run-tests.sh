#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
TASK_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/deltaswipe-multiplayer.XXXXXX")
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
swiftc -O -module-cache-path "$TASK_TEST_DIR/cache" Delta/Multiplayer/MultiplayerProtocol.swift Tests/Multiplayer/main.swift -o "$TASK_TEST_DIR/tests"
"$TASK_TEST_DIR/tests"
