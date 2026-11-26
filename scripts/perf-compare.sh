#!/bin/sh
# Reproducible headless C-vs-Zig performance comparison for foot.
#
# Scope: pixman/pango render corpus, config parser unit corpus, VT input
# throughput, and peak RSS of each harness. Everything is built from git
# snapshots in a private /tmp work area; no tracked file is modified.
#
# Method in one paragraph: HEAD and the pinned C oracle (6b3f557d) are
# exported with git archive. The C oracle is built twice (release -O3, and
# release with an extra -O2), HEAD is built with meson release (Zig
# ReleaseSafe) and once more with a private compile_zig.py copy patched to
# ReleaseFast. Private copies of the existing test drivers are rewritten to
# run a fixed corpus N times inside one process; each configuration is timed
# in >=12 separate processes and medians/p95 are reported per unit of work.
#
# Tunables: BUILD_DIR, TMPDIR, WORK, ORACLE_REF, PERF_REPS, PERF_RENDER_ITERS,
# PERF_CONFIG_ITERS, PERF_VT_ITERS. All output lines intended for parsing
# start with "perf:".
set -eu

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
oracle_ref=${ORACLE_REF:-6b3f557d}
reps=${PERF_REPS:-12}
render_iters=${PERF_RENDER_ITERS:-10}
config_iters=${PERF_CONFIG_ITERS:-100}
vt_iters=${PERF_VT_ITERS:-2000}

# Fail early instead of producing partial, plausible-looking numbers.
for tool in git tar meson ninja zig cc python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "perf-compare: missing $tool" >&2; exit 1; }
done
head_commit=$(git -C "$root" rev-parse HEAD)
oracle_commit=$(git -C "$root" rev-parse "${oracle_ref}^{commit}")

# Reuse the four expensive builds across runs. The key contains both commits,
# so a new HEAD or oracle rebuilds; otherwise a rerun only re-measures.
# WORK=... or PERF_NO_CACHE=1 restores the old throwaway behaviour.
if [ "${PERF_NO_CACHE:-0}" = 1 ] || [ -n "${WORK:-}" ]; then
    work=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/foot-perf.XXXXXX")}
    cache=0
else
    work=${PERF_CACHE_DIR:-${TMPDIR:-/tmp}/foot-perf-cache}/head-$head_commit-oracle-$oracle_commit
    cache=1
fi
build_dir=${BUILD_DIR:-$work}
mkdir -p -- "$work" "$build_dir"
builds=$work/builds
trap 'if [ "$cache" = 0 ]; then rm -rf -- "$work"; fi' 0 1 2 3 15
export ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-$builds/zig-cache}
mkdir -p "$work/bin" "$work/logs" "$work/out" "$builds"

phase() { echo "perf: phase=$1 at=$(date -u +%FT%TZ)" >&2; }
phase start

# ---------------------------------------------------------------- sources --
if [ ! -f "$work/.sources-ok" ]; then
    phase sources
    git -C "$root" archive "$head_commit" > "$work/head.tar"
    git -C "$root" archive "$oracle_commit" > "$work/oracle.tar"
    mkdir -p "$work/head" "$work/oracle" "$work/head-fast"
    tar -xf "$work/head.tar" -C "$work/head"
    tar -xf "$work/oracle.tar" -C "$work/oracle"
    cp -a "$work/head/." "$work/head-fast/"
    # The C oracle predates this harness; use the identical HEAD corpus driver.
    cp "$work/head/tests/test-render-parity.c" "$work/oracle/tests/test-render-parity.c"

    # ReleaseFast is not reachable via meson options: compile_zig.py maps
    # release to ReleaseSafe. Patch only the private copy, then assert ninja
    # really emits -O ReleaseFast (never claim a mode that was not used).
    python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); s=p.read_text(); old="\"release\": \"ReleaseSafe\","; new="\"release\": \"ReleaseFast\","; assert s.count(old)==1, "compile_zig mapping changed"; p.write_text(s.replace(old,new))' "$work/head-fast/compile_zig.py"
    touch "$work/.sources-ok"
else
    phase sources_reused
