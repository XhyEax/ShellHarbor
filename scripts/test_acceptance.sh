#!/bin/zsh

set -euo pipefail

repository_root=${0:A:h:h}
cd "$repository_root"

swift test

simulator_id=${SHELLHARBOR_IOS_TEST_DEVICE_ID:-}
if [[ -z "$simulator_id" ]]; then
    simulator_id=$(
        xcrun simctl list devices available |
            awk '/iPhone .*\([0-9A-F-]+\)/ {
                if (match($0, /\([0-9A-F-]+\)/)) {
                    print substr($0, RSTART + 1, RLENGTH - 2)
                    exit
                }
            }'
    )
fi

if [[ -z "$simulator_id" ]]; then
    print -u2 "没有找到可用的 iPhone Simulator。"
    exit 1
fi

xcrun simctl boot "$simulator_id" 2>/dev/null || true
xcrun simctl bootstatus "$simulator_id" -b

xcodebuild \
    -project ios/ShellHarborIOS.xcodeproj \
    -scheme ShellHarborIOS \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_id,arch=arm64" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    test
