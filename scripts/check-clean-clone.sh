#!/bin/sh
# Regression for non-semver tags: a clean clone of the current commit must
# build and pass its tests. Unlike an incremental build dir this has no
# stale generated version.h to hide a broken git describe.
#
# Set KEEP=1 to keep the temporary clone (its path is printed).

set -eu

# Number of registered Meson suites in tests/meson.build. Both the summary
# count and the registered suite list must equal this value; "Ok >= 9" would
# let a suite disappear as long as another one passed extra tests.
EXPECTED_SUITES=9

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
commit=$(git -C "$root" rev-parse HEAD)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/foot-clean-clone.XXXXXX")

if [ "${KEEP:-0}" = 1 ]; then
    echo "check-clean-clone: keeping ${tmp}"
else
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fi

if [ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
    ZIG_GLOBAL_CACHE_DIR="$tmp/zig-cache"
    export ZIG_GLOBAL_CACHE_DIR
fi

fail() {
    echo "check-clean-clone: FAILED: ${1}" >&2
    shift
    for log in "$@"; do
        [ -f "$log" ] || continue
        echo "--- ${log} (tail) ---" >&2
        tail -40 "$log" >&2
    done
    exit 1
}

echo "check-clean-clone: clone ${root} @ ${commit} into ${tmp}/src"
git clone --no-local "$root" "$tmp/src" >"$tmp/clone.log" 2>&1 ||
    fail "git clone" "$tmp/clone.log"
git -C "$tmp/src" checkout --detach "$commit" >"$tmp/checkout.log" 2>&1 ||
    fail "git checkout --detach" "$tmp/checkout.log"

echo "check-clean-clone: meson setup"
meson setup "$tmp/src/build" "$tmp/src" -Ddocs=disabled >"$tmp/setup.log" 2>&1 ||
    fail "meson setup" "$tmp/setup.log"

echo "check-clean-clone: ninja"
ninja -C "$tmp/src/build" >"$tmp/build.log" 2>&1 ||
    fail "ninja" "$tmp/build.log"

echo "check-clean-clone: meson test"
test_status=0
meson test -C "$tmp/src/build" --print-errorlogs >"$tmp/test.log" 2>&1 ||
    test_status=$?

summary=$(grep -E '^(Ok|Fail|Expected Fail|Skipped|Timeout):' "$tmp/test.log" |
          tr '\n' ' ' | tr -s ' ')
echo "check-clean-clone: ${summary}"

ok=$(sed -n 's/^Ok:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$tmp/test.log" | tail -1)
fail_count=$(sed -n 's/^Fail:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$tmp/test.log" | tail -1)
skipped=$(sed -n 's/^Skipped:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$tmp/test.log" | tail -1)
listed=$(meson test -C "$tmp/src/build" --list 2>/dev/null | wc -l | tr -d ' ')
observed=${ok:-none}
registered=${listed:-none}

if [ "$test_status" -ne 0 ] || [ "$observed" != "$EXPECTED_SUITES" ] ||
   [ "$registered" != "$EXPECTED_SUITES" ] ||
   [ "${fail_count}" != 0 ] || { [ -n "${skipped}" ] && [ "${skipped}" -gt 0 ]; }; then
    fail "meson test: expected exactly $EXPECTED_SUITES registered and passing suites (observed=$observed, registered=$registered, Fail=${fail_count:-missing}, Skipped=${skipped:-0})" "$tmp/test.log"
fi

echo "check-clean-clone: ok"
