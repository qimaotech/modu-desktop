#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_DOCUMENT="$ROOT_DIR/ModuDesktop/AppIcon.icon"
MODU_XCODE_CONTENTS="$(dirname "$(xcode-select -p)")"
ICON_TOOL="$MODU_XCODE_CONTENTS/Applications/Icon Composer.app/Contents/Executables/ictool"

main() {
  if [[ $# -gt 1 ]]; then
    echo "usage: $0 [output-directory]" >&2
    exit 2
  fi
  if [[ ! -x "$ICON_TOOL" ]]; then
    echo "Icon Composer's ictool was not found in the selected Xcode installation." >&2
    exit 1
  fi

  local output_dir="${1:-${TMPDIR%/}/modu-app-icon-previews}"
  local rendition
  mkdir -p "$output_dir"
  for rendition in Default Dark ClearLight ClearDark TintedLight TintedDark; do
    "$ICON_TOOL" "$ICON_DOCUMENT" \
      --export-image \
      --output-file "$output_dir/$rendition.png" \
      --platform macOS \
      --rendition "$rendition" \
      --width 1024 --height 1024 --scale 1
  done
  echo "App icon previews exported to $output_dir"
}

main "$@"
