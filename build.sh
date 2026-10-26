#!/usr/bin/env bash
# Rebuild Orca.app from source and install it into /Applications.
# Usage: ./build.sh [--no-install]
#
# Environment:
#   ORCA_INSTALL_DIR     destination for the copy step (default /Applications)
#   ORCA_SIGN_IDENTITY   codesign identity (default "-", i.e. ad-hoc)
#   ORCA_SWIFT_FLAGS     extra flags for swift build, e.g. --disable-sandbox in a sandbox
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Orca"
BUILD_DIR="$DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="${ORCA_INSTALL_DIR:-/Applications}"
SIGN_IDENTITY="${ORCA_SIGN_IDENTITY:--}"

# shellcheck disable=SC2086 # intentional word splitting
echo "▸ Compiling $APP_NAME"
swift build -c release --package-path "$DIR" ${ORCA_SWIFT_FLAGS:-}
BIN="$(swift build -c release --package-path "$DIR" ${ORCA_SWIFT_FLAGS:-} --show-bin-path)/$APP_NAME"

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# The running app writes the chosen icon preset into the installed bundle's AppIcon.icns, so a
# rebuild would otherwise reset the visible icon to the repo default until the app launches again.
# Carry the installed icon over whenever it differs from the shipped one.
INSTALLED_ICON="$INSTALL_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns"
ICON_SOURCE="$DIR/Resources/AppIcon.icns"
if [ -f "$INSTALLED_ICON" ] && ! cmp -s "$INSTALLED_ICON" "$DIR/Resources/AppIcon.icns"; then
  ICON_SOURCE="$INSTALLED_ICON"
fi
cp "$ICON_SOURCE" "$APP/Contents/Resources/AppIcon.icns"
cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/Icons"
cp "$DIR/Resources/Icons/"* "$APP/Contents/Resources/Icons/"
printf 'APPL????' >"$APP/Contents/PkgInfo"

echo "▸ Signing ($SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" = "-" ]; then
  # A stable designated requirement keeps TCC grants (Documents access, etc.) across rebuilds:
  # an ad-hoc signature's default requirement is its cdhash, so every build looks like a brand
  # new app to macOS and re-asks for permission.
  codesign --force --sign - --identifier com.xu.orca \
    -r='designated => identifier "com.xu.orca"' "$APP" >/dev/null 2>&1
else
  codesign --force --sign "$SIGN_IDENTITY" --identifier com.xu.orca "$APP" >/dev/null 2>&1
fi

if [ "${1:-}" = "--no-install" ]; then
  echo "✅ $APP"
  exit 0
fi

echo "▸ Installing to $INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1 || true
echo "✅ $INSTALL_DIR/$APP_NAME.app"
