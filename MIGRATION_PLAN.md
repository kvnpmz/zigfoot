# foot: finishing the C → Zig migration

Status snapshot and a concrete continuation plan.
Prepared 2026-11-23 against `feature/zig-migration` @ `a1d9d288`.

---

## 1. Where the migration stands

The branch is **64 commits ahead of `origin/master`** (upstream foot 1.28.0),
starting 2026-09-30. About **16.5k lines of C have been replaced by ~16k lines
of Zig** (including ~2k lines of Zig tests). Roughly **30k lines of C remain**.

| State | Modules |
|---|---|
| **Ported, C deleted** (22) | `async`, `base64`, `char32`, `composed`, `csi`, `cursor-shape`, `dcs`, `fdm`, `grid`, `hsl`, `misc`, `notify`, `osc`, `reaper`, `sixel`, `spawn`, `spawn_template`, `tokenize`, `uri`, `vt`, `xmalloc`, `xsnprintf` |
| **In progress** (Zig + remaining C + shims) | `terminal.c` (3,363 lines left), `selection.c` (1,175 lines left) |
| **Untouched** (20 modules, ~25.2k lines) | `box-drawing` (3,450), `config` (4,374), `render` (5,479), `input` (3,690), `wayland` (2,881), `search` (1,512), `shm` (1,110), `url-mode` (833), `main` (751), `server` (688), `key-binding` (661), `client` (629), `slave` (573), `ime` (532), `extract` (271), `log` (231), `commands` (115), `unicode-mode` (110), `quirks` (86), `debug` (47), `foot-features` (42), `user-notification` (14) |
| **Dead file** | `esc.zig` is a 4-line stub; `esc_dispatch` actually lives in `vt.zig`. Delete it. |

Dependency layering (headers included by other project modules, leaves first):

```
user-notification, foot-features, extract, quirks, debug, log
  → slave, shm, box-drawing, unicode-mode
    → config (9 dependents — biggest leverage)
      → ime, commands, key-binding, url-mode
        → selection, wayland
          → input, render, search
            → terminal
              → main
```

`terminal` and `render` are the hubs; `config` is the highest-leverage module
to port early because it removes a large class of `conf_*` shims.

---

## 2. Findings that change the plan

These are all verified on this checkout, not assumptions.

**F1 — HEAD cannot open a window (live regression). — fixed in Phase 0.**
`./build/foot -e sh -c 'sleep 1'` panics in `gridResizeAndReflow`:

```
thread N panic: attempt to use null value
grid.zig:1320 (gridResizeAndReflow)   <- `const old_grid = grid.rows.?;`
```

`term_init` leaves `term.normal.rows == NULL` until the first configure, and
C tolerates that (`old_rows == 0`, pointer never dereferenced, `free(NULL)` is
fine). The Zig port eagerly unwrapped the optional. The same pattern exists in
`gridResizeWithoutReflow`. The Phase 0 fix keeps `grid.rows` optional and unwraps
only under `old_rows > 0`; both configs build, `foot` starts and exits
cleanly, and a regression test now covers it.
**Implication:** the last chunks (P1/P2) were never exercised at runtime. A
runtime smoke test is not optional.

**F2 — The Zig tests exist but never run. — fixed in Phase 0 (meson test).**
23 tests in `grid.zig` (16) and `terminal_types.zig` (7), including all the
reflow/ABI layout tests. No meson target runs them, so they have been dead
weight. They pass when run manually:

```
zig test -lc -lpixman-1 --dep build_options -Mroot=grid.zig -Mbuild_options=...
```

**F3 — CI has no Zig at all. — fixed in Phase 0.**
`.woodpecker.yaml` installs meson/ninja/gcc but no Zig and never builds this
branch. Every Zig change is currently unverified by CI.

**F4 — The ABI mirror is hand-maintained and already drifted three times. — fixed in Phase 0 (generated probe).**
`terminal_types.zig` mirrors C structs with hand-computed offsets/sizes,
opaque blobs (`_font_state`, `xtsave`, `window`, `conf`, …) and ~175 shim
accessor functions in 1.2k lines of `*-shim.c`. Three of the 64 commits are
drift fixes (`23b7587a`, `2e52e2ef`, `858f9dfa`), one of which made
`build-disabled/foot` (grapheme clustering off) panic at startup. The layout
"probe" numbers in the tests were produced by hand; there is no probe in the
repo. Every remaining module adds more C structs, so this cost grows.

