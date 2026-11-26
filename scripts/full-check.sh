#!/bin/sh
# The commit gate: every build dir + the smoke test.
#
#   build             debug          - the fast inner loop (scripts/dev-check.sh)
#   build-disabled    debug          - features off (grapheme clustering, ...)
#   build-release     release        - ReleaseSafe: optimised, safety checks on
#
# The two debug dirs build together; build-release runs on its own afterwards,
# because Zig's ReleaseSafe codegen is the slow part and running it next to
# two debug builds only oversubscribes the machine.
#
# Exit status is non-zero if any dir fails, and the failing log is printed.

cd "$(dirname "$0")/.."

# Number of registered Meson tests in tests/meson.build. A Meson summary's
# "Ok:" is the number of suites that ran, not the number of `ok:` assertions
# printed by the harnesses (there are 1,040 of those in nine suites), so an
# "Ok >= 9" threshold on assertion lines cannot detect a missing suite.
EXPECTED_SUITES=9

# Keep Zig's cache per-checkout when the caller has not chosen one. Do not
# hardcode a developer's /tmp path here: this script is run from clean clones.
if [ -z "${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
    ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache-gate"
    export ZIG_GLOBAL_CACHE_DIR
fi

summary() {
    d=$1
    grep -E '^(Ok|Fail|Expected Fail|Skipped|Timeout):' "/tmp/foot-test-$d.log" 2>/dev/null |
        tr '\n' ' ' | tr -s ' '
}

run_dir() {
    d=$1
    # Never report a previous run's test results as if they were current.
    rm -f "/tmp/foot-build-$d.log" "/tmp/foot-test-$d.log"
    if ! ninja -C "$d" > "/tmp/foot-build-$d.log" 2>&1; then
        echo "--- $d build FAILED (tail) ---" >&2
        tail -40 "/tmp/foot-build-$d.log" >&2
        return 1
    fi
    meson test -C "$d" --print-errorlogs > "/tmp/foot-test-$d.log" 2>&1
}

report() {
    d=$1
    log="/tmp/foot-test-$d.log"
    printf '%-16s %s\n' "$d" "$(summary "$d")"

    ok=$(sed -n 's/^Ok:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log" 2>/dev/null | tail -1)
    fail_count=$(sed -n 's/^Fail:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log" 2>/dev/null | tail -1)
    skipped=$(sed -n 's/^Skipped:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log" 2>/dev/null | tail -1)
    observed=${ok:-0}
    listed=$(meson test -C "$d" --list 2>/dev/null | wc -l | tr -d ' ')
    listed=${listed:-0}

    # Both counts must equal EXPECTED_SUITES: the registered suite list
    # catches a test deleted from tests/meson.build, and the summary count
    # catches a registered suite that did not run.
    if [ "$observed" -ne "$EXPECTED_SUITES" ] ||
       [ "$listed" -ne "$EXPECTED_SUITES" ]; then
        echo "--- $d suite count: observed $observed, registered $listed, expected $EXPECTED_SUITES ---" >&2
        echo "--- $d build log (tail) ---" >&2
        tail -20 "/tmp/foot-build-$d.log" >&2
        echo "--- $d test log (tail) ---" >&2
        tail -20 "$log" >&2
        return 1
    fi

    if [ "$fail_count" != 0 ] ||
       { [ -n "$skipped" ] && [ "$skipped" -gt 0 ]; }; then
        echo "--- $d build log (tail) ---" >&2
        tail -20 "/tmp/foot-build-$d.log" >&2
        echo "--- $d test log (tail) ---" >&2
        tail -20 "$log" >&2
        return 1
    fi
    return 0
}

status=0

run_dir build & p1=$!
run_dir build-disabled & p2=$!
wait $p1 || status=1
wait $p2 || status=1
report build || status=1
report build-disabled || status=1

if [ "$status" -ne 0 ]; then
    echo "FAILED (debug dirs)"
    exit 1
fi

run_dir build-release || status=1
report build-release || status=1

if [ "$status" -ne 0 ]; then
    echo "FAILED (build-release)"
    exit 1
fi

# Build/test phase is complete. The parity check rebuilds the corpus against
# the C oracle; do not let a failure there pass unnoticed.
if [ -f scripts/render-parity.sh ]; then
    echo "--- render parity ---"
    if ! ./scripts/render-parity.sh; then
        echo "FAILED (render parity)"
        exit 1
    fi
fi

echo "--- smoke ---"
# Use the session compositor when there is one: the six window launches are
# the only end-to-end coverage the wayland/render ports have. Fall back to
# the weston/Xvfb path otherwise. If neither is available, smoke.sh fails
# rather than silently passing with zero window launches.
rt=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "$rt/$WAYLAND_DISPLAY" ]; then
    XDG_RUNTIME_DIR="$rt" scripts/smoke.sh
else
    env -u WAYLAND_DISPLAY scripts/smoke.sh
fi
