#!/bin/bash
# DeltaSwipe — apply local patches needed to build with Xcode 27 and your own
# Apple Developer team. Run once after `git submodule update --init --recursive`.
#
# Usage: Scripts/setup-signing.sh [YOUR_TEAM_ID]
# (default team: NK8KQXCK9X)

set -e

TEAM="${1:-NK8KQXCK9X}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo ">> Replacing upstream team with $TEAM in all subprojects"
find . -name "project.pbxproj" -not -path "./.git/*" -print0 | while IFS= read -r -d '' f; do
    sed -i '' -E "s/6XVY5G3U44/$TEAM/g; s/DEVELOPMENT_TEAM = (1[0-4]|[0-9])\.0/DEVELOPMENT_TEAM = 15.0/g" "$f"
done

echo ">> Done. Open Delta.xcworkspace, pick the Delta scheme and your device, then build."
echo "   (Submodule working trees are patched in place; commit inside each submodule"
echo "    and push your own forks if you want the fixes reproducible for others.)"
