#!/usr/bin/env bash
# Package Orca.app for distribution: a double-click PKG installer and a drag-to-Applications DMG.
# Artifacts are written to dist/ together with a SHA-256 checksum file.
#
# Usage: ./package.sh [--no-dmg] [--no-pkg]
#
# Environment:
#   ORCA_SWIFT_FLAGS          forwarded to build.sh (e.g. --disable-sandbox)
#   ORCA_INSTALLER_IDENTITY   "Developer ID Installer" identity for the PKG; unsigned when unset
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Orca"
APP="$DIR/build/$APP_NAME.app"
DIST="$DIR/dist"
PLIST="$DIR/Resources/Info.plist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
BASE="$APP_NAME-$VERSION"

want_dmg=1
want_pkg=1
for arg in "$@"; do
  case "$arg" in
    --no-dmg) want_dmg=0 ;;
    --no-pkg) want_pkg=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "▸ Building $APP_NAME $VERSION ($BUILD_NUM)"
ORCA_SWIFT_FLAGS="${ORCA_SWIFT_FLAGS:-}" "$DIR/build.sh" --no-install

echo "▸ Resetting $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"

# Builds Orca-<version>.dmg: the app plus an /Applications shortcut, so the usual drag gesture works.
build_dmg() {
  local dmg="$DIST/$BASE.dmg"
  local stage="$DIST/.dmg-root"

  echo "▸ Staging DMG"
  mkdir -p "$stage"
  ditto "$APP" "$stage/$APP_NAME.app"
  ln -s /Applications "$stage/Applications"
  cat >"$stage/READ ME.txt" <<TXT
$APP_NAME $VERSION ($BUILD_NUM)

把 $APP_NAME 拖到右侧的 Applications 文件夹即可安装。
Drag $APP_NAME onto the Applications folder to install.

This build is ad-hoc signed, so macOS blocks the first launch until you allow it:
  1. Open Applications, then right-click (or Control-click) $APP_NAME and choose Open.
  2. If no Open button appears, go to System Settings > Privacy & Security and click
     "Open Anyway" next to $APP_NAME.
Later launches work normally.

If macOS says the app is damaged, clear the download flag once:
  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app

Requires macOS $MIN_OS or later, and the \`dsh\` command line tool on PATH
(DeepSeek Harness). Point Orca at a different binary in Settings (⌘,) if needed.
TXT

  hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$stage" -ov \
    -format UDZO -imagekey zlib-level=9 "$dmg" >/dev/null
  rm -rf "$stage"
  echo "  $dmg"
}

# Builds Orca-<version>.pkg: a one-click installer that drops the app into /Applications.
build_pkg() {
  local pkg="$DIST/$BASE.pkg"
  local work="$DIST/.pkg-work"

  echo "▸ Building PKG"
  mkdir -p "$work"
  pkgbuild --component "$APP" \
    --install-location "/Applications" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    "$work/$BASE-component.pkg" >/dev/null

  cat >"$work/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>$APP_NAME $VERSION</title>
  <organization>com.xu</organization>
  <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <allowed-os-versions>
    <os-version min="$MIN_OS"/>
  </allowed-os-versions>
  <pkg-ref id="$BUNDLE_ID"/>
  <choices-outline>
    <line choice="default">
      <line choice="$BUNDLE_ID"/>
    </line>
  </choices-outline>
  <choice id="default"/>
  <choice id="$BUNDLE_ID" visible="false">
    <pkg-ref id="$BUNDLE_ID"/>
  </choice>
  <pkg-ref id="$BUNDLE_ID" version="$VERSION" onConclusion="none">$BASE-component.pkg</pkg-ref>
</installer-gui-script>
XML

  local sign_args=()
  if [ -n "${ORCA_INSTALLER_IDENTITY:-}" ]; then
    sign_args=(--sign "$ORCA_INSTALLER_IDENTITY")
  fi
  productbuild --distribution "$work/distribution.xml" --package-path "$work" \
    "${sign_args[@]}" "$pkg" >/dev/null
  rm -rf "$work"
  echo "  $pkg"
}

[ "$want_dmg" = 1 ] && build_dmg
[ "$want_pkg" = 1 ] && build_pkg

echo "▸ Checksums"
(
  cd "$DIST"
  shasum -a 256 "$BASE".* >SHA256SUMS.txt
)

echo "✅ Artifacts in $DIST"
for artifact in "$DIST"/*; do
  printf '  %-6s %s\n' "$(du -h "$artifact" | cut -f1)" "$(basename "$artifact")"
done
