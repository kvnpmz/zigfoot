# foot: finishing the C → Zig migration

Status snapshot and a concrete continuation plan.
Prepared 2026-11-23 against `feature/zig-migration` @ `a1d9d288`.
**Refreshed again 2026-11-25 @ `f67b6f48` (D3i) — current numbers, the revised
chunk order and the new verification gap are in §14. §1's scoreboard below is
the 11-24 snapshot; use §14 for anything measured.**
Refreshed 2026-11-24 against @ `3e023fd6` (Phase 0, Phase 1a, upstream merge,
config C1-C2o, the terminal font/DPI/size stack T9/T10, `shm` S1-S5, `slave`,
`log`, `debug`, `user-notification` and `unicode-mode` — the config parser,
the SHM allocator/cache/scroller, the spawn/exec path and the whole logging
stack are Zig).

---

## 1. Where the migration stands

The branch is **98 commits ahead of `origin/master`** (upstream foot 1.28.0),
starting 2026-09-30. Measured on this checkout, **21,826 of 48,830 top-level
foot-owned C lines are gone (44.7%)**, replaced by ~22.7k lines of Zig
(including ~2k lines of Zig tests). About **27.0k lines of C remain**, plus
1,142 lines of `*-shim.c` accessors and the generated `abi_probe.c` (2,215).

| State | Modules |
|---|---|
| **Ported, C deleted** (28) | `async`, `base64`, `char32`, `commands`, `composed`, `csi`, `cursor-shape`, `dcs`, `extract`, `fdm`, `grid`, `hsl`, `misc`, `notify`, `osc`, `reaper`, `sixel`, `spawn`, `spawn_template`, `tokenize`, `uri`, `log`, `user-notification`, `unicode-mode`, `vt`, `xmalloc`, `xsnprintf`, and **`config`** (the parser, the logger tail and the fcft accessors are Zig; the 35 surviving C lines are `config_regex_compile()` only — see §6.3) |
| **In progress** (Zig + remaining C + shims) | `terminal.c` (1,780 left), `selection.c` (844 left), `shm.c` (329 left — globals, 32-bit/punch-hole `#ifdef` shims, the `wl_buffer_listener` and the `wl_shm` protocol stubs; `shm.zig` is 1,014 lines), `debug.c` (22 left — the ASAN stack-trace hook), `config.c` (35 left — the regex_t shim), `slave.c` (158 left — O_*/F_*/TIOCSCTTY/_CS_PATH constants, the IUTF8 termios block, signal-mask restoration and the execvpe shim; `slave.zig` is 663 lines) |
| **Untouched** (13 modules, ~21.2k lines) | `box-drawing` (3,450), `render` (5,479), `input` (3,690), `wayland` (2,881), `search` (1,512), `url-mode` (833), `main` (751), `server` (688), `key-binding` (661), `client` (629), `ime` (532), `quirks` (86), `foot-features` (42) |

**Progress read two ways:** 45% by C volume, but roughly **35% by effort**,
because what remains is the hard core (`render`, `input`, `wayland`, the
`terminal` init/font tail) rather than the leaves. By module count it is
25 of 46 ported, 2 in progress, 19 untouched. The highest-leverage module
(`config`, nine dependents) is done, so the `conf_*` accessor shims and the
"blocked on config" markers are gone too.

Dependency layering (headers included by other project modules, leaves first):

