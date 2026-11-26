#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
: "${ZIG_GLOBAL_CACHE_DIR:=${TMPDIR:-/tmp}/foot-zig-target-cache}"
export ZIG_GLOBAL_CACHE_DIR

# Native build dir that supplies c_layout.zig. Default is unchanged; a
# relative override is resolved against the repo root.
BUILD_DIR=${BUILD_DIR:-$root/build}
case $BUILD_DIR in
    /*) ;;
    *) BUILD_DIR=$root/$BUILD_DIR ;;
esac

layout=
for candidate in "$BUILD_DIR/c_layout.zig" build-release/c_layout.zig                  bld/zig-enabled/c_layout.zig bld/zig-disabled/c_layout.zig                  bld/zig-release/c_layout.zig; do
    if [ -f "$candidate" ]; then
        layout=$candidate
        break
    fi
done
if [ -z "$layout" ]; then
    echo "check-targets: $BUILD_DIR/c_layout.zig is missing; run a native build first" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/foot-targets.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat > "$tmp/build_options.zig" <<"OPTIONS"
pub const grapheme_clustering = true;
pub const default_terminfo = "foot";
pub const foot_terminfo_path = "";
OPTIONS

for target in x86_64-freebsd aarch64-linux-gnu; do
    for source in fdm.zig spawn.zig slave.zig main.zig server.zig; do
        echo "check-targets: $target $source"
        set -- -target "$target" -lc -O Debug -fno-stack-check
        case "$source" in
            slave.zig|main.zig|server.zig)
                set -- "$@" --dep build_options --dep c_layout \
                    "-Mroot=$source" "-Mbuild_options=$tmp/build_options.zig" \
                    "-Mc_layout=$layout"
                ;;
            fdm.zig)
                # fdm imports c_layout only on Linux (for epoll_event).
                set -- "$@" --dep c_layout "-Mroot=$source" "-Mc_layout=$layout"
                ;;
            *)
                set -- "$@" "-Mroot=$source"
                ;;
        esac
        zig build-obj "$@" -fno-emit-bin
    done
done
