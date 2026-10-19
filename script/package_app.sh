#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${MODU_DERIVED_DATA_PATH:-${TMPDIR%/}/modu-desktop-derived-data}"
PACKAGE_DIR="${MODU_PACKAGE_DIR:-$ROOT_DIR/build/package}"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Release/Modu.app"

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
test -s "$APP_BUNDLE/Contents/Resources/modu-workflow/SKILL.md"
test -s "$APP_BUNDLE/Contents/Resources/modu-workflow/agents/openai.yaml"
test "$(lipo -archs "$APP_BUNDLE/Contents/MacOS/Modu")" = arm64
test "$(lipo -archs "$APP_BUNDLE/Contents/Resources/modu-cli")" = arm64
codesign --verify --deep --strict "$APP_BUNDLE"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
test -n "$APP_VERSION"
CLI_VERSION="$("$APP_BUNDLE/Contents/Resources/modu-cli" --version)"
if [[ "$CLI_VERSION" != "$APP_VERSION" ]]; then
  echo "App version ($APP_VERSION) does not match bundled CLI version ($CLI_VERSION)." >&2
  exit 1
fi
echo "Version: $APP_VERSION"
DMG_NAME="Modu-$APP_VERSION-arm64.dmg"
DMG_PATH="$PACKAGE_DIR/$DMG_NAME"

STAGING_DIR="$(mktemp -d "${TMPDIR%/}/modu-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_BUNDLE" "$STAGING_DIR/Modu.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$PACKAGE_DIR"
hdiutil create -volname Modu -srcfolder "$STAGING_DIR" \
  -format UDZO -fs HFS+ -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"
echo "Package: $DMG_PATH"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'dmg_name=%s\ndmg_path=%s\n' "$DMG_NAME" "$DMG_PATH" >> "$GITHUB_OUTPUT"
fi
