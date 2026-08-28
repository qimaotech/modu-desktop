#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ModuDesktop"
BUNDLE_ID="fun.armantang.ModuDesktop"
SCHEME="ModuDesktop"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ModuDesktop.xcodeproj"
DERIVED_DATA_PATH="${MODU_DERIVED_DATA_PATH:-${TMPDIR%/}/modu-desktop-derived-data}"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

main() {
  local mode="${1:-run}"

  if [[ $# -gt 1 ]]; then
    print_usage
    exit 2
  fi

  case "$mode" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
      ;;
    *)
      print_usage
      exit 2
      ;;
  esac

  stop_app
  build_app

  case "$mode" in
    run)
      open_app
      ;;
    --debug|debug)
      lldb -- "$APP_BINARY"
      ;;
    --logs|logs)
      open_app
      /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
      ;;
    --telemetry|telemetry)
      open_app
      /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
      ;;
    --verify|verify)
      open_app
      verify_app
      ;;
  esac
}

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_app() {
  local attempt

  for attempt in {1..20}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "$APP_NAME is running."
      return
    fi
    sleep 0.25
  done

  echo "$APP_NAME did not start within 5 seconds." >&2
  exit 1
}

print_usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

main "$@"