```
user-notification, foot-features, quirks, debug, log
  → slave, shm, box-drawing, unicode-mode
    → config (9 dependents — biggest leverage)
      → ime, key-binding, url-mode
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
accessor functions in 1.2k lines of `*-shim.c`. Three of the early commits are
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
| **1a** | T1–T3, T5–T7, S2 (T4 and S1 turned out to need the seats too) | ~1.7k | 8–10 days | nothing — shims suffice |
| **1b** | T8–T11, S3 | ~2.1k | 10–12 days | Phase 2 `config` (T9/T10/T11), Phase 3 `wayland` (T8/S3), `render`/`slave` (T11) |

Phase 0 was 4 commits and ~600 lines of *infrastructure* (probe, tests, CI,
smoke script) with no behaviour ported. Phase 1a alone is ~1.7k lines of
*behaviour* in ~10 commits, each of which must keep `terminal.c` compiling and
the smoke test green. So yes: longer, and the tail of Phase 1 cannot be
finished in Phase 1 at all — it is a Phase 2/3 deliverable by construction.

**Progress:** seven chunks landed (terminal.c 3363 → 2400 lines, selection.c
1175 → 844; harness at 102 checks):

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
| S2 clipboard receive | ✅ normalisation, C0 filter, URI decoding, 2s watchdog |
| S1 clipboard send | ⛔ **blocked**: `send_clipboard_or_primary()` and the `wl_data_source` listeners need the seat mirror |

The harness (`tests/test-terminal.c`) now fakes a `struct terminal`, a real
pty (for `term_to_slave` output), a real `struct config` and a timerfd, so it
covers erase, extraction, osc8, size notifications, flash, bell, focus-in,
theme apply/get, term_icon, mouse reporting in all five styles, and
insert-mode shifting.

What is left in `terminal.c` is T8–T11 — i.e. exactly the parts that need
`config`, `wayland` and `render` — and in `selection.c` only S1/S3, which need
the seat. So **1a is done**: the remaining ~2.5k C lines cannot move until
phase 2/3 land.

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

**T9/T10 prerequisites, measured (2026-11-24, now that `config` is done):**

* The font state is still an opaque blob: `Terminal._font_state: [112]u8`
  spans `terminal.h`'s `delayed_render_timer` … `font_subpixel`
  (C offsets: timer 2300, `fonts` 2312, `font_sizes` 2344,
  `font_line_height` 2376, `font_dpi` 2384, `font_is_sized_by_dpi` 2392,
  `font_x_ofs` 2394, `font_subpixel` 2400; `custom_glyphs` follows at 2408).
  Un-blobbing it is T9's first step: replace it with real fields, then let
  the probe confirm every offset above.
* `get_font_dpi()`/`get_font_subpixel()` need `term->window->on_outputs`
  (a tll of `struct monitor`) and `term->wl->monitors`, i.e. the `wayland`
  mirrors — they are **not** unblockable from `config` alone, contrary to the
  earlier note. `term_set_fonts()`/`term_line_height_update()` only need
  `fcft_font`'s `height`/`ascent`/`descent`/`max_advance`; following the
  `regex_t`/fcft precedent, expose those through `terminal-shim.c`
  accessors rather than mirroring `struct fcft_font`.
* `term_pt_or_px_as_pixels()` is pure (scale, dpi, pt/px) and can go in the
  first T9 commit with a Zig test.

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

   **Progress:** `extract` ✅ (271 lines gone; `term_*_to_text()` is now Zig
   end to end) and `commands` ✅ (115 lines). The rest of this group turned out
   not to be worth it yet: `quirks` needs `wl_subsurface` + `term->window`,
   `unicode-mode`'s main entry point takes `struct seat *`, `debug`/`log` are
   varargs-to-C loggers, `foot-features` is a preprocessor string whose macros
   (`FOOT_IME_ENABLED`, `HAVE_XDG_TOPLEVEL_TAG`, …) are not in Zig's
   build_options yet, and `user-notification` is one `va_list` wrapper around
   `xvasprintf()`. Revisit them after `config`, when build_options grows the
   feature flags.
2. **`slave` (573) + `shm` (1,110):** syscall/`mmap`/SCM_RIGHTS heavy; `shm` is
   the foundation for `render` and `wayland`. Port with tests around fd passing.
3. **`config` (4,374) — do it here, not last.** It has nine dependents and is
   the source of most remaining accessor shims. Split it:
   * C1 ✅: **done.** `struct config` plus its member types (`config_font`
     (+list), `argv`, `binding_aux`, `config_key_binding` (+list), the spawn
     templates, `custom_regex` (+list), `env_var`/`user_notification` tllists)
     are mirrored in `terminal_types.zig` and pinned by the ABI probe
     (`Config__size` = 3232, glibc/x86-64). `regex_t` is opaque — its size
     comes from the generated C layout (`Config_url_preg__size`), so glibc and
     musl both work. Anonymous C unions (`binding_aux`'s payload) are named
     `_u` so the probe skips them; the enclosing struct size/offsets still pin
     the layout. Porting this also exposed a live bug: `csi.zig` stored
     `enum underline_style` with a private encoding (`SINGLE = 0`,
     `NONE = -1`) while `render.c` reads C's (`NONE = 0`, `SINGLE = 1`, …), so
     every non-plain underline rendered wrong. The enum is now shared and
     `tests/test-terminal.c` pins the numbers;
   * C2: parser core (sections, key/value, include) with `tests/test-config.c`
     as the oracle — run the C test against the Zig implementation until the
     C parser is deleted. **C2a done** (value-parsing helpers: bool/int/
     dimensions/float/string/wchars/enum/colour/two-colour/pt-or-px and the
     argv + spawn-template clone/free pair, ~360 C lines). The test now
     compiles `config.c` into itself *and* links `config.o`, so the C oracle
     exercises the Zig helpers — that is the pattern the rest of C2 uses.
     `struct context` moved to `config.h` so the probe can pin its layout
     (`ConfigContext`), and `log_contextual()` lost its `static`;
     **C2b done** — eight section parsers (`[security]`, `[bell]`,
     `[desktop-notifications]`, `[scrollback]`, `[cursor]`, `[mouse]`,
     `[touch]`, `[environment]`, ~230 C lines). Two things fell out of it:
     `value_to_enum()` takes compile-time-built NULL-terminated maps, and
     `csd.color`'s unnamed bit-field block is now a `packed struct(u32)` so
     Zig can set `title_set`/`buttons_set`/… by name instead of poking a
     `u32` (the probe skips it because C has no such member; the u32 offsets
     below it still pin the layout);
     **C2c done** — `[colors-dark]`/`[colors-light]` (`parse_color_theme()`,
     the palette/`regularN`/`brightN`/`dimN`/`sixelN` index arithmetic and
     every named colour) and `[csd]`, another ~340 C lines. `config.c` was then
     3.5k (from 4.4k) and the whole ini except `[main]`, `[tweak]`, the
     key-binding sections and the regex ones (`[url]`/`[regex]` need
     `regex_t.re_nsub`, which is libc-private) is Zig;
     **C2d done** — `[tweak]`, which needed the first real `build_options`
     feature flag (`pixman_rgba_16`, since `surface-bit-depth=16-bit` only
     exists in builds with `HAVE_PIXMAN_RGBA_16`). `compile_zig.py` now
     accepts `name=value` arguments and writes them into the per-module
     `build_options`, so that plumbing is reusable for `FOOT_IME_ENABLED`,
     `HAVE_XDG_TOPLEVEL_TAG`, … when `foot-features` is ported. Watch out for
     `scaling-filter`: its values must be given in `enum fcft_scaling_filter`
     order, not the order config.c writes them in;
     **C2e done** — `[main]`, the last big section (~470 C lines), including
     `include=` (which forced `parse_config_file()` and
     `log_contextual_errno()` non-static, and a Zig `strJoin3()` because
     `xstrjoin3()` is `static inline`) and the `pad=` parser with its
     `center|center-when-fullscreen|center-when-maximized-and-fullscreen`
     modes. config.c was then down to 3.1k;
     **C2f done** — the file/section/key-value loop itself
     (`parse_key_value()`, `str_to_section()`, `section_info[]` and
     `parse_config_file()`, ~320 C lines). The Zig table reaches the sections
     that are still C (`[url]`, `[regex]`, the four `*-bindings`,
     `[text-bindings]`) through `extern` declarations, so those parsers lost
     their `static`;
     **C2g done** — the override loop (`config_override_apply()`) is Zig. It
     reuses `parseKeyValue()`/`strToSection()` from C2f and keeps C's error
     messages and the NULL `context.section` until after the empty-name check.
     Collision resolution needs the static binding action tables, so it stays
     in C as `config_bindings_finalize()`. config.c is now **2,720 lines**
     (from 4,374);
   * **C2h–C2o done — the config parser is finished; `config.c` is 335
     lines** (from 4,374), none of which is parsing logic:
     * **C2h** `[url]`/`[regex]`. `regex_t` stays opaque: its size comes from
       the generated C layout, and a 20-line `config_regex_compile()` in C
       does `regcomp()` + the `re_nsub >= 1` check + `regerror()` (returns
       0/-1/-2). Only at Phase 4, if ever, is this removable.
     * **C2i** the binding helpers: `parse_modifiers()`, the four colours of
       free (`free_binding_aux`/`free_key_binding`/`free_key_binding_list`),
       `binding_aux_equal`, `mouse_button_name_to_code` and friends,
       `modifiers_equal/disjoint/to_str`. `button_map` moved to Zig, so the
       oracle reads it through `config_button_map_len/code/name()`.
     * **C2j** `pipe_argv_from_value()`, `regex_name_from_value()` and
       `value_to_key_combos()`. One deliberate deviation: C sized its VLA by
       counting spaces and `memcpy`'d that many entries, so a double space
       inserted *uninitialised* bindings; Zig counts real tokens. Identical
       for well-formed input, no garbage.
     * **C2k** the action tables (as `enum(c_int)` + `?[*:0]const u8` arrays
       generated mechanically from `key-binding.h`, to avoid transcription
       drift), the five `-bindings` section parsers, collision resolution and
       `config_bindings_finalize()`. The C UNITTEST for
       `parse_key_binding_section` used a synthetic map and could not
       survive; its scenario is now `test_key_binding_sequences()` in the
       oracle. Tests reach the tables via `config_action_map_count/name()`.
     * **C2l** the four `default_*_bindings` tables (73 entries; keysym values
       obtained by compiling against xkbcommon, since `XKB_KEY_*` are macros,
       not symbols) and `get_server_socket_path()`.
     * **C2m** `config_load()` and the default tables. Zig has no designated
       initialisers, so the C zero-fill is `std.mem.zeroes()` + one assignment
       per named field. Three new `build_options` mirror C `#define`s
       (`default_terminfo`, `utmp_helper_path`, `debug_build`), which is also
       where `FOOT_IME_ENABLED`/`HAVE_XDG_TOPLEVEL_TAG` would go for
       `foot-features`. **Both default tables are generated, not typed**: the
       256-entry colour map by compiling the C `cube6()/cube36()` macros, the
       URL regex by re-escaping the C string literals — a hand-typed copy of
       the regex silently failed to compile (unmatched parenthesis), which is
       exactly the drift the generator avoids.
     * **C2n** `config_clone()`, `config_free()`, `config_font_list_clone()`,
       `key_binding_list_clone()` and `open_config()`. Ownership is the whole
       difficulty: inside one binding list, the first binding with
       `master_copy` set owns the argv/text/regex-name allocation and the
       remaining combos alias it, so the clone must reproduce that aliasing
       *into the clone* or `config_free()` frees the same argv twice.
     * **C2o** `value_to_fonts()`, `config_font_parse()`,
       `config_font_list_destroy()`, `check_if_font_is_monospaced()` and
       `get_shell()`. Fontconfig types are opaque, so nothing is mirrored;
       `check_if_font_is_monospaced()` reads exactly two fcft fields, which go
       through accessors rather than mirroring ~30 fields of layout.
       `get_shell()` mirrors Linux `struct passwd` (7 pointers + uid/gid).

     **What remains in config.c, and why** (all of it is deliberate):
     `log_and_notify[_va]()`, `log_and_notify_errno[_va]()`,
     `log_contextual[_errno]()` — Zig cannot *define* variadic functions, so
     they either stay here or move to `log.c` (open decision D-less: §12.7);
     `config_regex_compile()` (`regex_t`); `config_fcft_glyph_advance_x()` /
     `config_fcft_font_name()` (fcft layout); and a dead `#if 0
     conf_modifiers_to_mask()` that upstream deleted.

     **Test coverage grew with it.** `tests/test-config.c` (the oracle: it
     `#include`s `config.c` *and* links `config.o`) gained
     `test_key_binding_sequences()`, `test_default_url_regex()` (all 27 cases
     of the UNITTEST that had to move with the string),
     `test_config_load()` (every default `config_load()` assigns, then a
     clone/free round trip that includes a multi-combo pipe binding and a
     `[regex]` binding to exercise the `master_copy` aliasing),
     `test_config_load_from_xdg()` (`$HOME/.config`, `$XDG_CONFIG_HOME`, the
     no-config fallback, `errors_are_fatal`) and `test_font_helpers()`.

     **Two live bugs surfaced in C2n, both invisible to the test suite:**
     `xstrjoin()` copied `n2+1` bytes from an `n2`-byte source (only reachable
     through `open_config()`, which the tests bypass by passing an explicit
     `conf_path` — `scripts/smoke.sh` aborted instantly); and the empty
     scrollback-indicator string used `xc32dup(&[_:0]u32{})`, whose backing
     array has size 0, so the dup walked off the end (the replaced C UNITTEST
     only passed because the adjacent rodata happened to be zero). **Lesson:
     `meson test` is necessary but not sufficient — a chunk that touches
     start-up paths needs `scripts/smoke.sh` too.**
   * C3: per-section option tables, one section per commit (`main`, `cursor`,
     `mouse`, `colors`, `key-bindings`, `url`, `bell`, `scrollback`, …).
