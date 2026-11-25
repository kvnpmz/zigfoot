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

run_dir() {
    d=$1
    ninja -C "$d" > "/tmp/foot-build-$d.log" 2>&1 &&
    meson test -C "$d" --no-rebuild > "/tmp/foot-test-$d.log" 2>&1
}

report() {
    d=$1
    summary=$(grep -E '^(Ok|Fail):' "/tmp/foot-test-$d.log" 2>/dev/null | tr -s ' ' | tr '\n' ' ')
    printf '%-16s %s\n' "$d" "$summary"
    if grep -qE '^Fail:[[:space:]]*0[[:space:]]*$' "/tmp/foot-test-$d.log" 2>/dev/null; then
        return 0
    fi
    echo "--- $d build log (tail) ---"; tail -20 "/tmp/foot-build-$d.log"
    echo "--- $d test log (tail) ---"; tail -20 "/tmp/foot-test-$d.log"
    return 1
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

echo "--- smoke ---"
# Use the session compositor when there is one: the five window launches are
# the only end-to-end coverage the wayland/render ports have. Fall back to
# the weston/Xvfb path (or the version/config-only checks) otherwise.
rt=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "$rt/$WAYLAND_DISPLAY" ]; then
    XDG_RUNTIME_DIR="$rt" scripts/smoke.sh
else
    env -u WAYLAND_DISPLAY scripts/smoke.sh
fi