fi

setup() { # builddir source "extra meson args"
    b=$1; src=$2; shift 2
    if [ ! -f "$b/build.ninja" ]; then
        phase setup-$(basename "$b")
        meson setup "$b" "$src" --buildtype=release -Ddocs=disabled -Dthemes=false "$@" \
            > "$work/logs/setup-$(basename "$b").log" 2>&1 || {
            echo "perf-compare: meson setup failed for $b" >&2
            tail -20 "$work/logs/setup-$(basename "$b").log" >&2; exit 1; }
    elif [ "${PERF_FORCE_BUILD:-0}" = 1 ]; then
        phase wipe-$(basename "$b")
        meson setup --wipe "$b" "$src" --buildtype=release -Ddocs=disabled -Dthemes=false "$@" \
            > "$work/logs/setup-$(basename "$b").log" 2>&1 || {
            echo "perf-compare: meson setup --wipe failed for $b" >&2
            tail -20 "$work/logs/setup-$(basename "$b").log" >&2; exit 1; }
    fi
    # The pre-port oracle has no meson target for the render driver; its
    # private harness is linked by mkrender.py from the foot link line.
    targets="foot tests/test-config"
    case $b in *zig-*) targets="$targets tests/test-render-parity" ;; esac
    phase build-$(basename "$b")
    ninja -C "$b" -j4 $targets \
        > "$work/logs/build-$(basename "$b").log" 2>&1 || {
        echo "perf-compare: build failed for $b" >&2
        tail -30 "$work/logs/build-$(basename "$b").log" >&2; exit 1; }
}
setup "$builds/zig-rs" "$work/head"
setup "$builds/zig-fast" "$work/head-fast"
for mode in o2 o3; do
    if [ "$mode" = o2 ]; then extra="-Dc_args=-O2"; else extra=; fi
    setup "$builds/c-$mode" "$work/oracle" $extra
done
python3 -c 'import pathlib,subprocess,sys; s=pathlib.Path(sys.argv[2]).read_text(); assert s.count("\"release\": \"ReleaseFast\",") == 1, "compile_zig mapping unchanged"; ls=subprocess.run(["ninja","-C",sys.argv[1],"-t","commands"],capture_output=True,text=True,check=True).stdout.splitlines(); zl=[l for l in ls if "compile_zig.py" in l]; assert len(zl) > 10, "zig compile commands missing"; print("perf: mode_check=zig-fast optimize=ReleaseFast zig_modules=%d" % len(zl))' "$builds/zig-fast" "$work/head-fast/compile_zig.py"

phase builds_done

# ------------------------------------------------------------- tool copies --
# These helpers are deliberately written into WORK: they patch private source
# copies and derive compile/link commands from ninja instead of hardcoding
# flags. No file under root is touched.
python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])' "$work/bin/mkconfig.py" '
import os, pathlib, re, shlex, subprocess, sys
build, source, output, iterations = sys.argv[1:]
TESTS = """test_section_main test_section_security test_section_bell
test_section_desktop_notifications test_section_scrollback test_section_url
test_section_cursor test_section_mouse test_section_touch
test_section_colors_dark test_section_colors_light test_section_csd
test_section_key_bindings test_section_key_bindings_collisions
test_section_search_bindings test_section_search_bindings_collisions
test_section_url_bindings test_section_url_bindings_collisions
test_section_mouse_bindings test_section_mouse_bindings_collisions
test_section_text_bindings test_section_environment test_section_tweak""".split()
body = "\n".join("        %s();" % name for name in TESTS)
main = """
int
main(int argc, const char *const *argv)
{
    unsigned n = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 0) : %s;
    if (n == 0 || n > 1000000) return 2;
    FcInit();
    log_init(LOG_COLORIZE_AUTO, false, 0, LOG_CLASS_ERROR);
    for (unsigned i = 0; i < n; i++) {
%s
    }
    log_deinit();
    FcFini();
    printf("config: iterations=%%u: ok ", n); putchar(10);
    return 0;
}
""" % (iterations, body)
src = pathlib.Path(source).read_text()
patched, count = re.subn(r"\nint\nmain\([^)]*\)\n\{.*\Z", main, src, count=1, flags=re.S)
assert count == 1, "cannot patch config main"
patched = "#undef NDEBUG\n#include <stdlib.h>\n#include <stdio.h>\n" + patched
src_out = os.path.join(os.path.dirname(os.path.abspath(output)), "perf-config.c")
pathlib.Path(src_out).write_text(patched)
def commands(target):
    return subprocess.run(["ninja", "-C", build, "-t", "commands", target], capture_output=True, text=True, check=True).stdout.splitlines()