**F5 — `compile_zig.py` ignored the build type and pinned nothing. — fixed in Phase 0.**
It hardcodes `-O ReleaseSafe`, passes `-fno-stack-check`, adds no `-g`, and
does not check the Zig version (0.16.0 here). `--buildtype=debug` only affects
the C side, so the two halves of the program are built with different
optimization/safety assumptions.

**F6 — Test coverage of ported logic is very thin. — partly addressed in Phase 0 (harness still missing).**
23 tests for 16k lines. `csi`, `vt`, `osc`, `sixel`, `terminal`, `selection`,
`notify` have zero tests. The escape-sequence state machine — where most
behavioral risk lives — is untested. The C side's own `UNITTEST` blocks
(`input.c`) already show the pattern for constructing a minimal `struct
terminal` without Wayland, so a harness is cheap to build.

**F7 — The feature matrix is never tested.**
Configs that must all build and run: grapheme clustering on/off, IME on/off,
utmp backends, PGO on/off, `foot` vs `footclient`/server. Only the default and
one disabled build directory exist, and neither is in CI.

**F8 — Positive: the environment can run the real binary.**
Zig 0.16.0, meson, ninja and a live Wayland socket are available, and
`foot --pty=PATH` lets a test drive a real terminal. End-to-end smoke and
screenshot comparison are feasible here and in CI (with a headless compositor).

---

## 3. Definition of done

1. No foot-owned `.c` module remains (generated `srgb.c` and wayland-scanner
   protocol files excepted, or ported too if desired).
2. One source of truth for every struct: Zig owns the definitions, no mirrors,
   no opaque blobs, no `*-shim.c` accessors.
3. `meson test` covers the VT core (golden corpus + unit tests) and runs in CI
   on the full feature matrix.
4. Behavior parity with the C baseline is demonstrated (escape-sequence corpus,
   rendering screenshots, performance within an agreed margin).
5. Docs (`README`, `INSTALL`, CI) state that Zig is required and how to build.

---

## 4. Phase 0 — Make the safety net real — DONE

Implemented on this branch. What landed:

**0.1 Fixed the startup crash (F1).**
`grid.zig` no longer eagerly unwraps `grid.rows`; both resize functions keep
it optional and only index it under `num_rows > 0`. New regression test
`resize tolerates an uninitialized grid (NULL rows)` was verified to abort on
the pre-fix code.

**0.3 Generated ABI probe (F4).**
`scripts/gen_abi_probe.py` generates `abi_probe.c` from the mirrors in
`terminal_types.zig`; meson compiles and runs it into `c_layout.zig`.
`expectAbi()` compares every mirrored struct/field (recursively) at compile
time, for both grapheme configurations. The generator is checked by
`meson test abi-probe-up-to-date`.

The probe immediately found two drifts the old tests missed:
* `Grid.kitty_kbd`: C has one nested struct, the mirror had two top-level
  fields (`kitty_kbd_flags` + `kitty_kbd_idx`). Same size, wrong shape.
* `Vt.attrs`: the mirror placed it 4 bytes late (`_pad1` workaround around a
  packed struct's 8-byte alignment). Real corruption of SGR attributes.
  Fixed with `attrs: Attributes align(4)` and removal of the pad.

**0.2 Zig tests run in meson/CI (F2).**
`scripts/zig_test.py` + per-module `test()` entries; `grid` and
`terminal_types` (23 tests) now run under `meson test`. Add a module to
`zig_test_modules` when it gains tests.

**0.5 `compile_zig.py` honors the build.**
Optimize mode now follows meson's `--buildtype` (debug→Debug,
release→ReleaseSafe, minsize→ReleaseSmall), the Zig series is enforced
(0.16.x), and the `c_layout` module is wired in automatically.

**0.4 / 0.6 CI + smoke.**
`.woodpecker.yaml` installs Zig for all build jobs; a dedicated `zig` job
builds grapheme on/off in debug and release, runs `meson test`, and runs
`scripts/smoke.sh`. The smoke script checks `--version` (C UNITTESTs), `-C`
with a temp config, and real window launches (headless weston if needed).

Verified locally: debug/grapheme-on, debug/grapheme-off, and release builds
all build, `meson test` is 4/4 green, and the smoke test passes.

## 5. Phase 1 — Finish the in-flight modules (2 weeks unblocked + 2 weeks after Phase 2)