4. **Mid-tier (~3.5k):** `ime`, `key-binding`, `url-mode`, `search`.
5. **Standalone binaries:** `client` (footclient) and `server` — they share
   `main`'s setup; port once `config`/`wayland` are stable.

**Exit criteria:** `config.c` reduced to the variadic loggers (+ the two
`regex_t`/fcft accessors); `terminal` T9/T10 unblocked; shim line count
reduced by at least a third. (`config.c` cannot reach zero while it defines
variadic functions — see §12.7.)

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

**The loop** (added 2026-11-25, after measuring it):

    scripts/dev-check.sh     # build/ only: ~15 s
    scripts/full-check.sh    # the commit gate: 3 dirs + smoke, ~10 s warm

Both are thin wrappers, but two things matter for speed:

* `compile_zig.py` used to look for `MESON_BUILD_ROOT` to pick the optimize
  mode. Meson does **not** export that to `custom_target` commands, so every
  build dir silently compiled Zig in ReleaseSafe - the debug dir's
  `config.zig` took 27 s instead of 0.8 s, and a `terminal_types.zig` touch
  (21 dependent modules) took **215 s**. It now falls back to the directory
  the object is written to, which is always inside the build dir. Same touch
  is now **13 s**, a full 36-object rebuild 18 s.
* Never run two ninja invocations against the same build dir: they serialise
  on the build-dir lock and look like a hang.

`full-check.sh` builds the two debug dirs in parallel and `build-release`
afterwards - ReleaseSafe codegen dominates the wall time and running it
alongside two debug builds only oversubscribes the machine.

Side benefit of the fix: `build/` is a real Zig **Debug** build again, so the
harness now runs with Zig's runtime safety checks (integer overflow, bogus
pointer arithmetic) active - it caught nothing yet, and the box-drawing
oracle output is byte-identical between Debug and ReleaseSafe.


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
   **Done** (C2o): T9/T10/T11 are unblocked.
7. ~~**Where do the variadic loggers live?**~~ — **answered**: Zig *can*
   define C-variadic functions (`export fn f(fmt: [*:0]const u8, ...)` +
   `@cVaStart`/`@cVaCopy`/`@cVaEnd`, forwarded to `vfprintf`/`vsnprintf`).
   `log_msg`, `log_errno`, `bug()` and config's `log_and_notify*()`/
   `log_contextual*()` are all Zig now; the only remaining risk is a platform
   whose `va_list` layout differs from what Zig assumes when forwarding to
   `vfprintf`/`vsnprintf` (covered for x86-64 by the harness's stderr-capture
   tests; re-check on aarch64 before shipping). Keep Definition-of-Done #1 as
   "no module-specific C left", not "no C left".
8. **`struct seat`/`struct wayland`: mirror in full, or keep accessor shims?**
   Recommendation: **mirror in full, with the ABI probe**, in two stages
   (`wayland` + `wayl_surface` first, then `seat` + its nested `kbd`/
   `pointer`/`touch` groups). Rationale: `input.c` alone touches `seat->`
   356 times across a dozen fields, and `render.c` 88 times; per-field
   accessors would be hundreds of shims and would make the Zig code
   unrecognisable, while a mirror is ~250 lines of `extern struct` that the
   probe pins. The existing `terminal_shim_seat_*` (3), monitor/window (9)
   accessors then get deleted in Track B3.
9. **Where do the last C files land?** After `render`/`wayland`/`input`, the
   shims that only exist because a struct is not mirrored (`shm`'s
   `__SIZEOF_POINTER__`/`FALLOC_FL_PUNCH_HOLE` one-liners, `slave.c`'s
   constants accessor, `debug.c`'s ASAN hook, `config.c`'s `regex_t`) stay:
   each encodes compile-time knowledge Zig does not get from meson. Track E1
   only deletes the *struct-mirror* shims.

---

## 13. Sequenced backlog (refreshed 2026-11-24)

State: **35,870 of 48,830 C lines gone (73.5%)**, ~59% by effort, 35 modules
ported, 603 harness assertions, `meson test` 5/5 in three build dirs.
Remaining module C: 12,960 lines, plus 2,545 lines of `*-shim.c` accessors.

**`wayland` is done.** `wayland.c` is down from 2,884 lines to **359**, and what
is left is glue rather than logic: the fourteen generated-protocol listener
*tables* (their layout comes from the generated headers, so C pins it for
free), the tiny `wayland_shim_add_*_listener()` forwarders, and the three FDM
callbacks (`fdm_hook`, `fdm_wayl`, `fdm_repeat`) that the FDM hands opaque
pointers to. `wayland.zig` holds the other ~3,000 lines.

`smoke.sh` now launches **real windows**: weston's headless backend creates no
`wl_seat`, so foot refused to start ("no seats available"). When `Xvfb` is
installed the script starts weston's `x11-backend.so` inside a throwaway Xvfb,
which has a virtual keyboard and pointer; the whole five-launch phase
(80x24, 132x43, 20x5, maximized, fullscreen) runs inside `full-check.sh`.

**`terminal.c` is deleted.** Its prototypes moved into `terminal.h` and its
two `UNITTEST` constructors moved into the harness (`term_erase_scrollback()`'s
selection/sixel cases and the emoji variation-sequence table check), so the
Debug-build assertions they ran are not lost. Track C is done.

Track C is underway: C1 (the IME wrappers) is in (`1515fd13`), C2 (mouse grab
and CSD cursor shapes) is in. The build loop was also measured and fixed - see
section 10; a `terminal_types.zig`-touching rebuild went from 215 s to 13 s.

C2 needed one field of `struct key_binding_set` (`selection_overrides`).
Rather than mirror all of `key-binding.h` early, `terminal.zig` carries a
five-field local mirror whose layout is pinned by a compile-time
`@offsetOf`/`@sizeOf` check (96/104, verified against C). It moves into
`terminal_types.zig` with the rest of the header when `key-binding.c` is
ported (D5).

Track B is done (commits ec838c9a, aef90c27): **all of `wayland.h` is mirrored
and ABI-pinned**, `struct seat` included, and the 18 accessors that existed
only to read those fields are gone. Milestone **M1** is reached - `input`,
`ime`, `key-binding`, `render`, `wayland` and `terminal`'s IME/xcursor code
can all be ported, and the harness can fabricate a `struct seat`/`struct
wayland` the same way it fabricates a `struct terminal`.

`box-drawing` is finished (A1-A5c, commits 10cd275b..effdbe5d): the module is
3,374 lines of Zig, `box-drawing.c` is deleted, and every shape family is
verified byte-identical against the last C build through the FOOT_BOX_DUMP
differential oracle (786 codepoints in three ranges, FNV-1a per glyph).