cw = shlex.split(next(l for l in commands("tests/test-config") if " -c " in l and "test-config.c" in l))
cw[cw.index("-c") + 1] = src_out
obj = os.path.join(build, "perf-config.o")
cw[cw.index("-o") + 1] = obj
cw[1:1] = ["-UNDEBUG", "-Wno-unused-function"]
subprocess.run(cw, cwd=build, check=True)
lw = shlex.split(next(l for l in commands("tests/test-config") if " -o tests/test-config " in l))
for i, w in enumerate(lw):
    if w.endswith("tests/test-config.p/test-config.c.o"):
        lw[i] = obj
lw[lw.index("-o") + 1] = os.path.abspath(output)
subprocess.run(lw, cwd=build, check=True)
print(shlex.join(lw))
'

python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])' "$work/bin/mkrender.py" '
import os, pathlib, re, shlex, subprocess, sys
build, source, output, iterations, kind = sys.argv[1:]
def commands(target):
    return subprocess.run(["ninja", "-C", build, "-t", "commands", target], capture_output=True, text=True, check=True).stdout.splitlines()
def sub_compile(template, src, obj, extra=()):
    words = shlex.split(template)
    words[words.index("-c") + 1] = src
    words[words.index("-o") + 1] = obj
    for flag in ("-MF", "-MQ"):
        if flag in words:
            words[words.index(flag) + 1] = obj + ".d"
    words[1:1] = ["-Wno-unused-variable", "-Wno-unused-function"] + list(extra)
    subprocess.run(words, cwd=build, check=True)
src = pathlib.Path(source).read_text()
for pattern, nwant in ((r"\n\s*hash_cells\(&c,.*?\);", 9), (r"\n\s*printf\(\"TOTAL [^;]+;", 1), (r"\n\s*printf\(\"SCALE [^;]+;", 1)):
    src, n = re.subn(pattern, "", src, flags=re.S)
    assert n == nwant, "render patch count %d != %d" % (n, nwant)
main = """
int
main(void)
{
    setlocale(LC_ALL, "C.UTF-8");
    if (!fcft_init(FCFT_LOG_COLORIZE_AUTO, false, FCFT_LOG_CLASS_ERROR)) {
        fprintf(stderr, "render-perf: fcft_init() failed"); putchar(10);
        return 1;
    }
    for (int i = 0; i < %s; i++) {
        run_scale(126.0f / 120.0f);
        run_scale(100.0f / 120.0f);
        run_scale(2.0f);
    }
    fcft_fini();
    puts("render: ok");
    return 0;
}
""" % iterations
src, n = re.subn(r"\nint\nmain\(void\)\n\{.*\Z", main, src, count=1, flags=re.S)
assert n == 1, "cannot patch render main"
perfsrc = os.path.join(os.path.dirname(os.path.abspath(output)), "perf-render-" + kind + ".c")
pathlib.Path(perfsrc).write_text(src)
wraps = ["-Wl,--wrap=" + n for n in ("wl_surface_attach", "wl_surface_damage_buffer", "wl_surface_commit", "wl_surface_set_buffer_scale", "wayland_shim_viewport_set_destination")]
test_obj = os.path.join(build, "perf-render-" + kind + ".o")
if kind == "zig":
    compile_line = next(l for l in commands("tests/test-render-parity") if " -c " in l and "test-render-parity.c" in l)
    link_line = next(l for l in commands("tests/test-render-parity") if " -o tests/test-render-parity " in l)
    sub_compile(compile_line, perfsrc, test_obj)
    lw = shlex.split(link_line)
    for i, w in enumerate(lw):
        if w.endswith("tests/test-render-parity.p/test-render-parity.c.o"):
            lw[i] = test_obj
