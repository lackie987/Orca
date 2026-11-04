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
BIN_DIR="$(swift build -c release --package-path "$DIR" ${ORCA_SWIFT_FLAGS:-} --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
SYNC_BIN="$BIN_DIR/orca-icon-sync"

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# Keep the background icon-sync helper beside the main binary so the LaunchAgent
# can reach it without a separate install step.
if [ -f "$SYNC_BIN" ]; then
  cp "$SYNC_BIN" "$APP/Contents/MacOS/orca-icon-sync"
fi
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
# get-task-allow is what makes WebKit build its Web Inspector front end; without it the inspector
# (F12) is a silent no-op. See Resources/Orca.entitlements.
ENTITLEMENTS="$DIR/Resources/Orca.entitlements"
if [ "$SIGN_IDENTITY" = "-" ]; then
  # A stable designated requirement keeps TCC grants (Documents access, etc.) across rebuilds:
  # an ad-hoc signature's default requirement is its cdhash, so every build looks like a brand
  # new app to macOS and re-asks for permission.
  codesign --force --sign - --identifier com.xu.orca --entitlements "$ENTITLEMENTS" \
    -r='designated => identifier "com.xu.orca"' "$APP" >/dev/null 2>&1
else
  codesign --force --sign "$SIGN_IDENTITY" --identifier com.xu.orca \
    --entitlements "$ENTITLEMENTS" "$APP" >/dev/null 2>&1
fi

if [ "${1:-}" = "--no-install" ]; then
  echo "✅ $APP"
  exit 0
fi

echo "▸ Installing to $INSTALL_DIR"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"
"$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1 || true
# The assembled copy carries the same bundle id, so leaving it behind hands LaunchServices a second
# "Orca" holding a build-time snapshot of the icon: Finder, Spotlight and the Dock may draw that one.
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
rm -rf "$APP"

# Install and load the per-user LaunchAgent that keeps the Dock/ Finder icon in
# step with the saved app-icon setting while Orca is not running.
echo "▸ Installing LaunchAgent (icon auto-sync)"
PLIST_SRC="$DIR/Resources/com.xu.orca.icon-sync.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.xu.orca.icon-sync.plist"
if [ -f "$PLIST_SRC" ]; then
  sed -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" -e "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
  # Reload rather than load: launchd keeps the definition it was bootstrapped with, so a plist that
  # changed (KeepAlive instead of StartInterval, say) only takes effect after a bootout.
  launchctl bootout "gui/$(id -u)/com.xu.orca.icon-sync" 2>/dev/null || true
  # `bootstrap` races the teardown and fails with a bare I/O error, which `|| true` used to swallow:
  # the agent then stayed unloaded until the next build. Wait for the label to leave the domain.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "gui/$(id -u)/com.xu.orca.icon-sync" >/dev/null 2>&1 || break
    sleep 0.3
  done
  launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null \
    || echo "⚠️  LaunchAgent not loaded; run: launchctl bootstrap gui/$(id -u) $PLIST_DST"
  echo "✅ LaunchAgent installed: $PLIST_DST"
fi
echo "✅ $INSTALL_DIR/$APP_NAME.app"