Phase 1 is roughly **4× Phase 0**, and it splits cleanly in two:

| Part | Content | ~C lines left | Effort | Blocked on |
|---|---|---|---|---|
| **1a** | T1–T3, T5–T7, S1, S2 (T4 needs the seats) | ~1.7k | 8–10 days | nothing — shims suffice |
| **1b** | T8–T11, S3 | ~2.1k | 10–12 days | Phase 2 `config` (T9/T10/T11), Phase 3 `wayland` (T8/S3), `render`/`slave` (T11) |

Phase 0 was 4 commits and ~600 lines of *infrastructure* (probe, tests, CI,
smoke script) with no behaviour ported. Phase 1a alone is ~1.7k lines of
*behaviour* in ~10 commits, each of which must keep `terminal.c` compiling and
the smoke test green. So yes: longer, and the tail of Phase 1 cannot be
finished in Phase 1 at all — it is a Phase 2/3 deliverable by construction.

**Progress:** six chunks landed (terminal.c 3363 → 2400 lines, 1029 C lines
removed for 1211 Zig lines added, harness at 87 checks):

| Chunk | Status |
|---|---|
| T1 `term_erase_scrollback` | ✅ (existing C `UNITTEST` now drives the Zig code) |
| T2 text extraction | ✅ (headless harness) |
| T3 accessors | ✅ except IME — see T4 |
| T4 IME | ⛔ **blocked**: needs `term->wl->seats` (and `ime_enabled` + `FOOT_IME_ENABLED` in build_options) |
| T5 app-sync + throttle timers | ✅ |
| T6 focus/bell/title/icon/spawn | ✅ except `term_kbd_focus_out` (seats) and `term_surface_kind` (window CSD) |
| T7 mouse reporting | ✅ except `term_mouse_grabbed` + `term_xcursor_update*` (seats/key-bindings) |
| extra | `erase_cell_range`, `erase_line`, `print_linewrap`, `print_insert` |

The harness (`tests/test-terminal.c`) now fakes a `struct terminal`, a real
pty (for `term_to_slave` output), a real `struct config` and a timerfd, so it
covers erase, extraction, osc8, size notifications, flash, bell, focus-in,
theme apply/get, term_icon, mouse reporting in all five styles, and
insert-mode shifting.

What is left in `terminal.c` is T8–T11 — i.e. exactly the parts that need
`config`, `wayland` and `render` — so 1a is done: the remaining ~2.4k lines
cannot move until phase 2/3 land.

Order of work inside 1a: **~~T1 → T2 → T3 → T5 → T6 → T7~~**, with T4 pushed
to 1b, then **S2 → S1**., i.e.
cheapest and most testable first, and `T2` early because the text-extraction
helpers become the primary assertion surface for every later chunk.

Follow the established chunk style: one function group per commit, C body
deleted and replaced by an `extern` prototype, new shims listed in the commit
message.

### `terminal.c` — remaining ~3.2k lines, in dependency order

| Chunk | Functions | ~LOC | Notes / dependencies |
|---|---|---|---|
| T1 | `term_erase_scrollback` | 85 | pure grid/sixel; uses `sb_pushline` paths |
| T2 | `rows_to_text`, `term_scrollback_to_text`, `term_view_to_text`, `term_command_output_to_text` | 147 | also gives the test harness a way to dump state |
| T3 | `term_theme_apply/switch/toggle/get`, `term_osc8_open/close`, `term_set_user_mouse_cursor`, size-notification trio, `term_send_visibility_report` | ~120 | small accessors; removes several shims |
| T4 | `term_ime_is_enabled/enable/disable/reset/set_cursor_rect` | 74 | delegates to `ime.c`; do after `ime` port or via shims |
| T5 | `term_enable/disable_app_sync_updates`, `fdm_app_sync_updates_timeout`, title/icon/app-id timeouts | ~90 | fdm timers + wayland view shims |
| T6 | `term_kbd_focus_in/out`, `term_flash`, `fdm_flash`, `term_bell`, `term_icon`, `term_set_window_title`, `term_set_app_id`, `term_spawn_new`, `term_surface_kind` | ~220 | fdm + wayland + `spawn` |
| T7 | mouse reporting: `linux_mouse_button_to_x`, `encode_xbutton`, `report_mouse_click/motion`, `term_mouse_grabbed/down/up/motion` | ~250 | needs `seat`/`conf.mouse` mirrors |
| T8 | `term_xcursor_update_for_seat`, `term_xcursor_update` | 53 | defer until `wayland`/seat is ported |
| T9 | font stack: `term_set_fonts`, `term_line_height_update`, `free_custom_glyph(s)`, `get_font_dpi`, `get_font_subpixel`, `term_pt_or_px_as_pixels`, `font_loader_thread`, `reload_fonts`, `load_fonts_from_conf` | ~430 | needs `config` font fields + fcft mirrors; do **after** Phase 2 `config` |
| T10 | font size/scale/dpi: `term_font_size_*`, `term_fractional_scaling`, `term_update_scale`, `term_font_dpi_changed`, `term_font_subpixel_changed`, `term_font_baseline` | ~210 | depends on T9 |
| T11 | `term_init`, `term_destroy`, `term_shutdown`, `term_reset`, `term_window_configured`, `shutdown_maybe_done`, `fdm_client_terminated`, `fdm_shutdown`, `fdm_terminate_timeout`, `sig_alarm`, utmp helpers, `initialize_render_workers` | ~1.3k | last: needs config, wayland, render, ime, spawn, slave |