else:
    root = pathlib.Path(source).parent.parent
    render = (root / "render.c").read_text()
    for name in ("render_cell", "render_osd", "render_csd_border", "render_csd_title", "render_sixel_images"):
        render, n = re.subn(r"\bstatic\s+(int|void)\s+" + name + r"\s*\(", r"\1 " + name + "(", render)
        assert n == 1, "cannot expose " + name
    for pattern, repl in ((r"wl_surface_attach\(surf->surf, buf->wl_buf, 0, 0\);", "(void)surf;"), (r"wl_surface_damage_buffer\(surf->surf, 0, 0, buf->width, buf->height\);", "(void)surf;"), (r"wl_surface_commit\(surf->surf\);", "(void)surf;"), (r"wl_surface_attach\(sub_surf->surface\.surf.*?wl_surface_commit\(sub_surf->surface\.surf\);", "(void)sub_surf;")):
        render, n = re.subn(pattern, repl, render, flags=re.S)
        assert n == 1, "render protocol patch failed"
    render = render.replace("quirk_weston_subsurface_desync_on(sub_surf->sub);", "").replace("quirk_weston_subsurface_desync_off(sub_surf->sub);", "")
    wayland = (root / "wayland.c").read_text()
    wayland, n = re.subn(r"wl_surface_set_buffer_scale\(surf->surf, [^;]+;", "(void)surf;", wayland)
    assert n == 2, "wayland scale patches"
    wayland, n = re.subn(r"wp_viewport_set_destination\(\s*surf->viewport,[^;]+;", "(void)surf;", wayland, flags=re.S)
    assert n == 1, "wayland viewport patch"
    patched = os.path.join(os.path.dirname(os.path.abspath(output)), "render-oracle.c")
    wpatched = os.path.join(os.path.dirname(os.path.abspath(output)), "wayland-oracle.c")
    pathlib.Path(patched).write_text(render)
    pathlib.Path(wpatched).write_text(wayland)
    compile_line = next(l for l in commands("foot") if " -c " in l and "foot.p/render.c.o" in l)
    link_line = commands("foot")[-1]
    sub_compile(compile_line, patched, os.path.join(build, "render-oracle.o"))
    sub_compile(compile_line, wpatched, os.path.join(build, "wayland-oracle.o"))
    sub_compile(compile_line, perfsrc, test_obj, ("-DFOOT_RENDER_PARITY_C_ORACLE",))
    lw = shlex.split(link_line)
    for i, w in enumerate(lw):
        if w.endswith("foot.p/main.c.o"):
            lw[i] = test_obj
        elif w.endswith("foot.p/render.c.o"):
            lw[i] = os.path.join(build, "render-oracle.o")
        elif w.endswith("foot.p/wayland.c.o"):
            lw[i] = os.path.join(build, "wayland-oracle.o")
lw[lw.index("-o") + 1] = os.path.abspath(output)
lw[1:1] = wraps
subprocess.run(lw, cwd=build, check=True)
print(shlex.join(lw))
'

python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])' "$work/bin/mkvt.py" '
import os, shlex, subprocess, sys
build, source, output = sys.argv[1:]
def commands(target):
    return subprocess.run(["ninja", "-C", build, "-t", "commands", target], capture_output=True, text=True, check=True).stdout.splitlines()
words = shlex.split(next(l for l in commands("foot") if " -c " in l))
keep = []
for w in words[1:]:
    if w == "-MD":
        break
    if w.startswith(("-I", "-D")) or w in {"-fdiagnostics-color=always", "-D_FILE_OFFSET_BITS=64", "-Wall", "-Winvalid-pch", "-Werror", "-std=c11", "-O0", "-g", "-pedantic", "-fstrict-aliasing", "-Wstrict-aliasing", "-fPIC", "-pthread"}:
        keep.append(w)
