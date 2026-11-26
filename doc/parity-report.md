# Render parity report

Date: 2026-11-26. Branch: fix/corpus (parity corpus widening).
C oracle: commit `6b3f557d`, pinned via `ORACLE_REF` and detached by the
script into a worktree under a fresh `WORK` directory (`$TMPDIR` is honoured);
an `EXIT` trap removes the worktree and the scratch directory. `grim` is not
installed, and there is no wayland connection in this container, so the
oracle compares pixman images directly instead of screenshots
(MIGRATION_PLAN §14.5.2 item 2).

## Corpus

`tests/test-render-parity.c` paints a fixed 640×640 `PIXMAN_a8r8g8b8`
atlas with a real `monospace` fcft face at size 8, fixed 10×20 cells, and a
zeroed `wl_window`/`wayland` pair (no compositor connection):

- a 16×8 cell grid: bold, italic, reverse, selected, concealed, custom RGB
  fg/bg, strikethrough, URL underline, all five underline styles through
  row_ranges, box drawing, block elements/braille, and block cursors covering
  focused blink ON, focused blink OFF, and unfocused;
- a 12-cell cursor matrix covering `CURSOR_UNDERLINE`, `CURSOR_BEAM` (foot's
  legacy `cursor.style=bar` is an alias of `beam`) and `CURSOR_HOLLOW`, each
  with focused/unfocused × blink ON/OFF. Custom `colors.cursor_fg/bg` and
  point-valued `cursor.beam_thickness`/`cursor.underline_thickness` make the
  cursor colour and geometry arithmetic part of the comparison;
- wide and combining cells: two double-width CJK glyphs with their spacer
  cells, plus three composed clusters (base + U+0301; wide base + U+0301;
  forced-width-2 cluster with two combining marks). HarfBuzz/fcft grapheme
  shaping is enabled (`can_shape_grapheme` and `tweak.grapheme_shaping`), so
  the shaped glyph path is compared, not only the per-codepoint fallback;
- a URL-mode OSD label and a render-timer OSD with the product's margin;
- CSD top, left, **right**, **bottom** borders and a CSD title surface;
- two synthetic sixel images (translucent and opaque) pushed into a fake
  `grid.sixel_images` tll with prebuilt pixman images and rendered through the
  real `render_sixel_images()`. No shm pool, VT parser, or compositor is
  needed; the sixel escape decoding and cell-size rescaling paths are *not*
  part of this corpus;
- scales `126/120` (1.05), `100/120` (0.8333) and `2.0`.

The atlas grew from 320×320 to 640×640 because the new surfaces (in
particular the cursor matrix, wide/combining row and sixel band) must remain
disjoint at every scale. The existing painted regions were kept intact and
only moved; no case was removed. CSD border surfaces are sized to at least
two visible border widths so the painter's own bounds assertions hold at
scale 2.

For every painted cell the tool prints `CELL <region> <row> <col> <hash>`,
where the hash is FNV-1a (offset basis 14695981039346656037, prime
1099511628211) over the cell's RGBA bytes in row-major order. A `TOTAL`
line hashes the whole atlas. There are 1058 cell hashes across the three
scales, compared byte-for-byte.

The OSD margin still comes from `render_parity_osd_margin()`, exported by
`render.zig` for this purpose. The C oracle build defines
`FOOT_RENDER_PARITY_C_ORACLE` and supplies the same C expression with a weak
definition; the harness does not re-derive the margin.

## Commands

Measured on `ab5f4261` by:

    cd /tmp/wt-docs2
    ORACLE_REF=6b3f557d bash scripts/render-parity.sh

(Any checkout at `ab5f4261` works; `WORK` selects the scratch directory.)

`WORK` defaults to a fresh `mktemp -d "${TMPDIR:-/tmp}/foot-render-parity.XXXXXX"`;
set it explicitly to control the scratch location. `ZIG_GLOBAL_CACHE_DIR`
defaults to a cache inside `WORK`. The script fails if `ORACLE_REF` is missing
from the repository, creates `$WORK/oracle` as a detached worktree at that
commit, sets up `$WORK/oracle/build-parity` with its own logs, fails
immediately if either build fails, builds both corpus executables with `-j4`,
diffs the hash dumps, prints the first differing cell, and exits non-zero on
any difference. The EXIT trap removes the worktree (`git worktree remove
--force`, then `git worktree prune`) and the scratch directory. The C
oracle's private copies of `render.c` and `wayland.c` differ from the pinned
commit only in linkage (`static` removed from five painters, including
`render_sixel_images`) and in replacing generated Wayland protocol requests
with no-ops; none of those edits touch pixel arithmetic.

## Result

PASS. Exact hashes:

    SCALE 1.04999995 margin=3 cell=10x20 atlas=640x640
    TOTAL e5184e0fe5898153
    SCALE 0.833333313 margin=3 cell=10x20 atlas=640x640
    TOTAL b7cebabc45627f13
    SCALE 2 margin=6 cell=10x20 atlas=640x640
    TOTAL 87c0bab0d0d6829b

All 1058 per-cell hashes match byte-for-byte. No accepted pixel differences.
Measured per-scale cell counts (`./build/tests/test-render-parity`): 362 at
1.04999995, 348 at 0.833333313 and 348 at scale 2.

The oracle exposed two real port divergences in the earlier, narrower corpus,
both fixed:
- dotted underlines: the closed-form spacing omitted the second thickness
  term, moving four dot pixels;
- focused block cursors: CURSOR_BLINK_ON is 0, but the port tested
  state != 0.

No new divergence was found by the widened corpus: beam/underline/hollow
geometry and colours, point-to-pixel thickness scaling at scale 2, wide/spacer
glyphs, shaped composed clusters, CSD right/bottom borders and both sixel
compositing modes match the pinned C renderer exactly.

To prove the comparison is not vacuous, one source byte of the Zig colour
conversion was perturbed temporarily (`color_hex_to_pixman()` alpha
`0xffff` → `0xf000`); `scripts/render-parity.sh` then failed at the very
first cell (`C: CELL grid 0 0 1a18ce8907ec97bb` vs
`Zig: CELL grid 0 0 af98541f75ece847`, exit 1). The byte was restored and
the script passed again.
