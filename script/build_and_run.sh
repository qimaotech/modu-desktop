#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Modu"
BUNDLE_ID="fun.armantang.ModuDesktop"
SCHEME="ModuDesktop"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ModuDesktop.xcodeproj"
DERIVED_DATA_PATH="${MODU_DERIVED_DATA_PATH:-${TMPDIR%/}/modu-desktop-derived-data}"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
MOCK_SCENARIO=""
MOCK_DIRECTORY=""
MOCK_PREPARATION_PID=""
MOCK_HANDED_OFF=false
MOCK_LAUNCH_ATTEMPTED=false

main() {
  local mode="run"
  local mode_selected=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mock)
        if [[ $# -lt 2 || -n "$MOCK_SCENARIO" || "$2" != "linked-worktree-selected" ]]; then
          echo "Use --mock linked-worktree-selected." >&2
          exit 2
        fi
        MOCK_SCENARIO="$2"
        shift 2
        ;;
      run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|-verify|verify)
        if $mode_selected; then print_usage; exit 2; fi
        mode="$1"
        mode_selected=true
        shift
        ;;
      *)
        print_usage
        exit 2
        ;;
    esac
  done

  trap cleanup_unlaunched_mock EXIT
  trap 'cancel_mock_preparation 130' INT
  trap 'cancel_mock_preparation 143' TERM
  if [[ -z "$MOCK_SCENARIO" && "$mode" != "--verify" && "$mode" != "-verify" && "$mode" != "verify" ]]; then stop_app; fi
  build_app

  case "$mode" in
    run)
      open_app
      ;;
    --debug|debug)
      MOCK_LAUNCH_ATTEMPTED=true
      if [[ -n "$MOCK_SCENARIO" ]]; then lldb -- "$APP_BINARY" --mock "$MOCK_SCENARIO" --mock-workspace "$MOCK_DIRECTORY/example-workspace"
      else lldb -- "$APP_BINARY"; fi
      ;;
    --logs|logs)
      open_app
      /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
      ;;
    --telemetry|telemetry)
      open_app
      /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
      ;;
    --verify|-verify|verify)
      verify_app
      ;;
  esac
}

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  local command=(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION"
    -destination "platform=macOS" -derivedDataPath "$DERIVED_DATA_PATH" ENABLE_CODE_COVERAGE=NO build)
  if [[ -n "$MOCK_SCENARIO" ]]; then
    MOCK_DIRECTORY="$(/usr/bin/python3 "$ROOT_DIR/script/prepare_mock_workspace.py" allocate)"
    /usr/bin/python3 "$ROOT_DIR/script/prepare_mock_workspace.py" prepare --directory "$MOCK_DIRECTORY" --build "${command[@]}" &
    MOCK_PREPARATION_PID=$!
    local status=0
    wait "$MOCK_PREPARATION_PID" || status=$?
    MOCK_PREPARATION_PID=""
    if [[ "$status" -ne 0 ]]; then return "$status"; fi
  else
    "${command[@]}"
  fi
}

open_app() {
  local arguments=(-n)
  local variable
  for variable in MODU_TEST_DEFAULTS MODU_TEST_WORKSPACE MODU_TEST_SUPPORT_DIRECTORY MODU_TEST_HOME_DIRECTORY MODU_TEST_LOGIN_SHELL; do
    if [[ -n "${!variable:-}" ]]; then arguments+=(--env "$variable=${!variable}"); fi
  done
  MOCK_LAUNCH_ATTEMPTED=true
  if [[ -n "$MOCK_SCENARIO" ]]; then /usr/bin/open "${arguments[@]}" "$APP_BUNDLE" --args --mock "$MOCK_SCENARIO" --mock-workspace "$MOCK_DIRECTORY/example-workspace"
  else /usr/bin/open "${arguments[@]}" "$APP_BUNDLE"; fi
  MOCK_HANDED_OFF=true
}

verify_app() {
  local arguments=("$APP_BUNDLE")
  if [[ -n "$MOCK_SCENARIO" ]]; then arguments+=(--mock "$MOCK_SCENARIO" --mock-workspace "$MOCK_DIRECTORY/example-workspace"); fi
  MOCK_LAUNCH_ATTEMPTED=true
  if [[ -n "$MOCK_DIRECTORY" ]]; then
    launch_verified_app "${arguments[@]}" | tee "$MOCK_DIRECTORY/launch.log"
  else
    launch_verified_app "${arguments[@]}"
  fi
}

launch_verified_app() {
  /usr/bin/swift -module-cache-path "$DERIVED_DATA_PATH/VerificationModuleCache" "$ROOT_DIR/script/verify_app.swift" "$@"
}

cleanup_unlaunched_mock() {
  trap '' INT TERM
  if [[ -z "$MOCK_DIRECTORY" || "$MOCK_HANDED_OFF" == true ]]; then return; fi
  if $MOCK_LAUNCH_ATTEMPTED; then
    local status=0
    find_mock_app || status=$?
    case "$status" in
      0) return ;;
      1) ;;
      *) echo "Could not confirm mock App state; keeping temporary data: $MOCK_DIRECTORY" >&2; return ;;
    esac
  fi
  /usr/bin/python3 "$ROOT_DIR/script/prepare_mock_workspace.py" cleanup --directory "$MOCK_DIRECTORY"
}

find_mock_app() {
  /usr/bin/python3 "$ROOT_DIR/script/find_mock_app.py" --executable "$APP_BINARY" --workspace "$MOCK_DIRECTORY/example-workspace"
}

cancel_mock_preparation() {
  trap '' INT TERM
  if [[ -n "$MOCK_PREPARATION_PID" ]]; then
    kill -TERM "$MOCK_PREPARATION_PID" 2>/dev/null || true
    wait "$MOCK_PREPARATION_PID" || true
  fi
  exit "$1"
}

print_usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify] [--mock linked-worktree-selected]" >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