obj = os.path.join(build, "perf-vt.o")
subprocess.run(["cc"] + keep + ["-c", source, "-o", obj], cwd=build, check=True)
lw = shlex.split(commands("foot")[-1])
for i, w in enumerate(lw):
    if w.endswith("foot.p/main.c.o") or w == "main.o":
        lw[i] = obj
lw[lw.index("-o") + 1] = os.path.abspath(output)
wraps = ["-Wl,--wrap=" + n for n in ("zwp_primary_selection_source_v1_destroy", "wl_data_source_destroy", "render_shim_xdg_toplevel_set_title", "wayland_shim_xdg_toplevel_set_app_id", "wayland_shim_data_offer_receive", "wayland_shim_primary_offer_receive", "wayland_shim_add_data_offer_listener", "wayland_shim_add_primary_offer_listener", "wayland_shim_data_offer_destroy", "wayland_shim_primary_selection_offer_destroy", "wayland_shim_data_offer_accept", "wayland_shim_data_offer_set_actions", "wayland_shim_data_offer_finish")]
lw[1:1] = wraps
subprocess.run(lw, cwd=build, check=True)
print(shlex.join(lw))
'

# A single shared VT driver source, compiled against both implementations.
python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])' "$work/bin/vt-throughput.c" '
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "terminal.h"
#include "vt.h"
#include "grid.h"
#include "config.h"
#include "wayland.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
enum { ROWS = 8, COLS = 80 };
#define NOOP_WRAP(name, args) void __wrap_##name args
NOOP_WRAP(zwp_primary_selection_source_v1_destroy, (void *p) { (void)p; })
NOOP_WRAP(wl_data_source_destroy, (void *p) { (void)p; })
NOOP_WRAP(render_shim_xdg_toplevel_set_title, (void *p, const char *t) { (void)p; (void)t; })
NOOP_WRAP(wayland_shim_xdg_toplevel_set_app_id, (void *p, const char *a) { (void)p; (void)a; })
NOOP_WRAP(wayland_shim_data_offer_receive, (void *p, const char *m, int f) { (void)p; (void)m; (void)f; })
NOOP_WRAP(wayland_shim_primary_offer_receive, (void *p, const char *m, int f) { (void)p; (void)m; (void)f; })
NOOP_WRAP(wayland_shim_add_data_offer_listener, (void *p, void *l, void *u) { (void)p; (void)l; (void)u; })
NOOP_WRAP(wayland_shim_add_primary_offer_listener, (void *p, void *l, void *u) { (void)p; (void)l; (void)u; })
NOOP_WRAP(wayland_shim_data_offer_destroy, (void *p) { (void)p; })
NOOP_WRAP(wayland_shim_primary_selection_offer_destroy, (void *p) { (void)p; })
NOOP_WRAP(wayland_shim_data_offer_accept, (void *p, unsigned m, const char *t) { (void)p; (void)m; (void)t; })
NOOP_WRAP(wayland_shim_data_offer_set_actions, (void *p, unsigned a, unsigned d) { (void)p; (void)a; (void)d; })
NOOP_WRAP(wayland_shim_data_offer_finish, (void *p) { (void)p; })
static const char input[] =
    "The quick brown fox jumps over the lazy dog 0123456789 "
    "\x1b[31mred\x1b[32mgreen\x1b[0m\x1b[1mbold\x1b[22m"
    "\x1b[10;20Hcursor\x1b[4h\x1b[?25l\x1b[?25h"
    "\x1b[38;5;196m256color\x1b[38;2;1;2;3mtruecolor\x1b[0m"
    "\x1b[12;34H";
