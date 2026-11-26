#!/usr/bin/env bash
# Build and run the standalone VT fuzz harness against a frozen footlib.
set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [seeds]" >&2
    exit 2
fi
seeds=${1:-40}
case $seeds in
    ''|*[!0-9]*|0*) valid=no ;;
    *) valid=yes ;;
esac
if [ "$valid" != yes ] || [ "$seeds" -gt 10000 ]; then
    echo "seed count must be in 1..10000" >&2
    exit 2
fi

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# Build dir to snapshot. Default is unchanged ($root/build); a relative
# override is resolved from the repo root (cd "$root" happens below).
BUILD_DIR=${BUILD_DIR:-$root/build}
# Each invocation gets its own directory: concurrent checks must not reuse
# another run's snapshot archives, objects or failure artifacts.
work=$(mktemp -d "${TMPDIR:-/tmp}/fuzz-vt.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
cd "$root"

# ninja is used only to print existing commands.  Do not invoke a build target.
compile_line=$(ninja -C "$BUILD_DIR" -t commands libvtlib.a | python3 -c '
import sys
lines = sys.stdin.read().splitlines()
print(next(line for line in lines if " -c " in line and "csi-shim.c" in line))
')
link_line=$(ninja -C "$BUILD_DIR" -t commands foot | tail -1)
compile_flags=$(python3 -c '
import shlex, sys
words = shlex.split(sys.argv[1])
keep = []
for word in words[1:]:
    if word == "-MD":
        break
    if word.startswith(("-I", "-D")) or word in {
        "-fdiagnostics-color=always", "-D_FILE_OFFSET_BITS=64",
        "-Wall", "-Winvalid-pch", "-Werror", "-std=c11", "-O0", "-g",
        "-pedantic", "-fstrict-aliasing", "-Wstrict-aliasing",
        "-fPIC", "-pthread"
    }:
        keep.append(word)
print(shlex.join(keep))
' "$compile_line")
libs=$(python3 -c '
import os, shlex, sys
words = shlex.split(sys.argv[1])
keep = []
in_group = False
for word in words:
    if word == "-Wl,--start-group":
        in_group = True
        keep.append("-Wl,--start-group")
    elif word == "-Wl,--end-group":
        keep.append("-Wl,--end-group")
        in_group = False
    elif in_group and word.endswith(".a"):
        name = os.path.basename(word)
        keep.append(os.path.join(sys.argv[2], name))
    elif word == "-pthread" or word.startswith("-l") or word.endswith(".so"):
        if word not in keep:
            keep.append(word)
print(shlex.join(keep))
' "$link_line" "$work")
printf '%s\n' "$compile_line" > "$work/compile-line.txt"
printf '%s\n' "$link_line" > "$work/link-line.txt"
compile_flags=${compile_flags/-Ilibvtlib.a.p/-I$work/include}
printf '%s\n' "$compile_flags" > "$work/compile-flags.txt"
printf '%s\n' "$libs" > "$work/libs.txt"
sha256sum tests/fuzz-vt.c "$BUILD_DIR/libfootlib.a" > "$work/snapshot.sha256"

# From this point on, no object or archive under $BUILD_DIR is read.  Another
# agent may rebuild that dir while this snapshot is compiled and fuzzed.
mkdir -p "$work/include"
cp -- "$BUILD_DIR"/*.h "$work/include/"
# Meson may produce thin archives.  Snapshot their members too; otherwise a
# copied archive would still refer into the concurrently rebuilt build tree.
snapshot_archive() {
    local source=$1 objects_file=$2
    local name member src object index=0
    name=$(basename -- "$source")
    set --
    if [ "$(head -c 8 "$source")" = '!<thin>' ]; then
        mkdir -p "$work/objects"
        ar t "$source" > "$work/$objects_file.members"
        while IFS= read -r member; do
            src=$BUILD_DIR/$member
            if [ ! -f "$src" ]; then
                src=$member
            fi
            object=$(printf '%s/objects/%s-%04d-%s' "$work" "$objects_file" "$index" "$(basename -- "$member")")
            cp -- "$src" "$object"
            set -- "$@" "$object"
            index=$((index + 1))
        done < "$work/$objects_file.members"
    fi
    cp -- "$source" "$work/$name.thin.a"
    if [ "$#" -gt 0 ]; then
        # A regular archive is self-contained; a thin archive resolves members
        # against the linker cwd and would silently read the live $BUILD_DIR tree.
        rm -f -- "$work/$name"
        ar rcs "$work/$name" "$@"
    else
        cp -- "$work/$name.thin.a" "$work/$name"
    fi
}
for archive in libpgolib.a libvtlib.a libcommon.a libmisc.a; do
    snapshot_archive "$BUILD_DIR/$archive" "$archive"
done
snapshot_archive "$BUILD_DIR/libfootlib.a" libfootlib.a
eval "set -- $compile_flags"
cc "$@" \
    -Wl,--wrap=zwp_primary_selection_source_v1_destroy \
    -Wl,--wrap=wl_data_source_destroy \
    -Wl,--wrap=render_shim_xdg_toplevel_set_title \
    -Wl,--wrap=wayland_shim_xdg_toplevel_set_app_id \
    -Wl,--wrap=wayland_shim_data_offer_receive \
    -Wl,--wrap=wayland_shim_primary_offer_receive \
    -Wl,--wrap=wayland_shim_add_data_offer_listener \
    -Wl,--wrap=wayland_shim_add_primary_offer_listener \
    -Wl,--wrap=wayland_shim_data_offer_destroy \
    -Wl,--wrap=wayland_shim_primary_selection_offer_destroy \
    -Wl,--wrap=wayland_shim_data_offer_accept \
    -Wl,--wrap=wayland_shim_data_offer_set_actions \
    -Wl,--wrap=wayland_shim_data_offer_finish \
    tests/fuzz-vt.c "$work/libfootlib.a" $libs \
    -o "$work/fuzz-vt" 2> "$work/build.stderr"
{
    printf 'cc'
    printf ' %q' "$@"
    printf ' -Wl,--wrap=zwp_primary_selection_source_v1_destroy'
    printf ' -Wl,--wrap=wl_data_source_destroy'
    printf ' -Wl,--wrap=render_shim_xdg_toplevel_set_title'
    printf ' -Wl,--wrap=wayland_shim_xdg_toplevel_set_app_id'
    printf ' -Wl,--wrap=wayland_shim_data_offer_receive'
    printf ' -Wl,--wrap=wayland_shim_primary_offer_receive'
    printf ' -Wl,--wrap=wayland_shim_add_data_offer_listener'
    printf ' -Wl,--wrap=wayland_shim_add_primary_offer_listener'
    printf ' -Wl,--wrap=wayland_shim_data_offer_destroy'
    printf ' -Wl,--wrap=wayland_shim_primary_selection_offer_destroy'
    printf ' -Wl,--wrap=wayland_shim_data_offer_accept'
    printf ' -Wl,--wrap=wayland_shim_data_offer_set_actions'
    printf ' -Wl,--wrap=wayland_shim_data_offer_finish tests/fuzz-vt.c'
    printf ' %q' "$work/libfootlib.a"
    printf ' %s\n' "$libs"
} > "$work/build-command.txt"

completed=0
seed=1
while [ "$seed" -le "$seeds" ]; do
    artifact="$work/fail-$seed"
    : > "$artifact"
    if FUZZ_VT_FAIL="$artifact" timeout 30 \
        "$work/fuzz-vt" "$seed" 200 \
        > "$work/stdout-$seed" 2> "$work/stderr-$seed"; then
        completed=$((completed + 1))
    else
        status=$?
    echo "fuzz-vt: seed=$seed failed (status=$status)" >&2
    echo "stderr tail:" >&2
    tail -40 "$work/stderr-$seed" >&2
    echo "artifact: $artifact" >&2
    echo "fuzz-vt: FAIL seeds=$completed/$seeds seed=$seed"
    exit 1
    fi
    seed=$((seed + 1))
done
echo "fuzz-vt: PASS seeds=$completed iterations=$((completed * 200))"
