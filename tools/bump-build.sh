#!/usr/bin/env bash
# Bump the iOS build number (and optionally the marketing version), then
# regenerate the Xcode project so Xcode picks up the new values on next
# build. Doesn't commit — review the project.yml diff and commit yourself.
#
# Usage:
#   ./tools/bump-build.sh                  # CURRENT_PROJECT_VERSION += 1
#   ./tools/bump-build.sh --release 0.2.0  # also set MARKETING_VERSION
#
# Run from anywhere; the script cd's to the iOS repo root.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_FILE="project.yml"
if [ ! -f "$PROJECT_FILE" ]; then
  echo "error: $PROJECT_FILE not found (expected to run from iOS repo root)" >&2
  exit 1
fi

# ---- Parse args ----------------------------------------------------------
RELEASE_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release)
      RELEASE_VERSION="${2:-}"
      if [ -z "$RELEASE_VERSION" ]; then
        echo "error: --release requires a value (e.g. 0.2.0)" >&2
        exit 1
      fi
      if ! [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "error: --release must be X.Y.Z (got: $RELEASE_VERSION)" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1 (try --help)" >&2
      exit 1
      ;;
  esac
done

# ---- Read current values ------------------------------------------------
CURRENT_BUILD=$(awk -F'"' '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ {print $2; exit}' "$PROJECT_FILE")
if [ -z "$CURRENT_BUILD" ]; then
  echo "error: couldn't find CURRENT_PROJECT_VERSION in $PROJECT_FILE" >&2
  exit 1
fi
if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  echo "error: CURRENT_PROJECT_VERSION is not an integer ($CURRENT_BUILD)" >&2
  exit 1
fi
NEXT_BUILD=$((CURRENT_BUILD + 1))

CURRENT_MV=$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ {print $2; exit}' "$PROJECT_FILE")

# ---- Apply edits --------------------------------------------------------
# BSD sed (macOS) requires the '' after -i. The sentinel-quoted patterns
# make sure we replace the EXACT current value, not some other line that
# happens to mention the number.
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$CURRENT_BUILD\"/CURRENT_PROJECT_VERSION: \"$NEXT_BUILD\"/" "$PROJECT_FILE"
echo "build:     $CURRENT_BUILD → $NEXT_BUILD"

if [ -n "$RELEASE_VERSION" ]; then
  if [ -z "$CURRENT_MV" ]; then
    echo "error: couldn't find MARKETING_VERSION in $PROJECT_FILE" >&2
    exit 1
  fi
  sed -i '' "s/MARKETING_VERSION: \"$CURRENT_MV\"/MARKETING_VERSION: \"$RELEASE_VERSION\"/" "$PROJECT_FILE"
  echo "marketing: $CURRENT_MV → $RELEASE_VERSION"
fi

# ---- Regenerate the Xcode project ---------------------------------------
if ! command -v xcodegen >/dev/null 2>&1; then
  echo ""
  echo "warning: xcodegen not installed — project.yml updated but Xcode" >&2
  echo "         project NOT regenerated. Install with: brew install xcodegen" >&2
  exit 0
fi

xcodegen --quiet
echo ""
echo "✓ Done. Review the diff, commit, then archive in Xcode."