static void init_grid(struct grid *grid, bool populate)
{
    grid->rows = calloc(ROWS, sizeof(*grid->rows));
    if (grid->rows == NULL) exit(3);
    grid->num_rows = ROWS; grid->num_cols = COLS;
    grid->offset = 0; grid->view = 0;
    for (int r = 0; r < ROWS; r++) {
        struct row *row = calloc(1, sizeof(*row));
        if (row == NULL) exit(3);
        row->cells = calloc(COLS, sizeof(*row->cells));
        if (row->cells == NULL) exit(3);
        row->linebreak = true;
        if (populate)
            for (int c = 0; c < COLS; c++) row->cells[c].wc = 32;
        grid->rows[r] = row;
    }
    grid->cur_row = grid->rows[0];
}
int main(int argc, char **argv)
{
    unsigned iterations = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 0) : 2000;
    if (iterations == 0 || iterations > 1000000) return 2;
    static struct terminal term;
    static struct config conf;
    memset(&term, 0, sizeof(term)); memset(&conf, 0, sizeof(conf));
    term.rows = ROWS; term.cols = COLS; term.grid = &term.normal;
    init_grid(&term.normal, true); init_grid(&term.alt, false);
    term.scroll_region.end = ROWS; term.auto_margin = true;
    term.charsets.selected = G0;
    for (size_t i = 0; i < 4; i++) term.charsets.set[i] = CHARSET_ASCII;
    term.selection.coords.start = (struct coord){-1, -1};
    term.selection.coords.end = (struct coord){-1, -1};
    term.selection.kind = SELECTION_NONE;
    term.cell_width = 1; term.cell_height = 1; term.scale = 1.0f;
    term.conf = &conf;
    term_update_ascii_printer(&term);
    int ptmx = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (ptmx < 0 || grantpt(ptmx) != 0 || unlockpt(ptmx) != 0) return 3;
    const char *slave_name = ptsname(ptmx);
    if (slave_name == NULL) return 3;
    int slave = open(slave_name, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (slave < 0) return 3;
    term.ptmx = ptmx;
    size_t len = strlen(input);
    for (unsigned i = 0; i < iterations; i++) {
        size_t pos = 0;
        while (pos < len) {
            size_t chunk = 1 + (i % 3) * 61;
            if (chunk > len - pos) chunk = len - pos;
            vt_from_slave(&term, (const uint8_t *)input + pos, chunk);
            pos += chunk;
        }
        char drain[512];
        while (read(slave, drain, sizeof(drain)) > 0) {}
    }
    uint64_t hash = 1469598103934665603ULL;
    for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < COLS; c++) {
            hash ^= (uint64_t)term.normal.rows[r]->cells[c].wc;
            hash *= 1099511628211ULL;
        }
    printf("vt: iterations=%u bytes=%zu hash=%016llx: ok\n", iterations, len * iterations, (unsigned long long)hash);
    close(slave); close(ptmx);
    return 0;
}
'

python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])' "$work/bin/stats.py" '
import math, os, re, resource, statistics, subprocess, sys, time
label, variant, bench, binary, reps, inner, unit, expect = sys.argv[1:9]
inner = int(inner)
extra = list(sys.argv[9:])
if bench in ("config", "vt"):
    extra.append(str(inner))
samples, result_hash = [], ""
for _ in range(int(reps)):
    start = time.perf_counter_ns()
    p = subprocess.run([binary] + extra, capture_output=True, text=True)
    samples.append((time.perf_counter_ns() - start) / 1e6)
    if p.returncode != 0 or expect not in p.stdout:
        sys.stderr.write(p.stdout[-800:] + p.stderr[-800:])
        raise SystemExit("measurement failed: " + label + " " + variant + " " + bench)
    m = re.search(r"hash=([0-9a-f]+)", p.stdout)
    if m:
        if result_hash and result_hash != m.group(1):
            raise SystemExit("non-deterministic VT result")
        result_hash = m.group(1)
s = sorted(samples)
median, p95 = statistics.median(s), s[min(len(s) - 1, math.ceil(len(s) * 0.95) - 1)]
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
fields = ["perf:", "benchmark=" + bench, "variant=" + variant, "reps=" + str(len(s)),
          "inner=" + str(inner), "unit=" + unit, "median_ms_per_run=%.3f" % median,
          "p95_ms_per_run=%.3f" % p95, "median_us_per_unit=%.2f" % (median * 1000 / inner),
          "p95_us_per_unit=%.2f" % (p95 * 1000 / inner), "rss_kib=" + str(rss),
          "samples_ms=" + ",".join("%.2f" % v for v in s)]
if result_hash:
    fields.append("result_hash=" + result_hash)
