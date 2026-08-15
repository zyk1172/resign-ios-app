#!/bin/bash
# test-macos-app.sh — 用 Xcode Beta 工具链对 Resign 执行单元测试（macOS）。
# 流程: xcodegen generate -> build-for-testing -> test-without-building。
# 用法: ./scripts/test-macos-app.sh
# 退出码: 0=全部通过；非 0=测试失败。
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
XCODE_APP=${XCODE_PATH:-}

if [ -z "$XCODE_APP" ]; then
    if [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]; then
        XCODE_APP=/Applications/Xcode.app
    elif [ -x /Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild ]; then
        XCODE_APP=/Applications/Xcode-beta.app
    else
        printf 'No usable Xcode installation was found. Set XCODE_PATH.\n' >&2
        exit 1
    fi
fi

XCODEBUILD="$XCODE_APP/Contents/Developer/usr/bin/xcodebuild"
if [ ! -x "$XCODEBUILD" ]; then
    printf 'Invalid XCODE_PATH: %s\n' "$XCODE_APP" >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    printf 'XcodeGen is required. Install it with: brew install xcodegen\n' >&2
    exit 1
fi

cd "$PROJECT_ROOT"
xcodegen generate

export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"

printf '\n==> build-for-testing (Debug, macOS) ...\n'
"$XCODEBUILD" \
    -project Resign.xcodeproj \
    -scheme Resign \
    -configuration Debug \
    -destination 'platform=macOS' \
    build-for-testing

printf '\n==> test-without-building ...\n'
"$XCODEBUILD" \
    -project Resign.xcodeproj \
    -scheme Resign \
    -configuration Debug \
    -destination 'platform=macOS' \
    test-without-building

printf '\n测试通过 ✅\n'
