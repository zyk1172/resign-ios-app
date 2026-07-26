#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-"$PROJECT_ROOT/build/DerivedData"}
SOURCE_APP="$DERIVED_DATA_PATH/Build/Products/Release/Resign.app"
DESTINATION_APP=/Applications/Resign.app
STAGING_APP=/Applications/.Resign.installing.app
BACKUP_APP="/tmp/Resign.previous.$$.app"

DERIVED_DATA_PATH="$DERIVED_DATA_PATH" "$SCRIPT_DIR/build-macos-app.sh"

if [ "$(/usr/bin/defaults read "$SOURCE_APP/Contents/Info.plist" CFBundleIdentifier)" != "com.resign.app" ]; then
    printf 'Refusing to install an app with an unexpected bundle identifier.\n' >&2
    exit 1
fi

if /usr/bin/pgrep -x Resign >/dev/null 2>&1; then
    /usr/bin/pkill -TERM -x Resign || true
    sleep 1
fi

if [ -e "$STAGING_APP" ]; then
    /bin/rm -rf -- "$STAGING_APP"
fi
/usr/bin/ditto "$SOURCE_APP" "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict "$STAGING_APP"

if [ -e "$DESTINATION_APP" ]; then
    /bin/mv "$DESTINATION_APP" "$BACKUP_APP"
fi

if /bin/mv "$STAGING_APP" "$DESTINATION_APP"; then
    if [ -e "$BACKUP_APP" ]; then
        /bin/rm -rf -- "$BACKUP_APP"
    fi
else
    if [ -e "$BACKUP_APP" ]; then
        /bin/mv "$BACKUP_APP" "$DESTINATION_APP"
    fi
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$DESTINATION_APP"
/usr/bin/open "$DESTINATION_APP"
printf 'Installed %s\n' "$DESTINATION_APP"
