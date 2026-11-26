#!/usr/bin/env bash
# Build and compare the headless pixman corpus against a pinned C oracle.
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# Zig build dir under test. Default is unchanged ($root/build); a relative
# override is resolved against the repo root, not the caller's cwd.
BUILD_DIR=${BUILD_DIR:-$root/build}
case $BUILD_DIR in
    /*) ;;
    *) BUILD_DIR=$root/$BUILD_DIR ;;
esac
WORK=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/foot-render-parity.XXXXXX")}
ORACLE_REF=${ORACLE_REF:-6b3f557d}
work=$WORK
oracle=$work/oracle
mkdir -p "$work"
exec 9>"$work/lock"
flock 9

cleanup() {
    rc=$?
    trap - EXIT
    git -C "$root" worktree remove --force "$oracle" >/dev/null 2>&1 || true
    git -C "$root" worktree prune >/dev/null 2>&1 || true
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT

export ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-$work/zig-cache}

# Never let a hash dump from an earlier run (or a failed build) be compared
# as if it were this run's result.
rm -f "$work/c.hashes" "$work/zig.hashes"

if ! git -C "$root" cat-file -e "${ORACLE_REF}^{commit}" 2>/dev/null; then
    echo "render-parity: oracle ref '$ORACLE_REF' is missing from $root" >&2
    exit 1
fi
if [ -e "$oracle" ]; then
    # A reused WORK is fine only if its worktree is still the pinned commit.
    want=$(git -C "$root" rev-parse "${ORACLE_REF}^{commit}")
    have=$(git -C "$oracle" rev-parse HEAD 2>/dev/null || true)
    if [ "$have" != "$want" ]; then
        echo "render-parity: $oracle is at '$have', not '$want' (use a fresh WORK=...)" >&2
        exit 1
    fi
elif ! git -C "$root" worktree add --detach "$oracle" "$ORACLE_REF" \
        > "$work/c-worktree.log" 2>&1; then
    echo "render-parity: could not create oracle worktree at $ORACLE_REF" >&2
    tail -20 "$work/c-worktree.log" >&2
    exit 1
fi

if ! ninja -C "$BUILD_DIR" -j4 tests/test-terminal > "$work/zig-build.log" 2>&1; then
    echo "render-parity: Zig build failed (see $work/zig-build.log)" >&2
    exit 1
fi
zig_compile=$(ninja -C "$BUILD_DIR" -t commands tests/test-terminal |
    grep -F ' -c ../tests/test-terminal.c' | head -1)
zig_link=$(ninja -C "$BUILD_DIR" -t commands tests/test-terminal |
    grep -F ' -o tests/test-terminal ' | head -1)

python3 - "$zig_compile" "$root/tests/test-render-parity.c" \
    "$work/test-zig.o" "$BUILD_DIR" <<'PY'
import shlex
import subprocess
import sys

template, source, output, build = sys.argv[1:]
words = shlex.split(template)
words[words.index("-c") + 1] = source
words[words.index("-o") + 1] = output
for flag in ("-MF", "-MQ"):
    if flag in words:
        words[words.index(flag) + 1] = output + ".d"
subprocess.run(words, cwd=build, check=True)
PY

python3 - "$zig_link" "$work/test-zig.o" "$work/test-zig" "$BUILD_DIR" <<'PY'
import shlex
import subprocess
import sys

template, obj, output, build = sys.argv[1:]
words = shlex.split(template)
for i, word in enumerate(words):
    if word.endswith("tests/test-terminal.p/test-terminal.c.o"):
        words[i] = obj
words[words.index("-o") + 1] = output
wraps = [
    "-Wl,--wrap=wl_surface_attach",
    "-Wl,--wrap=wl_surface_damage_buffer",
    "-Wl,--wrap=wl_surface_commit",
    "-Wl,--wrap=wl_surface_set_buffer_scale",
    "-Wl,--wrap=wayland_shim_viewport_set_destination",
]
words[1:1] = wraps
subprocess.run(words, cwd=build, check=True)
PY
"$work/test-zig" > "$work/zig.hashes"

cp "$root/tests/test-render-parity.c" "$oracle/tests/test-render-parity.c"
if [ ! -f "$oracle/build-parity/meson-info/intro-buildoptions.json" ] &&
        ! meson setup "$oracle/build-parity" "$oracle" \
            -Ddocs=disabled -Dthemes=false > "$work/c-setup.log" 2>&1; then
    echo "render-parity: C oracle setup failed (see $work/c-setup.log)" >&2
    exit 1
fi
if ! ninja -C "$oracle/build-parity" -j4 foot > "$work/c-build.log" 2>&1; then
    echo "render-parity: C oracle build failed (see $work/c-build.log)" >&2
    exit 1
fi

# The pinned C oracle keeps the corpus painters static. Remove only these linkage
# qualifiers in private source copies. Function bodies stay unchanged, except
# that generated Wayland protocol requests are replaced with no-ops: the corpus
# has no compositor connection.
python3 - "$oracle/render.c" "$work/render-oracle.c" \
    "$oracle/wayland.c" "$work/wayland-oracle.c" <<'PY'
import pathlib
import re
import sys

render = pathlib.Path(sys.argv[1]).read_text()
for name in ("render_cell", "render_osd", "render_csd_border", "render_csd_title", "render_sixel_images"):
    pattern = r"\bstatic\s+(int|void)\s+" + name + r"\s*\("
    render, count = re.subn(pattern, r"\1 " + name + "(", render)
    if count != 1:
        raise SystemExit(f"cannot expose {name}: count={count}")
render, count = re.subn(
    r"wl_surface_attach\(surf->surf, buf->wl_buf, 0, 0\);",
    "(void)surf;", render)
render, count2 = re.subn(
    r"wl_surface_damage_buffer\(surf->surf, 0, 0, buf->width, buf->height\);",
    "(void)surf;", render)
render, count3 = re.subn(r"wl_surface_commit\(surf->surf\);", "(void)surf;", render)
if (count, count2, count3) != (1, 1, 1):
    raise SystemExit("csd_commit protocol no-op replacement failed")
render, count = re.subn(
    r"wl_surface_attach\(sub_surf->surface\.surf.*?wl_surface_commit\(sub_surf->surface\.surf\);",
    "(void)sub_surf;", render, flags=re.S)
if count != 1:
    raise SystemExit("render_osd protocol no-op replacement failed")
render = render.replace("quirk_weston_subsurface_desync_on(sub_surf->sub);", "")
render = render.replace("quirk_weston_subsurface_desync_off(sub_surf->sub);", "")
pathlib.Path(sys.argv[2]).write_text(render)

wayland = pathlib.Path(sys.argv[3]).read_text()
wayland, count = re.subn(
    r"wl_surface_set_buffer_scale\(surf->surf, [^;]+;", "(void)surf;", wayland)
if count != 2:
    raise SystemExit(f"wayland buffer scale replacements: {count}")
wayland, count = re.subn(
    r"wp_viewport_set_destination\(\s*surf->viewport,[^;]+;",
    "(void)surf;", wayland, flags=re.S)
if count != 1:
    raise SystemExit(f"wayland viewport replacements: {count}")
pathlib.Path(sys.argv[4]).write_text(wayland)
PY

c_compile=$(ninja -C "$oracle/build-parity" -t commands foot |
    grep -F ' -c ../render.c' | head -1)
c_link=$(ninja -C "$oracle/build-parity" -t commands foot |
    grep -F ' -o foot ' | head -1)

python3 - "$c_compile" "$work/render-oracle.c" "$work/render-oracle.o" \
    "$oracle/build-parity" <<'PY'
import shlex
import subprocess
import sys

template, source, output, build = sys.argv[1:]
words = shlex.split(template)
words[words.index("-c") + 1] = source
words[words.index("-o") + 1] = output
for flag in ("-MF", "-MQ"):
    if flag in words:
        words[words.index(flag) + 1] = output + ".d"
subprocess.run(words, cwd=build, check=True)
PY

python3 - "$c_compile" "$work/wayland-oracle.c" "$work/wayland-oracle.o" \
    "$oracle/build-parity" <<'PY'
import shlex
import subprocess
import sys

template, source, output, build = sys.argv[1:]
words = shlex.split(template)
words[words.index("-c") + 1] = source
words[words.index("-o") + 1] = output
for flag in ("-MF", "-MQ"):
    if flag in words:
        words[words.index(flag) + 1] = output + ".d"
subprocess.run(words, cwd=build, check=True)
PY

python3 - "$c_compile" "$oracle/tests/test-render-parity.c" \
    "$work/test-c.o" "$oracle/build-parity" <<'PY'
import shlex
import subprocess
import sys

template, source, output, build = sys.argv[1:]
words = shlex.split(template)
words[words.index("-c") + 1] = source
words[words.index("-o") + 1] = output
for flag in ("-MF", "-MQ"):
    if flag in words:
        words[words.index(flag) + 1] = output + ".d"
words.insert(1, "-DFOOT_RENDER_PARITY_C_ORACLE")
subprocess.run(words, cwd=build, check=True)
PY

python3 - "$c_link" "$work/test-c.o" "$work/render-oracle.o" \
    "$work/wayland-oracle.o" "$work/test-c" "$oracle/build-parity" <<'PY'
import shlex
import subprocess
import sys

template, test_obj, render_obj, wayland_obj, output, build = sys.argv[1:]
words = shlex.split(template)
for i, word in enumerate(words):
    if word.endswith("foot.p/main.c.o"):
        words[i] = test_obj
    elif word.endswith("foot.p/render.c.o"):
        words[i] = render_obj
    elif word.endswith("foot.p/wayland.c.o"):
        words[i] = wayland_obj
words[words.index("-o") + 1] = output
wraps = [
    "-Wl,--wrap=wl_surface_attach",
    "-Wl,--wrap=wl_surface_damage_buffer",
    "-Wl,--wrap=wl_surface_commit",
    "-Wl,--wrap=wl_surface_set_buffer_scale",
    "-Wl,--wrap=wayland_shim_viewport_set_destination",
]
words[1:1] = wraps
subprocess.run(words, cwd=build, check=True)
PY
"$work/test-c" > "$work/c.hashes"

if cmp -s "$work/c.hashes" "$work/zig.hashes"; then
    echo "render-parity: PASS ($(grep -c '^CELL ' "$work/zig.hashes") cells, 3 scales)"
    grep '^TOTAL ' "$work/zig.hashes"
    exit 0
fi

echo "render-parity: FAIL" >&2
diff -u "$work/c.hashes" "$work/zig.hashes" | head -80 >&2 || true
python3 - "$work/c.hashes" "$work/zig.hashes" <<'PY'
import sys

c = open(sys.argv[1]).read().splitlines()
z = open(sys.argv[2]).read().splitlines()
for i, (left, right) in enumerate(zip(c, z), 1):
    if left != right:
        kind = left.split()[0] if left else "EOF"
        print(f"first difference at line {i} ({kind}):", file=sys.stderr)
        print(f"  C:   {left}", file=sys.stderr)
        print(f"  Zig: {right}", file=sys.stderr)
        break
else:
    print("first difference: file length", file=sys.stderr)
PY
exit 1

