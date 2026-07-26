#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-"$PROJECT_ROOT/build/DerivedData"}
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Resign.app"
DIST_DIR=${DIST_DIR:-"$PROJECT_ROOT/dist"}
STAGING_DIR=$(/usr/bin/mktemp -d /tmp/resign-dmg.XXXXXX)
MOUNT_DIR=$(/usr/bin/mktemp -d /tmp/resign-mount.XXXXXX)
MOUNTED=0

cleanup() {
    if [ "$MOUNTED" -eq 1 ]; then
        /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    /bin/rm -rf -- "$STAGING_DIR" "$MOUNT_DIR"
}
trap cleanup EXIT

"$SCRIPT_DIR/build-macos-app.sh" >/dev/null

if [ ! -d "$APP_PATH" ]; then
    printf 'Resign.app was not found after the Release build.\n' >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
    printf 'The built app does not contain a valid version.\n' >&2
    exit 1
fi

SIGNING_IDENTITY_VALUE=${SIGNING_IDENTITY:-}
if [ -z "$SIGNING_IDENTITY_VALUE" ]; then
    SIGNING_IDENTITY_VALUE=$(
        /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
            | /usr/bin/awk '/Developer ID Application/ && !found { print $2; found=1 }'
    )
fi

SIGNING_MODE=ad-hoc
if [ -n "$SIGNING_IDENTITY_VALUE" ]; then
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY_VALUE" \
        "$APP_PATH"
    SIGNING_MODE=developer-id
fi

/usr/bin/codesign --verify --deep --strict "$APP_PATH"

/bin/mkdir -p "$DIST_DIR"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/Resign.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

DMG_NAME="Resign-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
/bin/rm -f -- "$DMG_PATH" "$CHECKSUM_PATH"

/usr/bin/hdiutil create \
    -volname "Resign $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH" >/dev/null

if [ "$SIGNING_MODE" = developer-id ]; then
    /usr/bin/codesign \
        --force \
        --timestamp \
        --sign "$SIGNING_IDENTITY_VALUE" \
        "$DMG_PATH"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ "$SIGNING_MODE" != developer-id ]; then
        printf 'NOTARY_PROFILE requires a Developer ID Application identity.\n' >&2
        exit 1
    fi
    /usr/bin/xcrun notarytool submit \
        "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    /usr/bin/xcrun stapler staple "$DMG_PATH"
fi

/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null
/usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_DIR" \
    "$DMG_PATH" >/dev/null
MOUNTED=1

if [ ! -d "$MOUNT_DIR/Resign.app" ] || [ ! -L "$MOUNT_DIR/Applications" ]; then
    printf 'The mounted DMG does not contain the expected files.\n' >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$MOUNT_DIR/Resign.app"
MOUNTED_VERSION=$(
    /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' \
        "$MOUNT_DIR/Resign.app/Contents/Info.plist"
)
if [ "$MOUNTED_VERSION" != "$VERSION" ]; then
    printf 'The mounted app version does not match the build.\n' >&2
    exit 1
fi

/usr/bin/hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=0

(
    cd "$DIST_DIR"
    /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)

printf 'version=%s\n' "$VERSION"
printf 'build=%s\n' "$BUILD"
printf 'signing-mode=%s\n' "$SIGNING_MODE"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    printf 'notarized=yes\n'
else
    printf 'notarized=no\n'
fi
printf 'dmg=%s\n' "$DMG_PATH"
printf 'checksum=%s\n' "$CHECKSUM_PATH"
