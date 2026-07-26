#!/bin/bash

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

DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-"$PROJECT_ROOT/build/DerivedData"}
DEVELOPER_DIR="$XCODE_APP/Contents/Developer" "$XCODEBUILD" \
    -project Resign.xcodeproj \
    -scheme Resign \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Resign.app"
if [ ! -d "$APP_PATH" ]; then
    printf 'Build completed but Resign.app was not found.\n' >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$APP_PATH"
printf '%s\n' "$APP_PATH"
