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
| **In progress** (Zig + remaining C + shims) | `terminal.c` (1,780 left), `selection.c` (844 left), `debug.c` (22 left — the ASAN stack-trace hook), `config.c` (35 left — the regex_t shim), `slave.c` (158 left — O_*/F_*/TIOCSCTTY/_CS_PATH constants, the IUTF8 termios block, signal-mask restoration and the execvpe shim; `slave.zig` is 663 lines) |
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

**`wayland` is done.** `wayland.c` went from 2,884 lines to **359** before
E3 deleted the rest (see the Post-E3 note). What was left is glue rather than
logic: the generated-protocol listener
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
| **D5a** done | `key-binding`: the whole module — manager new/destroy, `key_binding_new_for_seat`/`_new_for_conf` (one `key_set` per (seat, conf), ref-counted), `key_binding_for` with the last-used cache, `key_binding_remove_seat`, `key_binding_unref`, `key_binding_load/unload_keymap`; `initialize_vmod_mappings()` (8 virtual modifiers through a scratch `xkb_state`), `key_codes_for_xkb_sym()` (every key code producing a symbol, for cross-layout matching), `maybe_repair_key_combo()` (the shifted-symbol/composed-modifier repair, logging the offending combo), `key_cmp()`/`sort_binding_list()` (most modifiers first, foot#1280), `mods_to_mask()` (config modifier names → mask, virtual→real), and the four config→runtime converters. `struct vmod_map`/`key_set`/`key_binding_manager` moved from the .c to `key-binding.h`; `terminal_types.zig` gained `VmodMap`/`KeySet`/`KeyBindingManager` mirrors pinned by the probe, and `search.zig` dropped its private `KeyBinding` for `types.KeyBinding`. 9 new harness checks (set build on a real us keymap, repair, sort order, unload, remove) | D4e | 1d |
| **D5b** done | `ime`: the whole module — pending preedit/commit/delete state, `ime_reset_pending`/`ime_reset_preedit`, `done()` applying the six protocol steps (commit to the search input or the slave, then the preedit → cells with the `mblen()`+`c32width()` byte→cell cursor mapping, wide-glyph spacers, and the outside-cursor underline), `ime_enable`/`ime_disable`/`ime_update_cursor_rect` (pending-vs-sent rect dedupe, beam-vs-block width, grid-row rebasing) and the six listeners. Five `terminal_shim_text_input_*` forwarders for the generated inlines; the listener table moved to `wayland.c`; `ime.h` declares the callbacks outside the feature guard, and the `#else` stubs are gone (meson refuses `-Dime=false`). 15 new harness checks | D5a | 0.5d |
| **D5c** done | `url-mode`: the whole module — the url-mode binding dispatcher, activation (uri_parse, the local file: prefix strip, clipboard or launcher), the spawn-launcher + XDG activation-token callback, `urls_input()`'s three matchers and jump-label editing, `regex_detected()` (per-logical-line utf8 flattening with a byte→cell map, combining expansion, `c32rtomb()`), `osc8_uris()`, overlap removal, `generate_key_combos()`/`urls_assign_key_combos()` with duplicate reuse, `tag_cells_for_url()`, `urls_render()` and `urls_reset()`. `regexec()` stays in C (`url_shim_regex_match()`; `regex_t`/`regmatch_t` are libc-specific), `toc32lower()` added to `char32.zig`. 8 new harness checks | D5b | 1.5d |
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
| Branch | +167 commits | **+196 commits** vs `origin/master` | +29 |
| Foot-owned module C | 12,960 | **7,968** of 48,924 | −4,992 |
| C eliminated | 73.5% | **83.8%** (40,956 lines) | +10.3pt |
| `*-shim.c` accessors | 2,545 | **2,910** (11 files; `render.c` itself is gone) | +365 |
| Zig source | ~37.8k | **46,299** lines / 42 files | +8.7k |
| Harness assertions | 603 | **741** call sites (675 `check`, 66 `check_text`) + 30 Zig `test` blocks | +138 |
| `meson test` | 5/5 × 3 dirs | **5/5 × 3 dirs** (`build`, `build-disabled`, `build-release`) | ✅ |
| Real window launches | not verified | **6/6 pass** against the live `wayland-1` socket | ✅ |

Per-module burn-down (share of that module's original C that is gone):

| Module | C left / original | % | Note |
|---|---|---|---|
| 35 modules | 0 / — | **100%** | `async`…`box-drawing`, `search`, `terminal`, `log`, `grid`, `csi`, `sixel`, `osc`, `vt`, `input`, `key-binding`, `ime`, `url-mode`… |
| `config` | 35 / 4,374 | 99% | only `config_regex_compile()` (§6.3) |
| `wayland` | 0 / 2,884 | **100%** | `wayland.c` deleted in E3; generated listener tables + `add_listener()` forwarders live in `wayland-shim.c` (249 lines), FDM callbacks are in `wayland.zig` |
| `selection` | 844 / 2,967 | 72% | data-device / primary-selection listeners, DND |
| `slave` | 106 / 573 | **81%** | signal reset, terminfo path and execvpe left |
| `shm` | 0 / 1,110 | **100%** | `shm.c` deleted in E2; generated protocol inlines + `#ifdef` platform tests live in `shm-shim.c`; `shm.zig` is 1,028 lines |
| `debug` | 22 / 47 | 53% | ASAN stack-trace hook |
| `render` | 0 / 5,479 | **100%** | `render.c` deleted in D3l4; `render.zig` is the module |
| `input` | 0 / 3,687 | **100%** | `input.c` deleted in D4e; listener tables now live in `terminal-shim.c` |
| `url-mode` | 0 / 833 | **100%** | `url-mode.c` deleted in D5c; `url-mode.zig` is the module |
| `main` | 770 / 770 | 0% | |
| `server` | 0 / 707 | **100%** | `server.c` deleted; `server_obj` compiles `server.zig`; private structs + client protocol pinned by the ABI probe |
| `client` | 679 / 679 | 0% | |
| `key-binding` | 0 / 661 | **100%** | `key-binding.c` deleted in D5a; `key-binding.zig` is the module |
| `ime` | 0 / 540 | **100%** | `ime.c` deleted in D5b; `ime.zig` is the module |

**Percent complete: 92.2% by C volume (post-D5c), ~86% by effort (band
83–88%), 36/45 top-level modules (51 counting `spawn_template`) with zero C
left.**
**Post-D4d2a:** `input.c` is 3,618 → **2,040** (45% ported), module C 12,709 →
**7,968**, harness 684 → **744** checks; every keyboard entry point is Zig,
and so is mouse scrolling. `keymap.h` is down to 27 lines (types
only — its 78 key tables are Zig data now), and `kitty-keymap.h`'s table is
Zig too. `render.c` is **deleted** — 3,154 lines of C replaced by
`render.zig` (5,933 lines) plus 1,765 lines of C-only shim (statistics,
`struct timeval`, protocol listener tables). `render` is the 32nd module with
no C left; module C 12,709 → **9,555** (80.5% of the original C gone),
harness 605 → **684** checks, and `full-check.sh` now actually launches
the six windows
(§14.5.1). `smoke.sh` runs a sixth launch with `render-timer=osd` +
`scrollback-indicator=percentage`, which exercises the new OSD painter on a real
compositor. Real presentation feedback is still not delivered to these
short-lived windows, so `presented()` is covered by the fabricated-context
checks, not by the launches.

**Post-D5c:** `url-mode.c` is **deleted** — the 36th module with no C.
Module C **4,674 → 3,841** (92.2% of the original C gone), Zig 49,358 →
**50,364** lines, harness 814 → **822** checks, shim 2,999 → **3,020**. URL
mode is Zig: the url-mode binding dispatch, the four-step activation path
(uri_parse → the local file: prefix strip → clipboard or spawn), the
spawn-launcher and XDG-activation-token callback, `urls_input()`'s three
matchers plus jump-label entry/backspace, `regex_detected()` (utf8
flattening of each logical line with a byte→cell map, combining-character
expansion, `c32rtomb()`), `osc8_uris()`, overlap resolution,
`generate_key_combos()`/label assignment with duplicate reuse, cell tagging
on the snapshot grid, `urls_render()` and `urls_reset()`. Only `regexec()`
stayed in C (`url_shim_regex_match()`, since `regex_t`'s `re_nsub` and
`regmatch_t` are libc-specific); `toc32lower()` was added to `char32.zig`.
8 new harness checks: detection over a real POSIX regex (two rows), the
match range/action, the first label letter, duplicate-URL reuse, and reset.

**Post-E1a:** the `slave` platform glue shrank from 158 to **106** lines
(slave now 81% ported). `slave_shim_constants()` and
`slave_shim_set_iutf8()` are Zig: the open/fcntl/confstr/ioctl constants
are Zig constants with the Linux values (checked against the C macros by the
harness), and IUTF8 is set through libc's `tcgetattr()`/`tcsetattr()` on
Zig's `std.posix.termios` — deliberately not `std.posix.tcgetattr()`, which
maps EBADF/ENOTTY to `unreachable` where the C contract is return-1. What
remains in `slave.c` is only the signal-mask restore, the compile-time
terminfo path and `execvpe()`. 9 new harness checks; the full harness also
runs clean under **valgrind** (0 errors; gdb and valgrind are both present in
this container). Module C 4,726 → 4,674, harness 805 → **814** checks.

**Post-E2 (shm):** `shm.c` is **deleted** — the module is 100% Zig apart
from the C-only boundary. The file-static pool/alignment/punch-hole state is
in `shm.zig`, the compositor capability flags are read from the mirrored
`struct wayland` (including the packed SHM-format bit-field byte), and the
pixman/wl_shm_format table is the ABI-pinned `struct shm_format_constants`
(added to `terminal_types.zig` and to `gen_abi_probe.py`'s `C_TYPES`).
`shm-shim.c` (208 lines) keeps only generated wl_shm/wl_buffer request
inlines, the headless sentinels they have to recognise, the
`memfd_create`/SHM_ANON/mkostemp, fallocate, mmap and sealing `#ifdef`s, and
`_SC_PAGE_SIZE`. The wl_buffer `release` listener callback itself is Zig.
32 new harness checks (format table, 8/10/16-bit thresholds, stride
alignment, zero-sized `shm_get_many` entries, cache age tie-break, release
callback and sentinel forwarders; +32 `check()` call sites). Verified
with `ninja`, `meson test`, six smoke launches and valgrind (0 errors).

**Post-E3 (wayland):** `wayland.c` is **deleted** (370 → 0 C lines) — the
module is 100% Zig apart from the generated-protocol boundary. The 16
listener tables and their `add_listener()` forwarders moved to
`wayland-shim.c` (249 lines), with prototypes for all 27 forwarders added
to `wayland.h`; every callback in those tables is a Zig export. The three
FDM callbacks (`fdm_repeat`, `fdm_hook`, `fdm_wayl`) and the four
forwarders that register them are now Zig, calling `fdm_add`/`fdm_hook_add`/
`fdm_hook_del` directly with the mirrored `struct seat`/`struct wayland`.
No new ABI mirror was needed (`Seat.kbd.repeat` was already pinned).
13 new harness checks drive the FDM registration, the EAGAIN/EPOLLHUP paths
and the no-event path headlessly; the six smoke launches exercise the real
listener tables. Verified with `ninja`, `meson test`, smoke and valgrind.

**Post-D6 (server):** `server.c` is **deleted** (707 → 0 C lines). The
socket lifecycle (socket activation, bind/listen, accept4), FDM callbacks,
client setup-packet parser, terminal-instance bookkeeping and the two global
theme switches are all Zig in `server.zig` (881 lines); `server_obj` replaces
the C source. `struct server`/`struct client`/`struct terminal_instance`
moved to `server.h` and, together with the packed client-protocol structs and
`sockaddr_un`, are mirrored in `terminal_types.zig` and pinned through new
`gen_abi_probe.py` `C_TYPES` entries. No new C shim was needed: every call
is a libc function or an existing Zig export. 21 new harness checks cover the
theme switches, `prepare_socket`/`try_connect`, socket creation and teardown,
and the client's EPOLLHUP/oversized/no-monitor shutdown paths. Also gave the
pre-existing app-id rate-limit harness case a fallback `conf.app_id`, so it
no longer panics when the timer expires under valgrind, and relaxed its
flaky "timer armed" assertion to a timerfd-validity check.

**Post-D5b:** `ime.c` is **deleted** — the 35th module with no C.
Module C **5,266 → 4,726** (90.3% of the original C gone), Zig 48,738 →
**49,296** lines, harness 790 → **805** checks, shim 2,974 → **2,999**. The
text-input-v3 side of IME is Zig: the pending preedit/commit/delete state,
`done()` evaluating the protocol's six steps in order (commit into the search
input or the pty, then the preedit turned into cells), the byte→cell cursor
mapping through `mblen()` + `c32width()` (including the wide-glyph spacer
cells and the underline of everything outside the cursor), the preedit-cursor
hide/after-string/short-string cases, `ime_enable`/`ime_disable`/
`ime_update_cursor_rect` with the pending-vs-sent rect dedupe and the
beam-vs-block width, and the six listener callbacks. Five new
`terminal_shim_text_input_*` forwarders cover the generated request inlines;
the listener table moved to `wayland.c` next to
`wayland_shim_add_text_input_listener()`, and `ime.h` now declares the
callbacks outside the feature guard so the harness can drive them. The
`#else` stub block is not reproduced (meson refuses `-Dime=false`). 15 new
harness checks: the pending string reset, the no-manager no-ops, `done()`
producing cells (ASCII and wide), the cursor offset mapping, underline,
reset, and the cursor-rect math for beam and block.

**Post-D5a:** `key-binding.c` is **deleted** — the 24th module port and
the 34th with no C. Module C **5,927 → 5,266** (89.2% of the original C
gone), Zig 48,057 → **48,738** lines, harness 781 → **790** checks. The
manager, the per-(seat, conf) `key_set` lifecycle (build/ref-count/remove,
the last-used cache), the config→runtime conversion of keyboard, search, URL
and mouse bindings, `mods_to_mask()` with the virtual-modifier mapping,
`maybe_repair_key_combo()` (shifted-symbol → level-0 repair) and the
most-modifiers-first `key_cmp` sort are Zig. `struct vmod_map`,
`struct key_set` and `struct key_binding_manager` moved from the .c into
`key-binding.h` so the probe can pin the three new mirrors (`VmodMap`,
`KeySet`, `KeyBindingManager`) in `terminal_types.zig`; `search.zig` dropped
its private `KeyBinding` copy and now shares `types.KeyBinding` (only the
`u`→`_u` union rename was needed). 9 new harness checks: set construction
against a real `us` keymap, the shifted-symbol repair, the sort order, the
empty sibling lists, unload, and remove.

**Post-D4e:** `input.c` is **deleted** — the module is Zig only.
Module C **6,607 → 5,927** (87.9% of the original C gone), Zig 47,861 →
**48,057** lines, harness 767 → **781** checks, shim 2,939 → **2,974**. The
five touch callbacks are Zig: `touch_to_scroll()` (cell-granular vertical and
horizontal scroll from the touch delta), down (idle gate, long-press
deadline, surface kind), up and motion (a held touch becomes a button
press/release or a drag via synthesized `wl_pointer_*` calls, with the
scroll-vs-long-press split and C's three-way fallthrough written out
explicitly), frame (empty) and cancel. The three protocol listener tables
(`keyboard`/`pointer`/`touch`) moved from `input.c` into
`terminal-shim.c`, which already included `input.h` and owns
`wayland_shim_add_*_listener()`. The 390-line keyboard-layout `UNITTEST`
block (real `se`, `us+de(neo)` and `us(intl)` keymaps through the kitty
encoder, read back from a pty) moved verbatim into `tests/test-terminal.c`
as `test_keyboard_layouts()`, with its nine comparisons turned into named
checks; the two small `keymap_lookup()` blocks were already covered by
`test_keymap_lookup()` and were dropped. 6 new harness checks for the touch
state machine.

**Post-D4d2b:** `input.c` is 1,564 → **680** (82% ported), module C
**7,491 → 6,607** (86.5% of the original C gone), Zig 46,884 → **47,861**
lines, harness 756 → **767** checks, shim 2,922 → **2,939**. The twelve
`wl_pointer_*` callbacks are Zig: enter/leave (the touch-state gate, the
cursor-callback teardown, the full mouse-state reset and the per-surface
finalize/CSD-refresh), motion (CSD button hover/flush, the move-timer
hand-off, and the grid path with mouse reporting, selection auto-scroll and
the binding-driven cell bookkeeping), button (double/triple click timing, the
GNOME multi-press workaround, the CSD title/border/button branches and the
grid press/release path with `execute_binding()`), and the axis family
(low-res aggregation, discrete, value120 with its per-line remainder, frame
and stop). The listener table itself stays in C, as `keyboard_listener`
does, with the prototypes in `input.h`. `wl_fixed_t` is converted with local
24.8 helpers and `fabs()` became `@abs`; `xdg_toplevel_move/resize/
show_window_menu` needed three more shims. Deliberate guard: a motion or
button event with no mouse focus returns instead of dereferencing NULL (C's
debug `xassert` / release crash). What is left in `input.c` is the
touch listener and the seat glue (D4e), 680 lines.

**Post-D4c:** `input.c` is 2,040 → **1,564** (58% ported), module C
**7,968 → 7,491** (84.7% of the original C gone), Zig 46,299 → **46,884**
lines, harness 744 → **756** checks, shim 2,910 → **2,922** (four new
xdg-shell forwarders). `execute_binding()` — the 470-line action switch behind
every key and mouse binding — is Zig, so `input.c` is now only the pointer and
touch listeners plus the seat glue (D4d2b/D4e). The four xdg_toplevel requests
that were static inlines (`set_minimized`, `unset_maximized`,
`unset_fullscreen`, and `set_fullscreen`'s sibling pair) got shims; the
`PIPE_*` group keeps C's fallthrough as an explicit alt-grid early-out, and
C's `pipe_err` label became a labelled block. One deliberate difference: C
closed `pipe_fd[0]` twice (the fd stayed >= 0 after the first close, so the
error path could close a recycled descriptor); the port sets it to -1.

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
| **D3k1** done | `render`: the presentation-feedback trio — `sync_output` (empty), `presented` (the input→commit→presented breakdown, the monitor-frame bucket and the err/warn/info log, then the feedback teardown) and `discarded` — plus `render_init()`/`render_destroy()`: the two-pointer renderer object (C keeps a `_Static_assert` on the same size, since the still-C hook reads `renderer->wayl`) and the `fdm_hook_refresh_pending_terminals` registration (that hook lost its `static` until D3l4). `struct timeval` is platform-dependent, so the C-allocated presentation context is read through three accessors that die with `grid_render()`; the exit-time statistics and their `DESTRUCTOR` stay in C because the attribute is not portably expressible in Zig. 12 new harness checks: init/destroy against a real `fdm`, the frame arithmetic at 60/120 Hz and refresh=0, and `presented()` end-to-end for all four timing branches | D3j | 1d |
| **D3k2a** done | `render`: `force_full_repaint()` (drain the scroll-damage list, repaint the margins, `term_damage_view()`) and `reapply_old_damage()` — the two-frames-old `memcpy` shortcut, the row scan that builds this frame's dirty region, the "every cell dirty" bail-out, the scroll-damage-dependent subtract-vs-copy clip choice, and the `PIXMAN_OP_SRC` composite of the old frame. C leaks the region it just built on the full-repaint branch; the Zig version `fini`s it before taking the same path. 4 new harness checks (memcpy path, composite path, scroll-damage drain, re-dirtying) | D3k1 | 0.5d |
| **D3k2b** done | `render`: `render_scrollback_position()` — the indicator create/destroy lifecycle (`wayl_win_subsurface_new()` on demand, destroy when the viewport returns to the bottom), the scrollback-start scan, the rebased-view percentage, the three formats (percentage text via `snprintf`+`mbstoc32`, line number with `ceilf(log10f(num_rows))` cells, configured text), the fractional-scale snapping of width/height/x/y, the fixed/relative vertical placement (search-box aware) and the off-screen unmap. `render_render_timer()` — the µs string, the same snapping, the sub-surface position and the OSD paint. 5 shared helpers (`snapToScale`, `roundfDiv`, `osdMargin`) keep the float semantics explicit. 2 new harness checks for the early-outs; `smoke.sh` now runs a sixth launch with `render-timer=osd` + `scrollback-indicator=percentage` so the painting paths execute against a real compositor | D3k2a | 1d |
| **D3k3** done | `render`: **`render_search_box()`** — the IME pre-edit merge into the search string (`c32ncpy`/`c32cat`/`c32ncat`, now exported from `char32.zig` since they were `static inline` wcs* wrappers), the per-character cell widths and `c32swidth()` total, the 20-cell minimum window, the fractional-scale snapped geometry, the match/mismatch background (custom colours or `table[3]`/`table[1]`), the transparent strip left of the visible part, the cursor-visibility offset adjustment (including the three IME shift predictions) and the character-boundary snap, the glyph loop with colour-emoji vs mask compositing and the zero-width combining offset, both IME cursor shapes (bar and hollow, with their underlines and pending rects), the plain cursor, the sub-surface position/scale/attach/damage, and the *partial* opaque region (a new `wayland_shim_set_opaque_region_rect()`). The VLA for `widths[]` becomes a heap array; `searchBoxGlyphOffset()` is factored out so the windowing arithmetic is testable without a compositor. 5 new harness checks for that arithmetic; the paint path has no headless coverage (the search box needs a real sub-surface) | D3k2b | 1.5d |
| **D3k4** done | `render`: **`render_urls()`** — the scrollback-relative view range, the three hide rules (out of view, key shorter than what was typed, prefix mismatch → unmap), the label position clamped to the window margins, the URL decoded via `mbsntoc32(NULL, …)`, the label assembly (upper-cased key, `": "`, URL, entered keys blanked, ellipsis truncation that never splits a wide glyph), `shm_get_many()` for one shared pool across every label, and the per-label `render_osd()` paint. `char32.zig` gains `c32cpy`, `c32ncasecmp` and `toc32upper` (the last through libc's locale-dependent `towupper`). The VLAs become heap arrays, and the label buffer is stored directly instead of `xc32dup()`'d — C only copied because its label lived on the stack. `buildUrlLabel()` is factored out behind a C-facing `render_url_format_label()`: 7 new harness checks (composition, blanking, width, ellipsis truncation, NUL, zero width). The sub-surface paint itself has no headless coverage | D3k3 | 1d |
| **D3l1** done | `render`: **`render_worker_thread()`** — the worker loop: `sigfillset`/`pthread_sigmask` so the threads never take foot's signals, the `foot:render:%d` name, `sem_wait(start)`, the cursor row translated from the offset-relative grid to the view, the queue pop under the shared mutex, then the four codes: `-1` frame-done (`sem_post(done)`), `-2` quit, `-3` the pre-applied-damage composite (age 0 = leave alone, 1 = copy the previous frame's `dirty[0]`, ≥2 = whole buffer; `PIXMAN_OP_SRC` composite, `shm_unref`/`shm_addref` handover, `last_buf` swap, then `pre.buf = NULL` + `cnd_signal` under the pre-apply lock) and the default row case (`terminal_shim_grid_row_in_view`, cursor column, `render_row`). **`render_wait_for_preapply_damage()`** — the two early-outs and the `cnd_wait` loop. `workers.buf` stays *optional*: C reads it unconditionally but the `-1`/`-2` paths never dereference it, and the first wake-up (`term_destroy()`'s quit) really does see NULL — an eager `.?` there panicked in the harness until it was made `?*Buffer`. Two new C11 shims (`render_shim_block_all_signals`, `render_shim_set_thread_name`); `pthread_create`/`pthread_join` rather than `thrd_*`, per the C5 trap. 7 new harness checks: a real pthread driven through `-1` (posts `done`, drains the queue) and `-2` (returns 0), plus the pre-apply waiter's two early-outs and its block/wake-up handshake | D3k4 | 1d |
| **D3l2** done | `render`: **`grid_render()`** — the frame: the shutdown early-out, the pre-apply wait bracketed for the render timer, `shm_get_buffer()` for the grid chain, dirtying the old and new cursor cells, the three buffer-age cases (`force_full_repaint()` on a resize/margins change, `reapply_old_damage()` plus the "compositor never releases immediately" counter that flips `preapply_last_frame_damage` on after 10 frames, or the counter reset), the `last_buf` hand-over, the scroll-damage drain (a plain `DAMAGE_SCROLL` is dropped when the view is inside the scrollback, the `_IN_VIEW` variants always apply), `selection_dirty_cells()` so printed-to cells regain their `selected` bit, the view-relative cursor, the overflowing-glyph pre-pass (factored into `dirtyOverflowingGlyphs()` so it is testable — 8 new harness checks for the back-fill/forward-sweep/confined-stop/resume semantics), the sixel pass, the worker hand-off (`workers.buf`, one `sem_post` per worker, the queue, the `-1` fan-out and the `done` join), the damage union across `dirty[1..n]` into `dirty[0]` and the per-box `wl_surface_damage_buffer()`, the overlay/IME/scrollback-indicator sub-surfaces, the render-timer logging (µs breakdown, `timespec_add`/`_sub`), the frame callback, `wayl_win_scale()`, the presentation-feedback allocation, `damage_whole_window` and the attach+commit. Only the protocol glue stayed in C: `render_shim_add_frame_callback()` (the `wl_callback` listener table), `render_shim_presentation_{commit_time,feedback_new,feedback_add}()` and `render_shim_presentation_ctx_new()` (which owns `struct timeval`). The `_DEBUG` row/cell consistency assertions are not ported (they need the `BUG()` macro) | D3l1 | 2d |
| **D3l3a** done | `render`: the size-notification half of the resize path — `tiocswinsz()` (TIOCSWINSZ on the pty master through a `struct winsize` shim, then `term_send_size_notification()`), `delayed_reflow_of_normal_grid()` (reflow the grid stashed when the interactive resize started to the *current* size, swap it back in, restore the selection coords and `hide_cursor`, reset the interactive-resize state, drop the render pointers and the scroll damage, reflow the sixels, damage+refresh when the normal grid is active, resume the pty), `fdm_tiocswinsz()` (the timer callback: apply the size, reflow, disarm), `send_dimensions_to_client()` (immediate vs. the lazy `timerfd_create()`/`fdm_add()` debounce branch, falling back to immediate when the timer cannot be armed) and `set_size_from_grid()` (grid × cell size + padding × scale, rounded to multiples of the scale). `render_resize()` is still C, so those four keep C prototypes in `render.h` for one more chunk. 4 new harness checks for the size arithmetic (padding, scale multiples, zero grid, NULL out-param) | D3l2 | 1d |
| **D3l3b** done | `render`: **`render_resize()`** — the configure path: the three early-outs, floating vs. maximized/fullscreen/tiled, logical→physical scaling, `RESIZE_KEEP_GRID`, the compositor-lets-us-choose cases (stashed size, then `size=px` minus CSD decorations or `size=cells` through `set_size_from_grid()`), the one-cell minimum, padding clamped to half the slack, `RESIZE_BY_CELLS` snapping, the unchanged-size early-out, app-sync-disable + URL-mode exit, the power-of-two scrollback sizing (`32 - @clz()`), margins/centering with the four invariants, the interactive-resize stash plus the fake truncated-view grid (rows copied cell-by-cell, underline ranges deep-copied, sixels/URLs dropped, `hide_cursor` forced), selection cancel-vs-finalize, mouse revalidation, the truncating vs. reflowing grid resize, the alt grid, tab stops, `sixel_reflow()`, scroll-region clamping, TIOCSWINSZ, the floating-window size stash, the CSD-aware xdg geometry/min-size and the damage/refresh fan-out. Also fixed a latent bug: `grid_resize_and_reflow()`'s Zig export took a `*Composed` while every caller passed a `*Terminal` (the C forwarder that used to bridge them is not in `meson.build` any more), so reflow of grapheme clusters read the wrong memory. 4 new harness checks | D3l3a | 2d |
| **D3l4** done | `render`: the last of `render.c`, which is now **deleted**. `frame_callback()` (deferred pending-flags render, CSD/search/URL passes, the `delayed_render_timer` guard, IME cursor-rect sync), `render_update_title()` (2 KiB truncation), the cursor trio — `render_xcursor_is_valid()`, `render_xcursor_update()` (client-side NULL-surface hide, the cursor-shape-v1 branch with custom-shape name lookup, the client-side surface path with `wl_cursor` metrics and `wayl_surface_scale_explicit_width_height()`), `render_xcursor_set()` (theme/shape-device/focus gates, the fallback chain, the custom-xcursor strdup) — `xcursor_callback()`, `fdm_hook_refresh_pending_terminals()` (refresh flags, app-sync suppression, URL grid snapshot swap, `quirk_weston_csd_on/off`, pending-flags deferral, seat cursor flush) and `render_buffer_release_callback()` (the pre-applied-damage hand-off: age/size gates, pre-apply lock, `.start/.stop` reset, the `-3` queue push). What stayed in C moved to `terminal-shim.c` and is only C-only knowledge: the exit-time presentation statistics + `DESTRUCTOR`, `struct presentation_context` with its two `struct timeval`s, and the three protocol listener tables plus the generated inlines they wrap. 9 new harness checks | D3l3b | 1.5d |

Exit criterion: `render.c` deleted, `render.zig` ~3.5k lines, harness ≥ 700
checks, 5/5 window launches **with** `WAYLAND_DISPLAY` set, and a pixel-parity
dump (§14.5.2) for the cell/URL/CSD paths.

**Track D4 — `input` (≈6–8 dev-days).** Split by protocol, mechanical tables first:

| Chunk | Work | Est. |
|---|---|---|
| **D4a** done | `input`: `input.zig` created with the keyboard *setup* half — `fdm_write_pipe()` (the EPOLLOUT chunked write of a binding's feedback to the client), `keyboard_keymap()` (old xkb state teardown, the memfd `mmap()` + `xkb_keymap_new_from_buffer()`, the cached modifier indices, the legacy-vs-kitty significant-modifier masks, and the `virtual_modifiers` mask that papers over Mutter setting Alt/Meta/Super/... on top of the real modifiers), `keyboard_enter()` (NULL-surface guard, `term_kbd_focus_in()`), `keyboard_leave()` (repeat timer, modifier reset, compose-state reset, layout-index reset, `term_xcursor_update_for_seat()` + `term_kbd_focus_out()`, and the Sway-bug warning) and the repeat timer pair `start_repeater()`/`stop_repeater()` (rate/delay arithmetic with the ≥1 s normalisation, `dont_re_repeat`). libxkbcommon and libc are declared as plain Zig externs (all opaque pointers), so no new shim file was needed. 8 new harness checks for the repeat-timer short-circuits and the enter/leave bookkeeping; the keymap installation itself is exercised by the six smoke launches | D3l4 | 1d |
| **D4b1** done | `input`: `get_current_modifiers()` (effective/consumed masks off the xkb state, with the locked-modifier filter), `keysym_is_modifier()` (Shift_L..Hyper_R, the ISO group/lock range, Mode_switch, Num_Lock), `modifier_string()` ("Shift+Control" from the keymap's modifier names, or `<none>`; C's bare `strcat()` became explicit length tracking, and a NULL keymap now renders `<none>` instead of dereferencing it) and the `keyboard_repeat_info()` listener. 9 new harness checks, including a real `xkb_keymap_new_from_names()` so the modifier-name path is exercised, not just the fallbacks | D4a | 0.5d |
| **D4b2a** done | `input`: **`keymap.h`'s 78 key tables translated to Zig** (925 entries) by a generator that runs the header through the C preprocessor first, so the `DEFAULT_MODS_FOR_KP/​SINGLE/TILDE()` macro tables and their string-literal splicing arrive expanded — the generator then only has to turn C's octal escapes into Zig `\xNN`, map `MOD_*`/`CURSOR_KEYS_*`/`KEYPAD_*` to numbers, and emit `KeyData` (an `extern struct` with the same field-for-field layout as C's `struct key_data`) plus `keymap_data_for_sym()` and **`keymap_lookup()`** with the modifyOtherKeys-state filtering and the cursor-keys/keypad mode matching. `keymap.h` keeps only `enum modifier` and `struct key_data` (27 lines). 8 new harness checks that double as a translation parity test — they use the sequences keymap.h's own `UNITTEST` blocks asserted (Shift+Escape, Alt+Return with and without modifyOtherKeys=2, Shift+Ctrl+ISO_Left_Tab) plus the cursor-key-mode pair (CSI A vs SS3 A) and the table lookup itself | D4b1 | 1.5d |
| **D4b2b** done | `input`: **`legacy_kbd_protocol()`** (the MOD_ANY key-table lookup, modifyOtherKeys=2's XTerm emulation including the "is the base symbol a-z?" check, the sparse CSI-27 modifier parameter table as a `modParam()` switch, and the three Alt strategies: ESC prefix / 8th bit via `c32rtomb()` / ignore) and **`kitty_kbd_protocol()`** (all five flag bits, the "delegate to legacy" rule, the modifier-key self-inclusion trick via `xkb_state_update_key()`, the locked-vs-consumed text rule, the `is_text` scan with `isc32print()`, the plain-text/control-character fast paths, the `encoded_mods` bit packing, the shifted/unshifted/base key resolution with `xkb_keysym_to_utf32()` + `xkb_keymap_key_get_syms_by_level()`, the level-0 symbol rule for unencodable modifiers, the `:event` sub-parameter, and the CSI-u/CSI-~ formatter with alternate and associated-text sub-parameters). `kitty-keymap.h`'s 110-entry sorted table is Zig too (binary search instead of `bsearch()`), and `struct kbd_ctx` moved to `input.h` so C and Zig share it. 12 new harness checks read the encoders' output back out of a real pty: legacy plain text, Ctrl+a (control byte), Ctrl+é (CSI 27;5;233~), Alt+Return from the key table, releases; kitty plain text, report-all (`CSI 97u`), Ctrl (`CSI 97;5u`), and releases both with and without the report-events flag. **Note:** one of my own first expectations was wrong — Ctrl+a really does send 0x01, because `is_control_key()` covers keysym 0x40..0x7f and xkb already resolved the control character. The C behaviour was kept | D4b2a | 2.5d |
| **D4b** | `key_press_release` (262) + `legacy_kbd_protocol` (158) + `kitty_kbd_protocol` (327) — port the C `UNITTEST` blocks into the harness as you go | 2–3d |
| **D4b4-mirror** done | `terminal_types.zig`: **`KeyBinding`** (`type`, `action`, `mods`, the anonymous union as `_u` — `k.sym`/`k.key_codes` and `m.button`/`m.count` — and `aux`) and **`KeyBindingSet`** (the four tll headers plus `selection_overrides`) are mirrored and pinned by `expectAbi()`, with `scripts/gen_abi_probe.py`'s `C_TYPES` table extended so the probe emits `KeyBinding__size`, `KeyBinding_aux`, `KeyBinding_k_sym`, `KeyBindingSet_selection_overrides`, ... The union cannot be probed by name (C's is anonymous; the Zig field is `_u` so `expectAbi()` skips it) — its size is still pinned through `aux`'s offset and the struct size. `terminal.zig` and `search.zig` now share `types.KeyBindingSet` instead of carrying two private 104-byte copies with hand-written asserts; `search.zig` casts the fields to its local `tll.Tll(KeyBinding)` before iterating. This is the groundwork `execute_binding()`, `key_press_release()` and the whole of `key-binding.c` need | D4b3 | 0.5d |
| **D4b4** done | `input`: **`key_press_release()`** — the dispatcher. Repeat-timer handling on release, `last_shortcut_sym` reset on press, `xkb_keymap_key_repeats()`, `xkb_state_key_get_one_sym()`, the hide-when-typing pointer hide, compose feed/status, `get_current_modifiers()`, the layout + level-0 syms, `key_binding_for()`, the unicode-mode / search / URL early-outs, the **three binding matchers** (untranslated syms, translated sym with `mods & ~consumed`, raw keycodes) walking `types.KeyBindingSet`'s tlls, the release-after-shortcut suppression, the compose/utf8/utf32 buffer dance (`ambstoc32()` for composed text, stack buffer with a heap fallback), the `kbd_ctx` hand-off to the kitty-or-legacy encoder, the composed-release reset, and the `term_reset_view()` + `selection_cancel()` epilogue. C's three `goto maybe_repeat` paths became a labelled Zig block. `execute_binding()` lost its `static` (it is the next chunk) | D4b4-mirror | 2d |
| **D4b5** done | `input`: the three wrappers that were waiting on it — `keyboard_key()` (the `+8` evdev→xkb keycode shift), `input_repeat()` (the repeat timer's re-press) and `alternate_scroll()` (BTN_BACK/FORWARD → Up/Down presses, then the release). With these, **every keyboard entry point in `input.c` is Zig**; what is left there is the pointer/touch listeners and `execute_binding` | D4b4 | 0.5d |
| **D4c-groundwork** done | `input.zig`: the **binding-action constants** `execute_binding()` switches on, emitted by asking the C compiler rather than transcribing (`scripts/gen_bind_enums.sh`: 91 constants covering every `BIND_ACTION_*` and `BINDING_AUX_*`, plus `URL_ACTION_*` and `SELECTION_*` transcribed in declaration order). `types.BindingAux` (with `pipe`/`text`/`regex_name`) and `types.KeyBinding` already exist, so this is the last missing input for the switch | D4d2a | 0.25d |
| **D4c** done | `input`: **`execute_binding()`** — the whole action switch: scrollback up/down (page/half/line/mouse, with the alt-grid + `alt_scrolling` hand-off to `alternate_scroll()` and the `max(rows/2, 1)` half-page clamp), home/end, the three clipboard actions, search, the font-size trio, `term_spawn_new()`, minimize/maximize/fullscreen (via four new `terminal_shim_xdg_toplevel_*` forwarders for the static inlines), the `PIPE_*` quad (C's fallthrough became an explicit alt-grid early-out; the pipe/fcntl/spawn/fdm_add sequence with C's `goto pipe_err` as a labelled block, reusing the existing `PipeContext` and `fdm_write_pipe()`), the three URL collectors, text bindings, prompt-prev/next (the scrollback-relative row walk with `shell_integration.prompt_marker`), unicode input, quit, regex launch/copy (walking `conf.custom_regexes`, the two `LOG_ERR` messages), the theme trio and the eight selection actions. The four xdg-shell shims are C-only knowledge (static protocol inlines). One deliberate difference: C closed `pipe_fd[0]` twice on the error path (the fd was never reset), which could close a recycled descriptor; the Zig version sets it to -1. 12 new harness checks (alt-grid early-outs, the no-aux pipe no-op, the unknown-regex path, block-selection refusal, and a text binding read back out of a real pty) | D4d2a | 1d |
| **D4d1** done | `input`: the pointer helpers the listeners are built on — `mouse_button_state_reset()` (drops the button list and the double/triple-click counters and timer), `mouse_coord_pixel_to_cell()` (pixel → cell with the margins clamping to the first/last cell), `touch_is_active()` (idle/inhibited vs held/dragging/scrolling, plus the `wl_touch == NULL` short-circuit) and `mouse_scroll_multiplier()` (the configured scrollback multiplier on the normal grid, or on the alt grid only when the mouse is grabbed *and* alt-scrolling is on). 13 new harness checks, mostly around the coordinate clamping and the multiplier's four combinations | D4b2b | 0.5d |
| **D4b3** done | `input`: **`keyboard_modifiers()`** — the virtual-modifier masking (Mutter), the `xkb_state_update_mask()` call, and the four cached `shift`/`alt`/`ctrl`/`super` flags via `xkb_state_mod_index_is_active(..., XKB_STATE_MODS_EFFECTIVE)`, then the cursor refresh when the pointer sits on the grid. 4 new harness checks (no modifiers, ctrl+shift, the untouched pair, and a virtual modifier being ignored) against a real keymap. The big `UNITTEST` block that follows it in `input.c` still drives the Zig function through the C `key_press_release()` + the new protocol encoders, and still passes | D4d1 | 0.5d |
| **D4d2a** done | `input`: **`match_mouse_binding()`** — with a keyboard it walks `types.KeyBindingSet.mouse`, masks the selection-override modifiers out of the current mods, and picks the binding with the highest click count that is <= the seat's; without a keyboard it scans `conf.bindings.mouse` ignoring modifiers and synthesizes a static `KeyBinding` from the `ConfigKeyBinding` (the same trick C used). **`mouse_scroll()`** — axis+sign → wheel button, `term_mouse_grabbed()` → one `execute_binding()` with the scroll amount, otherwise `term_mouse_down()` per step plus one `term_mouse_up()`. 6 new harness checks: button/click-count matching, an unbound button, a modified binding being skipped without a keyboard, one wheel-down step and two wheel-up steps read back as SGR reports from a real pty, and silence when mouse tracking is off | D4b5 | 1d |
| **D4d2b** done | `input`: the twelve **pointer listeners** — `wl_pointer_enter` (NULL-surface workaround, `term_surface_kind()`, the scale multiply, cursor-theme reload, per-surface CSD refresh), `wl_pointer_leave` (the touch-state gate as plain-int comparisons, xcursor-callback teardown, the full mouse reset, and `selection_finalize()`/CSD refresh for the old surface), the static `pointer_is_on_button()` inlined as a Zig helper, `wl_pointer_motion` (CSD hover flush, move-timer hand-off, the grid path: cell bookkeeping, `selection_update()`, the distance-proportional auto-scroll timer, and `term_mouse_motion()`), `fdm_csd_move()`, `wl_pointer_button` (click counting off `CLOCK_MONOTONIC` + `timespec_sub()`, the GNOME multi-press tracker workaround, title double-click/move-timer/window-menu, border resize edges, CSD button releases, and the grid press/release path through `match_mouse_binding()`/`execute_binding()`), plus `axis`/`axis_discrete`/`axis_value120`/`frame`/`axis_source`/`axis_stop` with their three accumulators. The listener table stays in C (like `keyboard_listener`), prototypes in `input.h`. `wl_fixed_t` is local 24.8 arithmetic rather than two new shims, `fabs()` is `@abs`, and three more xdg-shell requests got shims (`move`, `resize`, `show_window_menu`). Deliberate guard: motion/button with no mouse focus returns instead of dereferencing NULL. 11 new harness checks (NULL-surface enter, no-focus motion/axis/value120 early-outs, frame and axis-stop bookkeeping, and the full pointer-leave reset incl. button trackers) | D4c | 1.5d |
| **D4e** done | `input`: the five **touch listeners** — `touch_to_scroll()` (the cell-granular delta scroll in both axes), `wl_touch_down` (idle gate, the long-press deadline from `conf.touch.long_press_delay`, surface kind), `wl_touch_up` and `wl_touch_motion` (a held touch becomes a synthesized LMB press and then either a scrolling touch or a drag through `wl_pointer_button`/`wl_pointer_motion`, with C's HELD→DRAGGING→SCROLLING fallthrough written out and the mouse-focus/active-surface temporarily swapped), `wl_touch_frame` and `wl_touch_cancel`. With this **`input.c` is deleted** (the 33rd module with no C): the three listener tables moved to `terminal-shim.c` (which already included `input.h` and owns `wayland_shim_add_*_listener()`), and the 390-line keyboard-layout `UNITTEST` moved to the harness as `test_keyboard_layouts()` (se / us+de(neo) / us(intl) keymaps through the kitty encoder, read back out of a pty; its nine assertions became named checks). The two `keymap_lookup()` blocks were already covered by `test_keymap_lookup()` and were dropped. 6 new harness checks for the touch state machine. No new shim functions — only the tables moved | D4d2b | 0.5d |

**Track D5 — mid-tier (≈5–6 dev-days).** `key-binding` (661) — **done, D5a** —
→ `ime` (540) → `url-mode` (833) — **done, D5c** — → `selection`'s 844-line tail. `key-binding`
removed `search.zig`'s private `KeyBinding` mirror; `terminal.zig` already
shared `types.KeyBindingSet`. The `selection` tail deletes
`selection-shim.c` (243) wholesale.

**Track D6 — entry points (≈4–5 dev-days).** `server` (707) — **done** —
then `main` (770) and `client` (679), which share `main`'s setup. After D6
the process entry point is Zig.

**Track E — endgame (≈3–4 dev-days).** E1a done (slave's constants +IUTF8); E2 done (`shm.c` deleted, 329 → 0 — the
`wl_shm` capabilities are read from the mirrored `struct wayland`, and only
the generated protocol inlines and `#ifdef` platform tests stay in
`shm-shim.c`). What is left is `slave`'s
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
5. **Beware `switch` on a mirrored C enum with a negative member.** In
   ReleaseSafe, `switch (seat.touch.state)` on the Zig mirror of
   `enum touch_state` (which has `TOUCH_STATE_INHIBITED = -1`) mis-compiled:
   an *idle* state (0) was reported as active. Comparing the state as a plain
   `c_int` instead of switching on the enum fixed it, and both build dirs now
   agree. Treat any enum with a negative member as "compare the integer" until
   this is understood; the Debug build hid it.
6. **Never let two `zig`/`ninja`/`meson` invocations share a build dir or the
   Zig cache.** This session lost an hour to a "nondeterministic Zig 0.16 DWARF
   bug" (`DWARF TODO: 'InputOutput' while updating constant`, `bad decl abbrev
   code: pad_1`, `failed to init dwarf: InputOutput`) that reproduced on
   *unmodified* modules of any size and looked compiler-fatal. It was not a
   compiler bug: the tool layer in this container runs every shell command
   **twice, concurrently**, so each `ninja`/`zig build-obj` was racing itself
   through `~/.cache/zig` and reading back half-written manifests. Serialised
   (`flock`, or a single-shot wrapper) the same objects build fine in `Debug`,
   so `-O Debug` stays the dev default — the earlier workaround that mapped
   `debug` to `ReleaseSafe` was reverted. Rule: wrap every mutating command in
   `/tmp/once.sh` (mkdir-lock) and never background two invocations of the same
   command string.

### 14.6 Untracked cruft

`git status` carries `capture/`, `inbox/`, `investigation.cany/`,
`squashfs-root/`, `craft.json`, `feed.json`, `usage.json`, `build-activity.log`.
None belong in the repo; gitignore or delete them before the next commit so
the scoreboard diffs stay readable. (`reference/` is tracked — leave it.)