print(" ".join(fields))
'

# ------------------------------------------------------------- harnesses ---
harness="$work/out"
python3 "$work/bin/mkrender.py" "$builds/zig-rs" "$work/head/tests/test-render-parity.c" "$harness/render-zig-rs" "$render_iters" zig > "$work/logs/harness.log" 2>&1
python3 "$work/bin/mkrender.py" "$builds/zig-fast" "$work/head-fast/tests/test-render-parity.c" "$harness/render-zig-fast" "$render_iters" zig >> "$work/logs/harness.log" 2>&1
python3 "$work/bin/mkrender.py" "$builds/c-o3" "$work/oracle/tests/test-render-parity.c" "$harness/render-c-o3" "$render_iters" c >> "$work/logs/harness.log" 2>&1
python3 "$work/bin/mkrender.py" "$builds/c-o2" "$work/oracle/tests/test-render-parity.c" "$harness/render-c-o2" "$render_iters" c >> "$work/logs/harness.log" 2>&1
for v in zig-rs zig-fast c-o3 c-o2; do
    src="$work/head/tests/test-config.c"; b="$builds/$v"
    case $v in c-*) src="$work/oracle/tests/test-config.c" ;; esac
    python3 "$work/bin/mkconfig.py" "$b" "$src" "$harness/config-$v" "$config_iters" >> "$work/logs/harness.log" 2>&1
    python3 "$work/bin/mkvt.py" "$b" "$work/bin/vt-throughput.c" "$harness/vt-$v" >> "$work/logs/harness.log" 2>&1
done

cells=$(python3 -c 'import subprocess,sys; out=subprocess.run([sys.argv[1]],capture_output=True,text=True,check=True).stdout; print(sum(l.startswith("CELL ") for l in out.splitlines()))' "$builds/zig-rs/tests/test-render-parity")
[ "$cells" -gt 0 ] || { echo "perf-compare: empty render corpus" >&2; exit 1; }
echo "perf: benchmark=cells count=$cells scales=3 head=$head_commit oracle=$oracle_commit"
echo "perf: settings reps=$reps render_iters=$render_iters config_iters=$config_iters vt_iters=$vt_iters date=$(date -u +%FT%TZ)"
python3 -c 'import os,platform,subprocess; print("perf: env cpu=" + next(l.split(":",1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")) + " cpus=" + str(os.cpu_count()) + " zig=" + subprocess.check_output(["zig","version"],text=True).strip() + " cc=" + subprocess.check_output(["cc","--version"],text=True).splitlines()[0] + " meson=" + subprocess.check_output(["meson","--version"],text=True).strip() + " python=" + platform.python_version())'
for v in o3 o2; do
    python3 -c 'import shlex,subprocess,sys; ls=subprocess.run(["ninja","-C",sys.argv[1],"-t","commands","foot"],capture_output=True,text=True,check=True).stdout.splitlines(); w=shlex.split(next(l for l in ls if " -c " in l)); print("perf: c_variant=" + sys.argv[2] + " cc_flags=" + " ".join(x for x in w if x.startswith("-O") or x.startswith("-fno-asynchronous")))' "$builds/c-$v" "$v"
done

measure() { # bench variant binary inner unit expect
    python3 "$work/bin/stats.py" "$1" "$2" "$3" "$4" "$reps" "$5" "$6" "$7"
}
for benchmark in render config vt; do
    for variant in c-o3 c-o2 zig-rs zig-fast; do
        case $benchmark in
            render) inner=$render_iters; unit=corpus_runs; expect="render: ok" ;;
            config) inner=$config_iters; unit=config_suites; expect="config: iterations=" ;;
            vt) inner=$vt_iters; unit=vt_sequences; expect="vt: iterations=" ;;
        esac
        measure "$benchmark" "$variant" "$benchmark" "$harness/$benchmark-$variant" "$inner" "$unit" "$expect"
    done
done
echo "perf: not_measured=startup_to_first_frame reason=no_compositor"
echo "perf: not_measured=fps_input_latency reason=no_compositor"
echo "perf-compare: complete"