Every chunk below is one commit, follows §9's recipe, and passes §10's
verification contract (3 build dirs + smoke + ABI probe + new tests).
Estimates are for one developer and are deliberately pessimistic.

### Track A — finish the leaves that need no new mirror (~4–5 days)

Nothing in Track A is blocked on `seat`/`wayland`, so it can be done in any
order and in parallel with someone starting Track B.

| Chunk | Work | Files | Est. |
|---|---|---|---|
| **A1** done | `box-drawing` scaffolding: move `struct buf` to `box-drawing.h`, mirror it in `terminal_types.zig` (+ `expectAbi`), port `_thickness`, `_hline`/`_vline`/`_rect`/`_*_middle` primitives, `change_buffer_format` | box-drawing.c/h, terminal_types.zig | 0.5d |
| **A2** done | `box-drawing` line family: 0x2500–0x254x light/heavy/double h & v lines, all dash variants, the 0x250c–0x254b corners and tees | box-drawing.c/.zig | 1d |
| **A3** done | `box-drawing` mixed/diagonal/arc family: 0x254c–0x257f (mixed light/heavy, arcs, diagonals, half lines) | box-drawing.c/.zig | 1d |
| **A4** done | `box-drawing` blocks: 0x2580–0x259f blocks/shades/quadrants, 0x25e2–0x25e5 triangles, 0x1fb00–0x1fb8b sextants/octants/wedges/eighth blocks, 0x1cc00+ legacy computing tables | box-drawing.c/.zig | 1.5d |
| **A5** done | `box-drawing` dispatch: the 251-case `draw_glyph()` switch, `box_drawing()` itself (glyph allocation, metrics, `fcft_glyph` fill-in), delete `box-drawing.c` | box-drawing.c/.zig | 1d |
| **A6** done | `quirks` (86): weston detection + CSD subsurface desync, 4 shims for `wl_subsurface_set_{de,}sync` and the csd surface array | quirks.c/.zig, terminal-shim.c | 0.5d |
| **A7** done | `foot-features` (42): pass `foot_version`, `pgo`, `ime`, `graphemes`, `toplevel-tag`, `blur`, `assertions` as `compile_zig.py` build options and build the string in Zig | foot-features.c/.zig, meson.build | 0.25d |
| **A8** done | shim audit: document the removal criterion in each `*-shim.c`, delete anything already dead (e.g. leftover monitor/window accessors that Track B replaces) | *-shim.c | 0.25d |

`box-drawing` verification (A1-A5, done): the differential oracle is a
harness mode (`FOOT_BOX_DUMP=1`) that renders U+2500..U+259F,
U+1FB00..U+1FB8B and U+1CC00..U+1CDE5 (786 codepoints) and prints an FNV-1a
hash of each pixmap; the old and new builds are diffed for byte-identical
output. It caught a real bug (wrong PIXMAN_a8/PIXMAN_a1 constants making the
shade format switch a no-op). The permanent test is structural and
font-independent: band contiguity, thickness <= height/3, full-cell coverage
for the full block, monotonic shade coverage, quadrant corner checks,
solid-shade uniformity at 0x40/0x80/0xc0. `FOOT_BOX_PIXELS=<cp>` dumps one
glyph's raw pixmap next to its hash.

### Track B — the mirrors that unlock the core (~1 week) [gate for C/D]

| Chunk | Work | Est. |
|---|---|---|
| **B1** done | Mirror the 19 structs in `wayland.h` **except** `struct seat`: `wayland`, `wayl_surface`, `wl_window`, `monitor`(+outputs), `clipboard`, `data_offer`, `renderer`/`chains`/`damage` subsets. Extend `gen_abi_probe.py` + `expectAbi` tests. No behaviour change; the C code keeps using the same structs. | 2–3d |
| **B2** done | Mirror `struct seat` (~100 members incl. nested `kbd`, `pointer`, `touch`, `repeat`) and `tll(struct seat)`; pin every offset with the probe; switch `terminal-shim.c`'s 3 seat accessors + the monitor/window ones to direct Zig field access and delete them. | 2–3d |
| **B3** done | Delete the now-dead accessors; re-point `terminal.zig` (DPI/scale), `unicode-mode.zig` and `slave`/`shm` call sites at the mirrors. | 0.5d |

Milestone **M1** (reached): `struct seat` and `struct wayland` are Zig-visible, so
`input`, `ime`, `key-binding`, `selection`'s data-source listeners, `render`
and `terminal`'s xcursor/IME/init code all become portable **and testable**
(the harness can fabricate `struct seat`/`struct wayland` the same way it
fabricates `struct terminal` today).

### Track C — `terminal`'s tail (after B2, ~4–6 days)

| Chunk | Work | Depends on | Est. |
|---|---|---|---|
| **C1** done | T4 IME accessors (`term_ime_is_enabled/enable/disable/reset/set_cursor_rect`, ~60 lines) | B2, ime.c | 0.5d |
| **C2** done | T8 xcursor: `term_mouse_grabbed`, `term_xcursor_update_for_seat`, `term_xcursor_update` from `terminal.c` plus `xcursor_for_csd_border()` and its four corner helpers from `input.c` (~110 lines). `terminal.c` is 1,609 lines, `input.c` 3,618. 16 new harness checks | B2 | 0.5d |
| **C3a** done | T11a part 1: `fdm_delayed_render`, `term_window_configured` and `initialize_render_workers` (~105 lines). The C11 thread calls are plain libc externs through the sem/mtx/cnd byte blobs in the mirror; `thrd_err_as_string()` is a `util.h` static inline, so it gets one shim. 7 new harness checks (a real timerfd pair and a real worker thread) | B1, render | 1d |
| **C3b** done | T11a part 2: `add_utmp_record()`/`del_utmp_record()`. `UTMP_ADD`/`UTMP_DEL`/`UTMP_DEL_HAVE_ARGUMENT` now reach Zig as `utmp_add`/`utmp_del`/`utmp_del_have_argument` build options (plus `utmp_enabled` for the `-Dutmp-backend=none` arm, which still returns `true` without spawning). 4 new harness checks; the disabled configuration was compiled by hand to prove the `comptime` arm | C3a | 0.5d |
| **C4a** done | T11b part 0: `term_kbd_focus_out()` and `term_surface_kind()` (~90 lines), the last two read-only leftovers. 8 new harness checks (focus-out with a real pty, and every CSD surface) | C3b | 0.5d |
| **C4b** done | T11c: `term_shutdown`, `shutdown_maybe_done`, `fdm_shutdown`, `fdm_terminate_timeout`, `fdm_client_terminated` (~218 lines). Only `term_destroy` and `wayl_win_destroy` remain externs. 8 new harness checks run the real shutdown against a real `fdm` | C4a | 1d |
| **C5** done | T11d part 1: `term_destroy()` + `sig_alarm()` (~240 lines) — the whole teardown, including the worker-pool wake/join and the blocking SIGALRM/waitpid slave reap. 3 new harness checks (a bare terminal, NULL, and a terminal with a live render worker that must be joined) | C4b | 1d |
| **C6** done | T11d part 2: `term_reset()` (~150 lines). 16 new harness checks cover the soft path (modes, charsets, VT state, `OSC 8` buffer, theme left alone) and the hard path (grid switch, theme reapplied, cursors/scroll region, rows re-allocated and the scrollback freed) | C5 | 1d |
| **C7** done | T11b: `term_init()` (~350 lines of Zig). Opens the pty + seven timer FDs, registers the fdm callbacks, builds the terminal from the config, spawns the slave, creates the window, loads fonts and starts the workers - the C's two `goto` cleanups became `closeFds()`/`termInitFail()` helpers. 1 new harness check (the pty-open failure path). **No functions are left in `terminal.c`** | C6, wayland, render | 2d |
| **C8** done | `terminal.c` retired: prototypes moved to `terminal.h`, both `UNITTEST` constructors moved into the harness, file deleted from `meson.build`. 5 new harness checks | C7 | 0.5d |

