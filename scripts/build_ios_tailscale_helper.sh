#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_ROOT="$PROJECT_ROOT/ios/GoHelper"
OUTPUT_ROOT="$PROJECT_ROOT/ios/Frameworks"

if ! command -v go >/dev/null 2>&1 || ! command -v gomobile >/dev/null 2>&1; then
    print -u2 "Go 1.26+ and gomobile are required to build the iOS Tailscale helper."
    exit 1
fi

mkdir -p "$OUTPUT_ROOT"
cd "$HELPER_ROOT"
go mod download
gomobile bind \
    -target=ios,iossimulator \
    -iosversion=17.0 \
    -prefix=SH \
    -trimpath \
    -o "$OUTPUT_ROOT/ShellHarborTS.xcframework" \
    ./shellharborts
