# Render parity report

Date: 2026-11-25. Branch: render-parity (parity follow-ups).
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
  row_ranges, box drawing, block elements/braille, and block-cursor cases
  covering focused blink ON, focused blink OFF, and unfocused;
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
    TOTAL 988ac8ef344eb1a5
    SCALE 0.833333313 margin=3 cell=10x20 atlas=320x320
    TOTAL 69a7dfb30f5f754d

All 447 per-cell hashes match byte-for-byte. No accepted pixel differences.

The oracle exposed two real port divergences, both fixed:
- dotted underlines: the closed-form spacing omitted the second thickness
  term, moving four dot pixels;
- focused block cursors: CURSOR_BLINK_ON is 0, but the port tested
  state != 0. The corpus now covers focused blink ON, focused blink OFF,
  and unfocused cursors.