**C5 found a real toolchain trap:** C11 `thrd_create()`/`thrd_join()` are
broken when called *from a Zig object* here — `thrd_create()` returns
`thrd_success`, the thread runs, and then `thrd_join()` returns
`thrd_error` without reaping it (reproduced in a 20-line standalone program;
the identical calls from C work). `terminal.zig` therefore calls
`pthread_create()`/`pthread_join()` directly — the same functions glibc's
C11 wrappers call, and `thrd_t` is `pthread_t` — with a comment recording
the experiment. The only visible difference is the error code logged on
failure (`errno` instead of `thrd_*`).

### Track D — the core (~3–4 weeks)

Order matters: `search` and `wayland` first (they unblock the rest), then
`render`, then `input`, then the wayland-protocol-heavy leftovers.

| Chunk | Module | Why this order | Est. |
|---|---|---|---|
| **D1** done | `search` (1,512): the matching core (`matches_cell`, `find_next`, the match iterator, the query buffer), the lifecycle (`search_begin`/`search_cancel`), the coord/extend/word/line selectors, `execute_binding()` and `search_input()` — 1,704 lines of Zig, `search.c` deleted. `struct key_binding`/`key_binding_set` are mirrored locally (56/104 bytes, pinned at compile time), and `char32.h`'s c32 comparisons plus `grid_row_absolute_in_view()` got shims. 15 new harness checks drive the buffer edits through `search_input()` with a synthetic binding list | 2–3d |
| **D2a** done | `wayland`'s monitor/output layer: `output_update_ppi()`, the six `wl_output` callbacks, the four `zxdg_output_v1` callbacks and `clock_id()` (~160 lines) into a new `wayland.zig`. The generated-protocol listener *tables* stay in C (they are generated types; C pins their layout for free) and point at the Zig exports. 21 new harness checks: DPI/PPI maths from geometry + mode + logical size + scale, name/description replacement, and the presentation clock | B1 | 1d |
| **D2b** done | `wayland`: surface scaling (`surface_scale_explicit_width_height()` in both the fractional/viewport and the integer `set_buffer_scale` arms, plus its three wrappers) and the two CSD-visibility predicates. `wl_surface_set_buffer_scale()`/`wp_viewport_set_destination()` are generated static inlines, so they got shims. The scaling path is exercised end-to-end by the five smoke launches; 11 new harness checks cover the CSD predicates | D2a | 1d |
| **D2c** done | `wayland`: urgency/activation (`wayl_win_set_urgent()` and its token callback), `wayl_win_ring_bell()` and `wayl_do_linear_blending()`. `xdg_system_bell_v1_ring()`/`xdg_activation_v1_activate()` are generated static inlines, so two more shims. 5 new harness checks | D2b | 0.5d |
| **D2d** done | `wayland`: the window sub-surface lifecycle — `wayl_win_subsurface_new_with_custom_parent()`, `wayl_win_subsurface_new()`, `wayl_win_subsurface_destroy()` (colour management, viewport, `wl_subsurface`, `wl_surface`, empty input region for the non-interactive ones). 13 new `wayland_shim_*` forwarders for the generated `wl_surface`/`wl_region`/`wp_viewport`/`wp_color_*` inlines. Every smoke launch creates and tears down five sub-surfaces (search, url, notify trio), so this path has real runtime coverage | D2c | 1d |
| **D2e** done | `wayland`: `wayl_flush()` (the EAGAIN/POLLOUT retry loop), `wayl_roundtrip()`, and `wayl_reload_xcursor_theme()` (XCURSOR_SIZE/XCURSOR_THEME parsing, server-side-cursor short circuit, scale-based reload). 3 new harness checks for the short-circuit paths; the flush/roundtrip pair runs on every smoke launch | D2d | 0.5d |
| **D2f** done | `wayland`: the CSD trio — `csd_instantiate()` (seven sub-surfaces, then the close/min/max buttons parented to the title bar), `csd_destroy()` and `csd_reload_font()` (`pixelsize=` from `csd.title_height` × scale). 5 new harness checks, including a real fcft font through `csd_destroy()` | D2e | 0.5d |
| **D2g** done | `wayland`: `monitor_destroy()`, `update_term_for_output_change()` (scale → fonts → CSD font → forced-resize ordering), `update_terms_on_monitor()` and the two `*_done` listeners that call it — the monitor listener set is now complete. `terminal_types.zig`'s `Tll` mirror is head-only, so iteration uses `tll.zig` via a pointer cast. 2 new harness checks | D2f | 0.5d |
| **D2h** done | `wayland`: `wayl_win_destroy()` — the touch-focus reset, the "unmap every surface, then roundtrip" sequence that makes the compositor drop keyboard/pointer focus, the url/subsurface/CSD teardown, the six `shm_purge()` calls and the activation-token list. 10 new shims; `HAVE_EXT_BACKGROUND_EFFECT` is resolved inside `wayland_shim_destroy_background_effect()` so the conditional stays in C. Every smoke launch destroys a window | D2g | 1d |
| **D2i** done | `wayland`: `wayl_win_init()` — surface + listener attachment, fractional scale, background effect, alpha region, xdg surface/toplevel, app-id, toplevel tag, icon, colour management (with its three warning variants), the CSD/SSD preference ladder, `wayl_activate()`, then the overlay and render-timer sub-surfaces. The listener *tables* are still `static` in wayland.c, so five tiny `wayland_shim_add_*_listener()` forwarders attach them. The five smoke launches are the regression test: without the listeners attached the window never receives a configure and the launch times out | D2h | 1.5d |
| **D2j** done | `wayland`: `wayl_win_alpha_changed()` (opaque region, and the blur region with its one-shot "compositor does not support it" warning) plus the XDG activation flow — `wayl_get_activation_token()`, `activation_token_v1_done()` (which had to be renamed: url-mode.c has its own static `activation_token_done`) and `wayl_activate()`. The activation-token listener table stays in C with a forwarder | D2i | 0.5d |
| **D2k1** done | `wayland`: the seat wiring — `seat_add_data_device()`, `seat_add_primary_selection()`, `seat_add_text_input()` (the `#if FOOT_IME_ENABLED` guard is a constant here, as elsewhere), `seat_add_key_bindings()` and the full `seat_destroy()` teardown (buttons list, xkb objects, repeat timerfd, cursor theme/surface/viewport/callback, clipboard+primary sources/offers/devices, cursor-shape device, keymap/pointer/touch release, text input, seat release, IME pending state, four string frees). The data-device/primary-selection/text-input listener tables live in selection.c and ime.c, so three forwarders attach them. 3 new harness checks incl. the button-list drain | D2j | 1d |
| **D2k2** done | `wayland`: the configure path — `xdg_toplevel_configure()` (all thirteen `xdg_toplevel_state` values decoded from the `wl_array`), `xdg_toplevel_close()`, `xdg_toplevel_configure_bounds()`, `xdg_toplevel_wm_capabilities()` and `xdg_surface_configure()` (CSD instantiate/destroy on transitions, titlebar/border size subtraction, ack, `RESIZE_BY_CELLS` vs `RESIZE_FORCE`, visual focus, visibility reports, the alpha/refresh pair on fullscreen changes, the compositor-appeasing commit, and `term_window_configured()` on the first configure). The listener tables stay in C. 15 new harness checks decode the state and capability arrays; maximized/fullscreen smoke launches drive the surfaces path | D2k1 | 2d |
| **D2k3** done | `wayland`: the `wl_surface` listener — `surface_enter()`/`surface_leave()` (monitor lookup, the window's `on_outputs` list, and the DPI/font refresh) — plus `verify_iface_version()` and the two preferred-buffer callbacks. 4 new harness checks | D2k2 | 0.5d |
| **D2k4** done | `wayland`: the small protocol listeners — `shm_format()` (the three 10/16-bit formats; the debug description block is compiled out by `LOG_ENABLE_DBG 0`), `seat_handle_name()`, `xdg_toplevel_decoration_configure()` (CSD/SSD mode → pending `csd_mode`), `fractional_scale_preferred_scale()` (÷120, no-op when unchanged) and `ext_background_capabilities()`. 10 new harness checks | D2k3 | 0.5d |
| **D2k5** done | `wayland`: `wayl_init()` (calloc, FDM hook, `wl_display_connect`, registry + roundtrip, the seven hard interface requirements and five warnings, the second roundtrip that fires the deferred listeners, the monitor summary log line, non-blocking socket, `fdm_add`, `wl_display_prepare_read`) and `wayl_destroy()` (the "terminals still running" sweep, monitor/seat teardown, 24 interface destroys, `fdm_del_no_close`, flush + disconnect). `fdm_hook`, `fdm_wayl` and `registry_listener` stay in C behind four forwarders; 28 new shims. 2 new harness checks run the real init-failure path | D2k4 | 1d |
| **D2k6** done | `wayland`: `seat_handle_capabilities()` — keyboard/pointer/touch object creation and release, the client-side pointer surface + viewport, the cursor-shape device, and the touch inhibit/restore rules. Seven more shims; the keyboard/pointer/touch listener tables come from input.c through three forwarders. 3 new harness checks; every smoke launch drives it (weston announces pointer+keyboard) | D2k5 | 1d |
| **D2k7** done | `wayland`: `handle_global()` — all 23 interfaces, each with its required/preferred version (`min(version, preferred)`), including the seat's repeat timerfd + xkb compose setup and the "late global" re-scans (data device, primary selection, text input, xdg-output per monitor). Rather than mirror `struct wl_interface`, `wayland_shim_iface_id()` matches the name and `wayland_shim_registry_bind()` performs the bind in C, so Zig switches on an integer and the generated symbols stay in C. 5 new harness checks drive the unknown/too-old paths | D2k6 | 2d |
| **D2k8** done | `wayland`: the tail — `handle_global_remove()` (monitor branch: log, `surface_leave()` for every terminal mapped there because compositors do not unmap first, then `monitor_destroy()`; seat branch: warn and synthesise the keyboard/pointer leave the compositor owed us, then `seat_destroy()`; unknown branch warns), the `fixes`-gated `wp_fixes_v1.ack_global_remove` helper, `colorManagerCreateImageDescription()` with the five `wp_color_manager_v1` callbacks (parametric creator → linear TF + sRGB primaries → image description), and `xdg_wm_base_ping()`. 3 new harness checks (unknown global, monitor removal, seat removal — the seat needs a real key-binding manager because `seat_destroy()` calls `key_binding_remove_seat()`). `wayland.c` is now 359 lines of listener tables + FDM glue | D2k7 | 1d |
| **D3a** done | `render`: the drawing primitives — `attrs_to_font()`, the four `color_hex_to_pixman*()` variants (sRGB decode table vs linear expansion, alpha premultiply), `color_blend_towards()`, `color_dim()` (custom-dim table + theme blend direction), `color_brighten()`, and the painters `draw_hollow_block()`, `draw_beam_cursor()`, `draw_underline_cursor()`, `draw_underline()`, `draw_styled_underline()` (double/dashed/dotted/curly), `draw_strikeout()`, `cursor_colors_for_cell()` and `draw_cursor()`. `pixman_color_t`/`pixman_rectangle16_t` are mirrored (comptime-sized); `pixman_trapezoid_t` is not — the curly underline passes its geometry to `render_shim_curly_underline()`. `fcft_font` metrics come from six `terminal_shim_fcft_font_*()` accessors rather than mirroring the library struct. 23 new harness checks, eleven of them reading pixels out of a real pixman image | D2k8 | 1d |
| **D3b** done | `render`: the frame bookkeeping — `dirty_cursor()`/`dirty_old_cursor()` (cell + row dirtying, plus remembering the cursor for the next frame), the four `render_refresh*()` flag setters, and the rate-limited title/app-id/icon updaters, which now share one `rateLimit()` helper (8333 µs window, `timerfd_settime()` for the remainder). `render_update_title()` lost its `static`; `grid_row()` and `urls_mode_is_active()` are static inlines in the headers, so two more `terminal_shim_*` accessors. 13 new harness checks, including a real timerfd proving the rate limiter arms itself | D3a | 0.5d |
| **D3c** done | `render`: `render_row()` (right-to-left so wide glyphs win), `render_urgency()` (the red border hints) and `render_margin()` (default background outside the grid, reverse handling, fullscreen alpha, the four `pixman_region32_union_rect()` damage adds and the `wl_surface_damage_buffer()` calls). Two new shims: `render_shim_region_union_rect()` (pixman_region32_t is not mirrored) and `wayland_shim_surface_damage_buffer()`. `render_cell()` lost its `static` so Zig can call it. 7 new harness checks paint a real 64×64 buffer and read the pixels back | D3b | 0.5d |
| **D3d** done | `render`: the CSD geometry and commit path — `get_csd_data()` (border/title/button widths from the scale, the fractional-scaling-safe offsets, the whole `enum csd_surface` switch) plus `csd_commit()` (scale, attach, damage, commit) and `render_csd_part()` (solid fill). `struct csd_data` is a 16-byte extern struct; the three wl_surface calls were already shimmed. 12 new harness checks walk every surface, the "no wm capability", maximized and too-narrow cases | D3c | 0.5d |
| **D3e** done | `render`: **`render_cell()`** — the 510-line heart of the renderer. Colour-source resolution for fg/bg (default/base16/base256/RGB), selection colours with the invert-on-collision rule, reverse and the three alpha modes (with the fullscreen assertion), dim/bold-in-bright/blink, glyph selection through the four custom-glyph caches (box drawing, braille, octants, legacy — allocated lazily under the worker lock), composed characters with grapheme shaping and forced widths, spacers, the overflowing-glyph bleed bookkeeping, clip + damage, background, the early blink-timer arming, colour-emoji vs mask compositing, combining-character pen arithmetic, styled underlines from `row->extra->underline_ranges`, strikeout, url underlines and both cursor paths. Six new `render_shim_*` helpers keep `pixman_region32_t` and the `mtx_t` worker lock in C. 13 new harness checks render real cells onto a pixman image | D3d | 1.5d |
| **D3f** done | `render`: `grid_render_scroll()` and `grid_render_scroll_reverse()` — the "SHM scroll or memmove" heuristic (`lines + region.start + (rows - region.end) < rows/2`, guarded by `shm_can_scroll()`), the margin restore after a successful SHM scroll, the memmove fallback (`copyForwards` for up, `copyBackwards` for down, matching `memmove()`'s overlap semantics), and the surface damage + buffer damage that follow. 6 new harness checks scroll a real byte buffer and read it back | D3e | 0.5d |
| **D3g** done | `render`: the sixel path — `render_sixel_images()` (viewport-relative start/end with wrap-around, sorted-list early exits, `sixel_sync_cache()`), `render_sixel()` (chunking consecutive visible *dirty* rows to avoid recompositing, the opaque path that only marks cells clean unless the last row/column is partially covered, the transparent path that renders the cells underneath via `render_row()`), and the chunk compositor with its margin clamping. One new shim for a composite with an explicit operator and source offset. 8 new harness checks composite a real sixel image and check the clean/dirty bookkeeping | D3f | 1d |
| **D3h** done | `render`: the CSD button painters — `get_csd_button_fg_color()`, the shared button geometry (a square of a third of the buffer, `min(width/2, scale)` thick), `render_csd_button_minimize()`, `_maximize_window()`, `_maximize_maximized()`, `_maximize()` and `_close()` (four pixman triangles, kept in C as `render_shim_close_button()`), plus `any_pointer_is_on_button()`. 11 new harness checks paint the buttons on a real 36×36 buffer and verify each glyph's shape | D3g | 0.5d |
| **D3i** done | `render`: the CSD painting layer — `render_csd_title()` (configured title colour, dimming when unfocused, `M`-advance margin, `ambstoc32()` title), `render_csd_border()` (transparent fill + the visible strip at `border_width - border_width_visible`), `render_csd_button()` (per-button theme colour, dim-until-hovered, background + glyph), and `render_csd()` (the eight-surface loop, position/skip decisions, `shm_get_many()` and the three painters). Also **`render_osd()`**, the text painter: clip, background, fcft text run with a per-character fallback, baseline from the font metrics, colour-emoji vs mask compositing, the attach/damage/opaque-region/commit tail. `struct fcft_text_run` stays in C behind three shims; `wl_region`/`wl_surface_set_opaque_region` behind a fourth. 12 new harness checks | D3h | 1.5d |
| **D3j** done | `render`: **`render_overlay()`** — the style ladder (search > flash > unicode mode), the unmap path, the single-pixel fast path (`wp_single_pixel_buffer_manager_v1` + viewport destination, one buffer reused until the style changes), the SHM path's two branch shapes (search diffing vs a full flash/unicode fill) and the search-damage region algebra (last frame's see-through minus this frame's = dim, the inverse = clear, the union = damage bounds). **`render_ime_preedit()`** — the per-seat pre-edit overlay: the viewport-relative cursor row, the extra-cell rule for a trailing cursor, the clipping window when the string does not fit (`start`/`end`/`ime_ofs`, spacer-aware), copying+dirtying the span, the per-cell `render_cell()` calls, the bar/hollow cursors and their pending rect, and the restore. `pixman_region32_t` stays in C behind nine `render_shim_region_*` helpers (Zig owns a 24-byte blob, the same size as `Render.last_overlay_clip`); `wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer()` is a generated static inline, so one more shim. 16 new harness checks: pre-edit restoration/dirtying, cursor-rect placement, the overlong/spacer/double-width windows, a hidden cursor, and the overlay unmap path | D3i | 1.5d |
| **D3k2** | `render`: `render_scrollback_position()` and `render_render_timer()` | D3j | 1d |
| **D3k** | `render`: search-box and url painting | D3j | 2d |
| **D3l** | `render`: the worker thread, damage tracking, `grid_render()`, `render_resize()` and the remaining xcursor/tiocswinsz glue | D3k | 3–4d |
| **D4** | `input` (3,687) — split into D4a keyboard/legacy+kitty protocols, D4b pointer/mouse/touch, D4c compose/IME plumbing | after B2 + key-binding | 1–1.5w |
| **D5** | `key-binding` (661), `ime` (540), `url-mode` (833), `selection` S1+S3 (~600) | after B2/D4 | 4–5d |
| **D6** | `main` (770), `server` (707), `client` (679) | last; they tie everything together and are only fully testable once a window opens | 4–5d |

### Track E — endgame (~2–3 days)

- **E1** delete the struct-mirror shims (not the compile-time-knowledge ones,
  see §12.9); shrink `terminal-shim.c` (1,175) and `selection-shim.c` (243).
  Several newer shims are generated-protocol static inlines rather than struct
  mirrors — those stay (§12.9).
- **E2** decisions to close: `ReleaseSafe` vs `ReleaseFast` (§12.4 — fuzz
  first), PGO, `translate-c` spike (§12.1 — recommend abandoning it: the
  probe + mirrors have not produced an ABI bug yet), meson vs `build.zig`
  (§12.3 — stay on meson).
- **E3** refresh the LOC scoreboard, Definition-of-Done checklist, run the
  full matrix + smoke, tag the branch.

### Critical path and total

```
A1-A5 box-drawing ──┐
A6-A8 leaves ───────┴─> (independent)

B1 wayland mirror ──> B2 seat mirror ──> B3 cleanup
        │                    │
        │                    ├─> C1/C2 IME+xcursor
        │                    ├─> D5 key-binding/ime/url-mode/selection
        │                    └─> D4 input
        └─> D2 wayland ──> D3 render ──> C3-C6 terminal tail ──> D6 main/server/client
D1 search (starts as soon as someone is free)
```

**Total: 6–7 weeks for one developer** (A ~1w, B ~1w, C ~1w, D ~3–4w, E ~0.5w),
or **3–4 weeks with 2–3 parallel workers** (A ∥ B, then C ∥ D1 ∥ D2).

### Standing rules (unchanged)

1. One chunk per commit; no behaviour change in a port commit.
2. Never `.?` a pointer C allows to be NULL; never `unreachable` where C
   degrades gracefully.
3. Memory allocated by C is freed with `std.c.free`, never a Zig allocator.
4. `terminal_types.zig` changes ⇒ regenerate `abi_probe.c`.
5. `meson test` in `build`, `build-disabled`, `build-release` + `env -u
   WAYLAND_DISPLAY scripts/smoke.sh` before every commit.
6. Merge `origin/master` weekly (R7) and port upstream fixes immediately.

### Standing caveat

There is no compositor in this container, so *nothing* in Track B–D is
verified visually. The substitutes are: the headless harness (fabricated
structs + real pty/memfd/fonts), `foot --pty`, `foot -C -c <file>`, and the
config oracle. Once a compositor (weston/cage/sway) is available, add
`scripts/smoke.sh` window launches and a screenshot-diff job to CI before
declaring Phase 3 done.


---

## 14. Refresh 2026-11-25 @ `f67b6f48` — continuation from D3i

Measured on this checkout, not carried over from §1.

### 14.1 Scoreboard

| Metric | 2026-11-24 | 2026-11-25 | Δ |
|---|---|---|---|
| Branch | +167 commits | **+176 commits** vs `origin/master` | +9 |
| Foot-owned module C | 12,960 | **12,709** of 48,924 | −251 |
| C eliminated | 73.5% | **74.0%** (36,215 lines) | +0.5pt |
| `*-shim.c` accessors | 2,545 | **2,524** (11 files) | −21 |
| Zig source | ~37.8k | **39,248** lines / 41 files | +1.4k |
| Harness assertions | 603 | **600** call sites (548 `check`, 52 `check_text`) + 30 Zig `test` blocks | flat |
| `meson test` | 5/5 × 3 dirs | **5/5 × 3 dirs** (`build`, `build-disabled`, `build-release`) | ✅ |
| Real window launches | not verified | **5/5 pass** against the live `wayland-1` socket | **new** |

Per-module burn-down (share of that module's original C that is gone):

| Module | C left / original | % | Note |
|---|---|---|---|
| 31 modules | 0 / — | **100%** | `async`…`box-drawing`, `search`, `terminal`, `log`, `grid`, `csi`, `sixel`, `osc`, `vt`… |
| `config` | 35 / 4,374 | 99% | only `config_regex_compile()` (§6.3) |
| `wayland` | 359 / 2,884 | 88% | 27 listener tables + forwarders + 3 FDM callbacks |
| `selection` | 844 / 2,967 | 72% | data-device / primary-selection listeners, DND |
| `slave` | 158 / 573 | 72% | O_*/TIOCSCTTY constants, termios, execvpe shim |
| `shm` | 329 / 1,110 | 70% | globals, `wl_shm`/`wl_buffer` stubs, punch-hole `#ifdef`s |
| `debug` | 22 / 47 | 53% | ASAN stack-trace hook |
| `render` | 3,154 / 5,479 | **42%** | D3a–D3i done; 9 chunks left |
| `input` | 3,618 / 3,687 | **0%** | the single largest untouched module |
| `url-mode` | 833 / 833 | 0% | |
| `main` | 770 / 770 | 0% | |
| `server` / `client` | 707 / 679 | 0% | |
| `key-binding` | 661 / 661 | 0% | |
| `ime` | 540 / 540 | 0% | |

**Percent complete: 74% by C volume, ~60% by effort (band 58–63%), 31/45
top-level modules (46 counting `spawn_template`) with zero C left.**
**Post-D3j:** `render.c` is 3,154 → **2,701** lines, module C 12,709 → **12,256**
(75.0% of the original C gone), harness 605 → **621** checks, and
`full-check.sh` now actually launches the five windows (§14.5.1).

The effort figure is §13's 59% at 12,960 lines, advanced by the 251 lines D3e–D3i
removed — all of them render code, the most expensive per line (1.4× weight),
hence only ~+1.5pt for 9 commits. Do not read the 74% as three-quarters of the
*work*: the 12.7k lines left contain seven of the eight largest functions in
the tree (`render_resize` 478, `grid_render` 391, `render_search_box` 343,
`render_urls` 226, `render_overlay` 208, `render_ime_preedit_for_seat` 159,
`render_scrollback_position` 148) plus the whole of `input`.

### 14.2 What changed since §13 was written

* D3a–D3i landed (9 commits): render primitives, frame bookkeeping, rows/margins,
  CSD geometry/commit/buttons/painting, `render_cell()`, scroll paths, sixel,
  `render_osd()`. `render.zig` is 2,354 lines; the harness grew ~120 checks,
  many reading real pixman pixels back.
* D2k7/k8 closed `wayland`: `handle_global()`, `handle_global_remove()`, colour
  management, `xdg_wm_base_ping()`. `wayland.c` is glue only.
* **A compositor is present in this container** (`WAYLAND_DISPLAY=wayland-1`,
  `XDG_RUNTIME_DIR=/run/user/1000`). `smoke.sh` ran all five window launches
  (80×24, 132×43, 20×5, maximized, fullscreen) clean against it today. The
  "Standing caveat" above is therefore out of date *for this machine*.
* **But the commit gate does not use it.** `full-check.sh` follows standing rule
  5 and runs `env -u WAYLAND_DISPLAY scripts/smoke.sh`, so every commit since
  the rule was written has been verified **without opening a window** — exactly
  the class of regression F1 was. Fix this before the next render chunk (§14.5).

### 14.3 Next chunks, in order (one commit each, §9 recipe)

**Track D3 tail — `render` (≈9–10 dev-days).** Ordered so the pixel-heavy,
high-blast-radius functions land last, after their helpers are already Zig.

| Chunk | Work | Est. |
|---|---|---|
| **D3j** | `render_overlay()` + `render_overlay_single_pixel()` and `render_ime_preedit_for_seat()` / `render_ime_preedit()` (367 lines) | 1–2d |
| **D3k1** | presentation feedback: `sync_output`, `presented`, `discarded`, `log_presentation_statistics` + `render_init`/`render_destroy` (~120) | 1d |
| **D3k2** | `render_scrollback_position()`, `render_render_timer()`, `force_full_repaint()`, `reapply_old_damage()` (~250) | 1d |
| **D3k3** | `render_search_box()` (343) — reuses D3i's OSD painter | 1–1.5d |
| **D3k4** | `render_urls()` (226) | 1d |
| **D3l1** | `render_worker_thread()`, `render_wait_for_preapply_damage()` (~150) — the thread/lock path, keep the C11 trap from C5 in mind | 1d |
| **D3l2** | **`grid_render()`** (391) — damage apply, worker dispatch, frame callback, margins, sixel, cursor, commit | 2d |
| **D3l3** | `render_resize()` (478) + `set_size_from_grid`, `send_dimensions_to_client`, `tiocswinsz`, `delayed_reflow_of_normal_grid`, `fdm_tiocswinsz` (~200) | 2–3d |
| **D3l4** | `render_xcursor_is_valid/update/set`, `xcursor_callback`, `fdm_hook_refresh_pending_terminals`, `render_buffer_release_callback` (~270) | 1d |

Exit criterion: `render.c` deleted, `render.zig` ~3.5k lines, harness ≥ 700
checks, 5/5 window launches **with** `WAYLAND_DISPLAY` set, and a pixel-parity
dump (§14.5.2) for the cell/URL/CSD paths.

**Track D4 — `input` (≈6–8 dev-days).** Split by protocol, mechanical tables first:

| Chunk | Work | Est. |
|---|---|---|
| **D4a** | keymap tables + `keymap_data_for_sym`, `keyboard_keymap`, `keyboard_modifiers`, `keyboard_enter/leave` (mechanical, mostly data) | 1d |
| **D4b** | `key_press_release` (262) + `legacy_kbd_protocol` (158) + `kitty_kbd_protocol` (327) — port the C `UNITTEST` blocks into the harness as you go | 2–3d |
| **D4c** | `execute_binding` (469) and the binding matchers | 1–1.5d |
| **D4d** | pointer: `wl_pointer_enter/motion/leave/button/axis/frame` (~450) + scroll/mouse-binding tables | 1.5–2d |
| **D4e** | touch + IME plumbing + the remaining seat glue | 1d |

**Track D5 — mid-tier (≈5–6 dev-days).** `key-binding` (661) → `ime` (540) →
`url-mode` (833) → `selection`'s 844-line tail. Doing `key-binding` first
removes `search.zig`'s and `terminal.zig`'s local 104-byte `key_binding_set`
mirror; the `selection` tail deletes `selection-shim.c` (243) wholesale.

**Track D6 — entry points (≈4–5 dev-days).** `main` (770), then `server` (707)
and `client` (679), which share `main`'s setup. After D6 the process entry
point is Zig.

**Track E — endgame (≈3–4 dev-days).** `wayland`'s 359 glue lines, `shm`'s 329
(pull the `wl_shm` stubs behind a mirrored `struct shm_wayland_caps`), `slave`'s
158 constants/execvpe, `config`'s 35-line regex shim, `debug`'s 22-line ASAN
hook; then delete every struct-mirror shim. Note the shim count has *grown*
during D2/D3 (2,465 → 2,524) because generated protocol inlines need
forwarders — E1 must keep those and delete only the mirrors (§12.9).

**Total: ≈27–33 dev-days ≈ 5.5–6.5 weeks solo**, or ≈3 weeks with three
workers (D3 tail ∥ D4a–b ∥ D5). The old "6–7 weeks total" headline in §13 is
still roughly right for the whole project but should not be used to infer the
remaining time; use the chunk sums.

### 14.4 Critical path from here

```
D3j -> D3k1/k2 -> D3k3/k4 -> D3l1 -> D3l2 (grid_render) -> D3l3 (resize) -> D3l4
                                                     `-> render.c deleted
D4a -> D4b -> D4c -> D4d -> D4e            (input; can start in parallel now)
D5 (key-binding -> ime -> url-mode -> selection tail)   (parallel with D4)
D6 (main -> server/client)  — gated on D3l2 and D5's key-binding
E  (wayland/shm/slave/config/debug tails, shim sweep)
```

Nothing left is blocked on a missing mirror: `struct seat`, `struct wayland`,
`struct key_binding*` are all ABI-pinned (M1), which is why D4 and D5 can run
concurrently with D3 by different workers.

### 14.5 Verification changes to make before the next chunk

1. **Stop skipping the window launches. — DONE in D3j.** `scripts/full-check.sh`
   now passes `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` through when the socket exists
   (`[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]`) and only unsets it when there
   is none; the weston/Xvfb fallback stays for CI. The gate ran all five window
   launches for the first time since D3a.
2. **Add a render parity oracle** like `FOOT_BOX_DUMP`: a harness mode that
   paints a fixed cell/URL/CSD corpus into a pixman image and prints an FNV-1a
   hash per cell, diffed against a build of `origin/master`. `grim` is not
   installed, so screenshot diffing is not available yet; the pixmap dump is.
3. **Keep the probe honest**: `scripts/gen_abi_probe.py` + the
   `abi-probe-up-to-date` test on every `terminal_types.zig` touch (unchanged,
   but D3l3/D4 will add many fields).
4. **Fuzz the VT core before E2's `ReleaseSafe` vs `ReleaseFast` call** (R3) —
   still open, and `input` is the module most exposed to hostile input.

### 14.6 Untracked cruft

`git status` carries `capture/`, `inbox/`, `investigation.cany/`,
`squashfs-root/`, `craft.json`, `feed.json`, `usage.json`, `build-activity.log`.
None belong in the repo; gitignore or delete them before the next commit so
the scoreboard diffs stay readable. (`reference/` is tracked — leave it.)

