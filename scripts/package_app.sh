#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build/app-package"
APP_PATH="$PROJECT_ROOT/dist/ShellHarbor.app"
CONTENTS_PATH="$APP_PATH/Contents"
ICONSET_PATH="$BUILD_ROOT/AppIcon.iconset"
BASE_ICON="$BUILD_ROOT/AppIcon-1024.png"

cd "$PROJECT_ROOT"
swift build -c release
RELEASE_BIN_PATH="$(swift build -c release --show-bin-path)"

rm -rf "$BUILD_ROOT" "$APP_PATH"
rm -f "$PROJECT_ROOT/dist/sh-cli"
mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources" "$ICONSET_PATH"
cp "$RELEASE_BIN_PATH/ShellHarbor" "$CONTENTS_PATH/MacOS/ShellHarbor"
cp "$RELEASE_BIN_PATH/shcli" "$CONTENTS_PATH/MacOS/shcli"
cp "$RELEASE_BIN_PATH/shcli" "$PROJECT_ROOT/dist/shcli"
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS_PATH/Info.plist"
cp -R \
  "$RELEASE_BIN_PATH/SwiftTerm_SwiftTerm.bundle" \
  "$CONTENTS_PATH/Resources/SwiftTerm_SwiftTerm.bundle"

swift "$PROJECT_ROOT/Tools/GenerateIcon.swift" "$BASE_ICON"
sips -z 16 16 "$BASE_ICON" --out "$ICONSET_PATH/icon_16x16.png" >/dev/null
sips -z 32 32 "$BASE_ICON" --out "$ICONSET_PATH/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$BASE_ICON" --out "$ICONSET_PATH/icon_32x32.png" >/dev/null
sips -z 64 64 "$BASE_ICON" --out "$ICONSET_PATH/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$BASE_ICON" --out "$ICONSET_PATH/icon_128x128.png" >/dev/null
sips -z 256 256 "$BASE_ICON" --out "$ICONSET_PATH/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$BASE_ICON" --out "$ICONSET_PATH/icon_256x256.png" >/dev/null
sips -z 512 512 "$BASE_ICON" --out "$ICONSET_PATH/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$BASE_ICON" --out "$ICONSET_PATH/icon_512x512.png" >/dev/null
cp "$BASE_ICON" "$ICONSET_PATH/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_PATH" -o "$CONTENTS_PATH/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP_PATH"
codesign --force --sign - "$PROJECT_ROOT/dist/shcli"
echo "$APP_PATH"
