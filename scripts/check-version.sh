#!/bin/sh
# Verify that generate-version.sh emits numeric FOOT_MAJOR/MINOR/PATCH for the
# current tree (in particular when HEAD is described by a non-semver tag).
#
# Usage: scripts/check-version.sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

tmp=$(mktemp "${TMPDIR:-/tmp}/foot-check-version.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM

sh "$root/generate-version.sh" 1.28.0 . "$tmp"

for macro in MAJOR MINOR PATCH; do
    value=$(sed -n "s/^#define FOOT_${macro}[[:space:]]*\\([^[:space:]]*\\).*/\\1/p" "$tmp")
    case "${value}" in
        ''|*[!0-9]*)
            echo "check-version: FOOT_${macro} is not numeric: '${value}'" >&2
            echo "check-version: generated header:" >&2
            cat "$tmp" >&2
            exit 1
            ;;
    esac
done

echo "check-version: ok ($(sed -n 's/^#define FOOT_VERSION "\(.*\)"/\1/p' "$tmp" | head -1))"
