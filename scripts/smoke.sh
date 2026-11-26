#!/bin/sh
# Smoke-test a foot build.
#
# Checks, in order:
#   1. `foot --version` (also runs the C UNITTEST constructors in assertion
#      builds, e.g. the term_to_slave/ptmx test)
#   2. `foot -C` (config parser)
#   3. real window launches at a few sizes, asserting a clean exit and no
#      panic. Uses $WAYLAND_DISPLAY if set, otherwise starts a headless
#      weston (when installed).
#
# Usage: scripts/smoke.sh [path-to-foot]

set -eu

foot=${1:-./build/foot}

if [ ! -x "$foot" ]; then
    echo "smoke: $foot is not executable" >&2
    exit 1
fi

echo "smoke: $foot --version"
"$foot" --version >/dev/null

tmp_dir=$(mktemp -d)
conf=$tmp_dir/foot.ini
printf '[main]\nfont=monospace:size=10\n' > "$conf"

# `-C` treats "no configuration found" as an error (foot exits -26), so give
# it a known-good file instead of depending on the machine's config.
echo "smoke: $foot -C -c <temp config>"
"$foot" -C -c "$conf"

weston_pid=
xvfb_pid=
runtime_dir=
cleanup() {
    [ -n "$weston_pid" ] && kill "$weston_pid" 2>/dev/null || true
    [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
    [ -n "$runtime_dir" ] && rm -rf "$runtime_dir"
    rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    if command -v weston >/dev/null 2>&1; then
        runtime_dir=$(mktemp -d)
        export XDG_RUNTIME_DIR=$runtime_dir
        export WAYLAND_DISPLAY=wayland-smoke
        backend=headless-backend.so
        # Weston's headless backend creates no wl_seat, and foot refuses to
        # start without one. The x11 backend under a throwaway Xvfb has a
        # virtual keyboard and pointer, so prefer it when Xvfb is available.
        if command -v Xvfb >/dev/null 2>&1; then
            display=:91
            while [ -e "/tmp/.X${display#:}-lock" ] ||
                  [ -e "/tmp/.X11-unix/X${display#:}" ]; do
                display=:$(( ${display#:} + 1 ))
            done
            Xvfb "$display" -screen 0 1024x768x24 \
                  >"$runtime_dir/xvfb.log" 2>&1 &
            xvfb_pid=$!
            export DISPLAY=$display

            i=0
            while [ ! -e "/tmp/.X11-unix/X${display#:}" ]; do
                i=$((i + 1))
                if [ "$i" -gt 50 ]; then
                    echo "smoke: Xvfb did not come up" >&2
                    cat "$runtime_dir/xvfb.log" >&2 || true
                    exit 1
                fi
                sleep 0.1
            done

            backend=x11-backend.so
        fi
        echo "smoke: starting weston ($backend)"
        weston --backend="$backend" --socket="$WAYLAND_DISPLAY" \
               --idle-time=0 --log="$runtime_dir/weston.log" \
               >>"$runtime_dir/weston.log" 2>&1 &
        weston_pid=$!
        i=0
        while [ ! -S "$runtime_dir/$WAYLAND_DISPLAY" ]; do
            i=$((i + 1))
            if [ "$i" -gt 50 ]; then
                echo "smoke: weston did not come up" >&2
                cat "$runtime_dir/weston.log" >&2 || true
                exit 1
            fi
            sleep 0.1
        done
    elif [ "${FOOT_ALLOW_NO_COMPOSITOR:-0}" = 1 ]; then
        echo "smoke: SKIP window launches (no WAYLAND_DISPLAY and no weston/Xvfb; FOOT_ALLOW_NO_COMPOSITOR=1)"
        exit 0
    else
        # Version/config checks alone do not exercise the wayland/render
        # ports. Never report success when zero windows were launched.
        echo "smoke: no WAYLAND_DISPLAY and no weston/Xvfb; cannot launch windows" >&2
        echo "smoke: start a compositor, or set FOOT_ALLOW_NO_COMPOSITOR=1 to skip explicitly" >&2
        exit 1
    fi
fi

run() {
    size=$1
    shift
    echo "smoke: launching at $size"
    if ! out=$(timeout 30 "$foot" -W "$size" "$@" -e sh -c 'printf "smoke\n"; exit 0' 2>&1); then
        echo "smoke: launch at $size failed" >&2
        echo "$out" >&2
        return 1
    fi
    case "$out" in
        *panic*|*ERROR*|*assertion*)
            echo "smoke: launch at $size produced a failure:" >&2
            echo "$out" >&2
            return 1
            ;;
    esac
    return 0
}

run 80x24
run 132x43
run 20x5
# Maximized/fullscreen trigger extra configure/reflow paths.
run 80x24 -m
run 80x24 -F

# The scrollback indicator and the render-timer OSD each paint into their own
# sub-surface; enable both so those paths run against a real compositor.
osd_conf=$tmp_dir/osd.ini
printf '[main]\nfont=monospace:size=10\nrender-timer=osd\nscrollback-indicator=percentage\n' > "$osd_conf"
run 80x24 -c "$osd_conf"


echo "smoke: ok"