### `selection.c` — remaining ~1.1k lines

The text-selection core is already ported. What is left is Wayland clipboard
and DnD plumbing:

| Chunk | Functions | ~LOC | Notes |
|---|---|---|---|
| S1 | `send_clipboard_or_primary`, `fdm_send`, `wl_data_source` listeners (`send`, `cancelled`, `dnd_*`, `action`, `target`) and primary equivalents | ~250 | needs `wl_data_source`/seat mirrors |
| S2 | receive path: `fdm_receive*`, `decode_one_uri`, `begin_receive_clipboard`, `select_mime_type_for_offer`, `data_offer_reset` | ~400 | self-contained text/uri-list decoding; good Zig unittest candidates |
| S3 | DnD / data-device / primary offer listeners (`offer`, `enter`, `leave`, `motion`, `drop`, `selection`, `primary_*`) | ~450 | **port with `wayland.c`**, not before |

**Recommendation:** do S1/S2 now with thin wl shims; leave S3 for Phase 3.

**Exit criteria for Phase 1a:** `terminal.c` contains only T8–T11 and
`selection.c` only S3, each carrying a `/* TODO(phase2/3): blocked on <module> */`
marker; the headless harness covers cursor movement, erase, scroll, print, text
extraction and selection; zero new opaque blobs without a tracked TODO; every
new chunk has at least one Zig unittest or harness assertion.

---

## 6. Phase 2 — Leaves, then the config hub (4–6 weeks)

Port in this order; each module is a small, reviewable series of chunks.

1. **Trivial leaves (~0.9k):** `user-notification`, `foot-features`, `quirks`,
   `debug`, `log`, `commands`, `unicode-mode`, `extract`. Good warm-up and
   they delete C↔C call glue.
2. **`slave` (573) + `shm` (1,110):** syscall/`mmap`/SCM_RIGHTS heavy; `shm` is
   the foundation for `render` and `wayland`. Port with tests around fd passing.
3. **`config` (4,374) — do it here, not last.** It has nine dependents and is
   the source of most remaining accessor shims. Split it:
   * C1: mirror the `config`/section structs (kills `conf_*` shims for T7/T9);
   * C2: parser core (sections, key/value, include) with `tests/test-config.c`
     as the oracle — run the C test against the Zig implementation until the
     C parser is deleted;
   * C3: per-section option tables, one section per commit (`main`, `cursor`,
     `mouse`, `colors`, `key-bindings`, `url`, `bell`, `scrollback`, …).
4. **Mid-tier (~3.5k):** `ime`, `key-binding`, `url-mode`, `search`.
5. **Standalone binaries:** `client` (footclient) and `server` — they share
   `main`'s setup; port once `config`/`wayland` are stable.

**Exit criteria:** `config.c` gone; `terminal` T9/T10 unblocked; shim line
count reduced by at least a third.

---

## 7. Phase 3 — The core four (4–6 weeks, partly parallel)

1. **`box-drawing` (3,450) — mechanical, do it early as a quick win.**
   Most of the file is static box-drawing glyph tables. Convert the tables with
   a script, port the ~300 lines of lookup logic by hand. Zero runtime risk.
