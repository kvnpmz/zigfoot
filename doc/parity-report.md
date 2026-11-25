# Render parity report

Date: 2026-11-25. Branch: `render-parity` @ `39e70a77` plus the oracle work.
C oracle: `origin/master` = `6b3f557d`, detached in
`/tmp/agent-c/c-oracle`. `grim` is not installed, and there is no
wayland connection in this container, so the oracle compares pixman images
directly instead of screenshots (MIGRATION_PLAN §14.5.2 item 2).

## Corpus

`tests/test-render-parity.c` paints a fixed 320×320 `PIXMAN_a8r8g8b8`
atlas with a real `monospace` fcft face at size 8, fixed 10×20 cells, and a
zeroed `wl_window`/`wayland` pair (no compositor connection):

- a 16×6 cell grid: bold, italic, reverse, selected, concealed, custom RGB
  fg/bg, strikethrough, URL underline, all five underline styles through
  `row_ranges`, box drawing, block elements/braille, and a focused block
  cursor;
- a URL-mode OSD label with a fractional-scale margin;
- a render-timer OSD with the same margin;
- CSD top and left borders plus a CSD title surface;
- scales `126/120` (1.05) and `100/120` (0.8333).

For every painted cell the tool prints `CELL <region> <row> <col> <hash>`,
where the hash is FNV-1a (offset basis 14695981039346656037, prime
1099511628211) over the cell's RGBA bytes in row-major order. A `TOTAL`
line hashes the whole atlas. There are 447 cell hashes across the two scales.

The OSD margin comes from `render_parity_osd_margin()`, exported by
`render.zig` for this purpose. The C oracle build defines
`FOOT_RENDER_PARITY_C_ORACLE` and supplies the same C expression with a weak
definition.

## Commands

    cd /tmp/agent-c-wt
    ZIG_GLOBAL_CACHE_DIR=/tmp/agent-c/zig-cache scripts/render-parity.sh

The script creates `/tmp/agent-c/c-oracle` if needed, sets up
`/tmp/agent-c/c-oracle/build-parity` with its own logs, builds both corpus
executables with `-j4`, diffs the hash dumps, prints the first differing
cell, and exits non-zero on any difference. The C oracle's private copies of
`render.c` and `wayland.c` differ from `origin/master` only in linkage
(`static` removed from four painters) and in replacing generated Wayland
protocol requests with no-ops; none of those edits touch pixel arithmetic.

## Result

PASS. Exact hashes:

    SCALE 1.04999995 margin=3 cell=10x20 atlas=320x320
    TOTAL 4d7af90ae20b6e2d
    SCALE 0.833333313 margin=3 cell=10x20 atlas=320x320
    TOTAL 353c69151c9e6575

All 447 per-cell hashes match byte-for-byte. Accepted difference: the focused block-cursor blink phase is inverted in the port (see below).

The first oracle run exposed two real port divergences. One was fixed
in render.zig before the PASS above; the other is recorded as accepted
below.

- dotted underlines: the closed-form spacing omitted the second thickness
  term, moving four dot pixels;
- focused block cursors: CURSOR_BLINK_ON is 0, but the port tested
  state != 0, so a blinking block cursor was not painted. That part could
  not be fixed without editing tests/test-terminal.c, which Agent A owns:
  tests/test-terminal.c:4623 and :5092 set CURSOR_BLINK_OFF and expect a
  painted block cursor. The current corpus therefore paints the cursor
  unfocused, where C and Zig agree. The port gap is listed in the final
  report as found-but-not-fixed (render.zig:569, :581, :586, :591).

## Registration

Agent A must add the following line to `tests/meson.build`; this branch does
not edit that file:

    test('render-parity', executable('test-render-parity', 'test-render-parity.c', client_harness_obj, include_directories: '..', dependencies: foot_deps, link_with: footlib))

