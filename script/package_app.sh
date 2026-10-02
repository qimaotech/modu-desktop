#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${MODU_DERIVED_DATA_PATH:-${TMPDIR%/}/modu-desktop-derived-data}"
PACKAGE_DIR="${MODU_PACKAGE_DIR:-$ROOT_DIR/build/package}"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Release/Modu.app"
DMG_PATH="$PACKAGE_DIR/Modu-arm64.dmg"

xcodebuild \
  -quiet \
  -project "$ROOT_DIR/ModuDesktop.xcodeproj" \
  -scheme ModuDesktop \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ENABLE_CODE_COVERAGE=NO \
  build

test -x "$APP_BUNDLE/Contents/MacOS/Modu"
test -x "$APP_BUNDLE/Contents/Resources/modu-cli"
test -s "$APP_BUNDLE/Contents/Resources/SKILL.md"
test "$(lipo -archs "$APP_BUNDLE/Contents/MacOS/Modu")" = arm64
test "$(lipo -archs "$APP_BUNDLE/Contents/Resources/modu-cli")" = arm64
codesign --verify --deep --strict "$APP_BUNDLE"
"$APP_BUNDLE/Contents/Resources/modu-cli" --version

STAGING_DIR="$(mktemp -d "${TMPDIR%/}/modu-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_BUNDLE" "$STAGING_DIR/Modu.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$PACKAGE_DIR"
hdiutil create -volname Modu -srcfolder "$STAGING_DIR" \
  -format UDZO -fs HFS+ -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"
echo "Package: $DMG_PATH"
