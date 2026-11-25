#!/usr/bin/env bash
# Build and compare the headless pixman corpus against origin/master.
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=/tmp/agent-c/render-parity
oracle=/tmp/agent-c/c-oracle
mkdir -p "$work"
exec 9>"$work/lock"
flock 9
export ZIG_GLOBAL_CACHE_DIR=/tmp/agent-c/zig-cache

ninja -C "$root/build" -j4 tests/test-terminal > "$work/zig-build.log" 2>&1
zig_compile=$(ninja -C "$root/build" -t commands tests/test-terminal |
    grep -F ' -c ../tests/test-terminal.c' | head -1)
zig_link=$(ninja -C "$root/build" -t commands tests/test-terminal |
    grep -F ' -o tests/test-terminal ' | head -1)

python3 - "$zig_compile" "$root/tests/test-render-parity.c" \
    "$work/test-zig.o" "$root/build" <<'PY'
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

python3 - "$zig_link" "$work/test-zig.o" "$work/test-zig" "$root/build" <<'PY'
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

if [ ! -e "$oracle/.git" ]; then
    git -C "$root" worktree add --detach "$oracle" origin/master
fi
want=$(git -C "$root" rev-parse origin/master)
if [ "$(git -C "$oracle" rev-parse HEAD)" != "$want" ]; then
    git -C "$oracle" checkout --detach "$want"
fi
cp "$root/tests/test-render-parity.c" "$oracle/tests/test-render-parity.c"
if [ ! -f "$oracle/build-parity/meson-info/intro-buildoptions.json" ]; then
    meson setup "$oracle/build-parity" "$oracle" \
        -Ddocs=disabled -Dthemes=false > "$work/c-setup.log" 2>&1
fi
ninja -C "$oracle/build-parity" -j4 foot > "$work/c-build.log" 2>&1

# origin/master keeps the corpus painters static. Remove only these linkage
# qualifiers in private source copies. Function bodies stay unchanged, except
# that generated Wayland protocol requests are replaced with no-ops: the corpus
# has no compositor connection.
python3 - "$oracle/render.c" "$work/render-oracle.c" \
    "$oracle/wayland.c" "$work/wayland-oracle.c" <<'PY'
import pathlib
import re
import sys

render = pathlib.Path(sys.argv[1]).read_text()
for name in ("render_cell", "render_osd", "render_csd_border", "render_csd_title"):
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
    echo "render-parity: PASS ($(grep -c '^CELL ' "$work/zig.hashes") cells, 2 scales)"
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