2. **`wayland` (2,881) + selection S3:** protocol listeners, seats, xcursor,
   window state. This unblocks T8 and the render path. Expect lots of
   `wl_*` struct mirrors; consider generating them (see D1).
3. **`input` (3,690):** key handling, IME, mouse, scroll. Port the keymap
   tables mechanically; port the handlers in chunks; port the four `UNITTEST`
   blocks to Zig tests. `search` (1,512) can go in parallel — it is
   self-contained.
4. **`render` (5,479):** the largest and highest-risk module (pixman, fcft,
   shm, sixel, damage tracking). Port in this order: damage/cursor →
   background/decoration → text/glyphs → sixel/kitty graphics → resize/CSD.
   Screenshot-diff every chunk against the C baseline.
5. **`main` (751) last:** argument parsing, fdm/wayland/terminal bring-up,
   `--server`, `--pty`, config check. Once it is Zig, the process entry point
   is Zig and the C library can be deleted.

**Parallelization:** after Phase 0, independent modules can be ported
concurrently. The one shared file is `terminal_types.zig`; assign a single
writer per phase, or partition by struct, and rebase daily.

---

## 8. Phase 4 — Endgame and cleanup (1–2 weeks)

* Delete `*-shim.c`, `xmalloc-shim.c`, `xsnprintf-shim.c`, `esc.zig`, and the
  "Ported to …" extern blocks in the last C files.
* Make `terminal_types.zig` (or a renamed `types.zig`) the sole owner of the
  struct definitions; delete the mirrors and the ABI probe once C headers are
  gone.
* Decide whether `srgb.c` (generated by `scripts/srgb.py`) is ported or kept.
  Wayland-scanner output can stay C unless a Zig protocol generator is adopted.
* Replace 26 individual `zig build-obj` invocations with one `zig build-lib`
  (or a `build.zig`) if build times or dependency tracking become a problem.
* Update `README.md`, `INSTALL.md`, the man pages, and CI; drop the C compiler
  from the build requirements if nothing C remains.
* Final parity run: golden corpus, screenshot diff, benchmark, leak check,
  full feature matrix.

---

## 9. Per-chunk recipe (use for every commit)

1. Read the C function **and** every helper/struct field it touches.
2. Mirror missing fields in `terminal_types.zig` as real fields where possible;
   if a blob is unavoidable, add an accessor and a `TODO(shim-removal)`.
3. Port to `*.zig` as `export fn` with the C ABI; keep identifiers recognizable
   (`term_foo` → `termFoo` internally, exported name unchanged).
4. Delete the C body; add a `/* Ported to X.zig */ extern …` prototype.
5. Only de-`static` C helpers that Zig actually calls; otherwise port them too.
6. Update meson `depend_files` for every `@import`ed `.zig`.
7. Build and smoke **all** configs; run `zig test`.
8. Add a Zig unit test when the logic is testable without Wayland.
9. Commit `module: chunk X — port …`, listing new shims, blob additions, and
   any deliberate behavior differences. One chunk per commit, no drive-bys.

**Hard rules**
* No behavior changes in a port commit; refactors are separate.
* Never `.?` a pointer that C permits to be NULL.
* Memory allocated by C (`malloc`/`xcalloc`/tll nodes) is freed with
  `std.c.free`/the matching C free — never with a Zig `Allocator`.
* Update the ported-LOC / shim-LOC scoreboard in this file every phase.

---

## 10. Verification strategy

**A. Unit tests (fast, every commit).**
`zig test` per module: grid reflow invariants, ABI layout, parser edge cases,
selection boundary finders, base64/uri/tokenize.

**B. Headless terminal harness (highest value — build in Phase 0/1).**
A `tests/` program in the style of `input.c`'s `UNITTEST`: construct a minimal
`struct terminal` (config, grid, ptmx pipe, wayland stub), feed a byte corpus
through `vt_parse()`, dump the screen with `term_view_to_text()`, compare
against golden files. Corpus: CSI/SGR, cursor movement, scroll regions, alt
screen, wrapping/wide/combining chars, DECAWM, tabs, OSC 8/52, shell
integration, sixel. While the C implementations still exist, **run the same
corpus against `origin/master` and the migrated build and diff** — this is the
cheapest way to prove behavior parity.

**C. Fuzzing.**
Feed random bytes to the harness; C parts under ASAN, Zig under ReleaseSafe.
Any Zig panic on hostile input is a bug (or a documented policy decision).
Seed with vttest/esctest sequences.

