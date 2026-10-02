#!/usr/bin/env bash
set -euo pipefail

if [[ ! "${MARKETING_VERSION:-}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ||
      ! "${CURRENT_PROJECT_VERSION:-}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "error: Version.xcconfig must define numeric MARKETING_VERSION and CURRENT_PROJECT_VERSION." >&2
  exit 1
fi

mkdir -p "$(dirname "${SCRIPT_OUTPUT_FILE_0:?}")"
cat > "$SCRIPT_OUTPUT_FILE_0" <<EOF
// Generated from Version.xcconfig. Do not edit.
public enum ModuVersion {
    public static let current = "$MARKETING_VERSION"
    public static let buildNumber = "$CURRENT_PROJECT_VERSION"
}
EOF