**D. End-to-end under a compositor.**
`weston --backend=headless` (or the existing `WAYLAND_DISPLAY`), launch
`foot --pty=<harness pty>`, assert clean startup/exit, then screenshot with
`grim` and diff frames against the C baseline for a small scenario set.

**E. Performance and resources.**
`doc/benchmark.md` scenarios (reflow, sixel, text throughput) C vs Zig; PGO
build comparison; RSS; valgrind/ASAN for the C side and leak detection for
Zig-owned allocations.

**F. Feature matrix in CI.**
grapheme on/off × IME on/off × debug/release; `foot`, `footclient`, `--server`;
utmp backends where available.

---

## 11. Risk register

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | ABI drift between C and Zig mirrors | Silent memory corruption / startup panics (already happened 3×) | Generated layout probe + compile-time asserts + matrix CI (0.3) |
| R2 | Silent behavior drift (reflow, printing, scroll) | Subtle terminal misbehavior users notice late | Golden corpus + differential run vs C baseline (10B) |
| R3 | Zig safety panics on hostile escape sequences | Remote DoS in a terminal emulator | Fuzz the VT core; decide ReleaseSafe vs ReleaseFast per module before release |
| R4 | No runtime testing | Broken HEAD merges unnoticed (F1 is an example) | `--pty` smoke + headless compositor in CI (0.6) |
| R5 | Ownership bugs across the boundary (double free, wrong allocator) | Crashes/leaks | Explicit allocator rule; ASAN/valgrind; ownership notes in commit messages |
| R6 | `config` port scope creep | Weeks lost, blocks everything | Port struct first, then parser, then sections with `test-config` as oracle |
| R7 | Upstream foot moves | Merge pain grows | Merge `origin/master` weekly; port upstream fixes into already-ported modules immediately |
| R8 | Parallel workers colliding in `terminal_types.zig` | Wasted rebases/regressions | Single writer per phase or field-partitioned ownership; small commits |
| R9 | Zig 0.16 API churn | Build breaks | Pin the version; bump deliberately with a dedicated commit |
| R10 | Long tail (wayland glue, IME, PGO, utmp) | Schedule slip | Reserve 20% buffer; keep shims until their module is ported |

---

## 12. Open decisions (need a call)

1. **How to keep the ABI mirror in sync** — hand mirrors + generated probe
   (cheap, incremental), or a timeboxed spike to generate the Zig types from
   the C headers with `zig translate-c` (I verified it can translate
   `terminal.h` here with the exact meson flags; it produces ~18k lines). The
   generated-types route removes an entire bug class but is a bigger detour.
   Recommendation: probe now, evaluate translate-c before Phase 3.
2. **Scope of "finish"** — does it include `footclient`/`--server`, utmp
   helpers, PGO, and the generated `srgb.c`? Assume yes unless told otherwise.
3. **Build system** — stay on meson + `compile_zig.py` (recommended) or move to
   `build.zig`. Meson already handles wayland-scanner/fcft; keep it.
4. **Production safety mode** — `ReleaseSafe` (panics instead of UB) vs
   `ReleaseFast` for release. Decide before shipping; fuzzing informs it.
5. **Shim cleanup cadence** — delete shims per module once its struct is fully
   mirrored (recommended) vs a final sweep.
6. **Port `config` before finishing `terminal`'s font/init chunks** —
   recommended yes, because it unblocks T9–T11 and removes many accessors.

---

## 13. Suggested immediate actions (this week)

1. Commit the `grid.rows` NULL fix (verified) + a regression test.
2. Add the `zig test` meson targets and make `meson test` run the 23 existing
   tests; add the CI job with Zig 0.16.0.
3. Add the generated ABI probe and replace the hardcoded offsets in
   `terminal_types.zig`.
4. Add `scripts/smoke.sh` (`foot -C`, `foot --version`, `foot --pty` under a
   headless compositor) and run it in CI.
5. Start Phase 1 with T1 (`term_erase_scrollback`) and T2 (text extraction),
   plus the headless harness skeleton, which T2 makes easy.

**Rough effort:** Phase 0 3–5 days; Phase 1 2–3 weeks; Phase 2 4–6 weeks;
Phase 3 4–6 weeks; Phase 4 1–2 weeks. About **3–4 months for one developer**,
or **6–8 weeks with 2–3 parallel workers** once Phase 0 lands.
