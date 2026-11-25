# Audit 2 — Wayland surface, render, input, selection

> **Status (endgame, 2026-11-25, base `98f999c6`).** Body unchanged.
>
> | id | status |
> |---|---|
> | S-01, S-02 | fixed `674e62d2` |
> | S-03, S-08 | fixed `4a5f3382` |
> | V-01 | fixed `c819c0f2` — `render_update_title()` returns when the window
>   or toplevel is NULL; C dereferences. Unreachable with a real window |
> | S-04…S-07 | fixed `b14005a1` — f32 arithmetic at all four sites; C probes
>   recorded in the commit (21/11/3/10 vs the port's 20/10/2/9) |
> | S-09…S-13 | fixed `b4e3ba91` |
> | S-14, S-15 | fixed `39e70a77` |
> | cursor-blink phase | fixed `4d9df1d6` — C has CURSOR_BLINK_ON == 0; the port
>   tested `state != 0`, inverting every cursor painter. Harness adapted in the
>   merge `5c508c64` (tests/test-terminal.c asked for the inverted phase) |
> | parity oracle | `f8db574a` + `c6b5205b` — 447 per-cell hashes across two
>   fractional scales, byte-identical to origin/master; 447/447 covered, no
>   accepted pixel differences |
Base: `18754871` (`git fetch /workspace feature/zig-migration && git reset --hard FETCH_HEAD`, snapshot taken at the start of this audit). References to C are `git show origin/master:<file>.c` (`origin/master` = `6b3f557d`). No product file was edited; this document is the only write.

Verification run on this checkout:

```
ZIG_GLOBAL_CACHE_DIR=/tmp/audit-surface/zig-cache ninja -C build   # ok
meson test -C build --no-rebuild                                   # 5/5 OK
valgrind -q --error-exitcode=99 ./build/tests/test-terminal        # exit 0
valgrind --vgdb=no --error-exitcode=99 ./build/tests/test-terminal # exit 0
```

`/tmp/gate5.log` (last `scripts/full-check.sh` log) shows all three build dirs at `Ok: 5 Fail: 0` and six successful window launches. No launch reported panic/ERROR/assertion. The harness therefore does **not** currently reproduce the reported SIGSEGV; see V-01.

## Findings

`class` uses: `arithmetic`, `cleanup`, `state`, `diagnostic`, `safety`. Severity is impact on behaviour relative to C, not style.

| id | file:line | C ref | class | severity | evidence | fix |
|---|---|---|---|---|---|---|
| S-01 | `wayland.zig:778` | `wayland.c:61` | arithmetic | high | C `roundf(conf->csd.title_height * scale * 1 / 2)`; Zig `round(title_height * scale)` — the `* 1 / 2` is gone | divide by two before rounding; add a harness check for `title_height=26, scale=1` → `pixelsize=13` |
| S-02 | `notify.zig:17-19` | `notify.c:23-27` | cleanup | high | C `if (notif->pid > 0) fdm_del(term->fdm, notif->stdout_fd);`; Zig `_ = term; // TODO(chunk B)` | restore the `fdm_del()` guarded by `pid > 0`; otherwise the stdout fd stays registered after `notif_done()`/`term_reset()` |
| S-03 | `render.zig:4407-4409` | `render.c:4555-4556` | arithmetic | high | C `width = round(width * scale)` with `float scale`; Zig `const scale: f64` and `roundF(float(width) * scale)` | keep `term.scale` as `f32` in the multiply, then widen only for `round()` |
| S-04 | `render.zig:4322-4337` | `render.c:4513-4526` | arithmetic | medium | C `(pad_left + pad_right) * term->scale` is `float`; Zig promotes to `f64` before `intFromFloat` | compute padding in `f32` as C does |
| S-05 | `render.zig:4816-4858` | `render.c:4962-5001` | arithmetic | medium | C `roundf(border / scale)`, `roundf(term->width / scale)` etc. are `f32`; Zig uses `roundF(f64 / f64)` | use the existing `roundfDiv()`/`f32` helpers here too |
| S-06 | `render.zig:3199-3201`, `render.zig:3512` | `render.c:3077`, `render.c:3158` | arithmetic | medium | C `(int)roundf(3. * scale)`; Zig `@round(3.0 * @as(f64, scale))` | call `osdMargin()` (f32) in `render_search_box()` too, and make `osdMargin()` f32 |
| S-07 | `render.zig:5664-5665` | `render.c:5118` | arithmetic | medium | C `image->hotspot_x / scale` is `int / float`; Zig divides two `f64`s before `intFromFloat` | divide in `f32`, then cast to `i32` |
| S-08 | `input.zig:3197` | `input.c:1857` | safety | low | C `key + 8` on `uint32_t` wraps; Zig traps in ReleaseSafe for `key > UINT32_MAX-8` | use `key +% 8` (or reject out-of-range keycodes explicitly) |
| S-09 | `selection.zig:2882-2889` | `selection.c:2846-2849` | diagnostic | low | C logs `LOG_WARN("compositor called data_device::drop() even though we rejected the drag-and-drop")`; Zig returns silently | restore the warning |
| S-10 | `selection.zig:2045-2061` | `selection.c:2094` | diagnostic | low | C logs the clipboard timeout at `LOG_WARN`; Zig only returns | restore the warning |
| S-11 | `selection.zig:2072-2076` | `selection.c:2122` | diagnostic | low | C logs `LOG_ERR("drag-and-drop: invalid URI: ...")`; Zig returns `false` silently | restore the error log |
| S-12 | `selection.zig:1517`, `selection.zig:1545` | `selection.c:2007`, `selection.c:2496` | diagnostic | low | C logs `LOG_ERR("failed to create clipboard data source")`; Zig returns `false` silently | restore the error log |
| S-13 | `notify.zig:377-384`, `notify.zig:328-346` | `notify.c:258`, `notify.c:662`, `notify.c:696` | diagnostic | low | C warns when the terminal is gone / a notification is unknown or has no helper; Zig has no warning | restore the warnings (they are not `LOG_DBG`) |
| S-14 | `notify.zig:465` | `notify.c:456-457` | safety | low | C `xassert(title != NULL); if (title == NULL) return false;`; Zig substitutes `""` and sends the notification | either document as a deliberate safe divergence or keep C's rejection |
| S-15 | `selection.zig:2814` | `selection.c:2771` | state | low | C `xassert(seat->clipboard.window == NULL)` before the terminal scan; Zig asserts only in the accept branch | move the assertion back before the scan (debug builds only) |
| V-01 | `render.zig:5502` | `render.c:4308` | *not a defect* | n/a | C and Zig both call `xdg_toplevel_set_title(term->window->xdg_toplevel, ...)` unconditionally; the crash needs a zeroed `wl_window` plus an expired rate-limit stamp | harness precondition; no product fix |

### S-01 — CSD title font is twice the size

```c
/* wayland.c:61 */
snprintf(pixelsize, sizeof(pixelsize), "pixelsize=%u",
         (int)roundf(conf->csd.title_height * scale * 1 / 2));
```
```zig
// wayland.zig:778-780
const px: c_int = @intFromFloat(@round(
    @as(f32, @floatFromInt(conf.csd.title_height)) * scale));
_ = snprintf(&pixelsize, pixelsize.len, "pixelsize=%u", @as(c_uint, @intCast(px)));
```

C evaluates `((title_height * scale) * 1) / 2`; the port drops the division. With the default `title_height = 26` and `scale = 1`, C asks fcft for `pixelsize=13`, Zig for `pixelsize=26`. This changes the titlebar metrics and therefore `render_csd_title()`'s OSD layout on every CSD-enabled window. `MIGRATION_PLAN.md` §14 (D2f) describes "pixelsize from `csd.title_height` × scale" but does **not** record the halving as deliberate.

### S-02 — notification stdout fd loses its FDM registration

```c
/* notify.c:23-27 */
if (notif->pid > 0)
    fdm_del(term->fdm, notif->stdout_fd);
```
```zig
// notify.zig:17-19
export fn notify_free(term: ?*types.Terminal, notif: *types.Notification) ... {
    _ = term;
    // TODO(chunk B): fdm_del(term->fdm, notif->stdout_fd) when pid > 0
```

`notify_free()` is called from `notif_done()` (`notify.zig:425`) and from `term_destroy()`/`term_reset()` (`terminal.zig:4641`, `:4646`, `:4893`, `:4898`). In all four cases C removes the stdout fd from the FDM; Zig leaves it registered with a freed `notification`, so a later writable/HUP event either polls a closed descriptor or, after fd reuse, is matched against a different notification. This is a real cleanup/ownership defect, not a style difference.

### S-03..S-07 — `float` arithmetic widened to `f64`

All five sites replace a C `float` operation with a `f64` one. The values differ whenever the fractional-scaling value (a multiple of 1/120) makes the exact f32 product land on a rounding boundary. A small C probe on this machine:

```
$ cc /tmp/audit-surface/f32.c -lm && ./f32
resize  scale=1.049999952 C=11 zig-f64=10
hotspot scale=1.100000024 C=10 zig-f64=9
margin  scale=0.833333313 C=3 zig-f64=2
```

* S-03: `term.scale = 126/120` (1.05f), `render_resize(term, 10, h, 0)` gives physical width 11 in C, 10 in Zig.
* S-04: same family in `set_size_from_grid()`; the int truncation after padding multiplication can differ by one pixel.
* S-05: the `wl_surface_damage_buffer`/geometry pairs sent at the end of `render_resize()` can be off by one logical pixel.
* S-06: `scale = 100/120` (0.8333f) gives OSD margin 3 in C, 2 in Zig: the render-timer, scrollback-indicator, search-box and URL OSDs are all one pixel narrower on each side.
* S-07: with a client-side cursor hotspot of 11 px and `scale = 132/120` (1.1f), C sends hotspot 10 to `wl_pointer_set_cursor()`, Zig sends 9.

The rest of the port *does* preserve `f32` (`get_csd_data()`, `snapToScale()`, `roundfDiv()`, `ime.scaleInt()`, `wl_pointer_motion`'s auto-scroll divisor, `wl_fixed_t` helpers). These five sites are the outliers. §14 does not document any of them as deliberate.

### S-08..S-15 — smaller divergences

* S-08: `keyboard_key()` passes `key + 8` to `key_press_release()`. C's unsigned addition wraps; Zig's ReleaseSafe `+` traps. Only reachable from a malformed compositor keycode, but C's behaviour is defined.
* S-09/S-10/S-11/S-12/S-13: the verified-differences list permits omitting `LOG_DBG` only. These are `LOG_WARN`/`LOG_ERR` sites whose diagnostics are silently lost. They do not change protocol traffic, but they remove the operator-visible evidence for DnD rejection, clipboard timeout, invalid URI, source-creation failure and a dead terminal's notification.
* S-14: C rejects a notification with neither title nor body; Zig sends one with an empty title. This is a safe divergence from C's assertion, but it is not in §14 and changes observable notification traffic.
* S-15: C's `xassert(window == NULL)` runs for every DnD enter, including rejected offers; Zig's assertion only runs on the accepted path. Debug builds therefore detect fewer double-enter bugs.

## V-01 — the valgrind SIGSEGV

**Verdict: harness precondition, not a lifetime/ordering error in `render.zig`, and not a mirror gap.**

The reported chain is `wl_proxy_get_version → xdg_toplevel_set_title → render_update_title → term_reset → test_term_reset`.

`tests/test-terminal.c:2644` builds a bare terminal and a **zeroed** `struct wl_window win = {0}`; it assigns `term->window = &win` and stamps `render.title.last_update`/`render.app_id.last_update` with `clock_gettime()` immediately before `term_reset()`. `term_reset()` calls `term_set_window_title()` and `term_set_app_id()` (`terminal.zig:4865`/`:4867`). Both go through the 8333 µs rate limiter (`render.zig:640-670`). If the stamp is still fresh, the timerfd path is taken and no protocol request is made. If more than 8333 µs elapse (valgrind's slowdown makes this plausible; the subsequent work in `term_reset()` includes allocation and logging), `render_update_title()` executes:

```c
/* render.c:4296-4308 */                    /* render.zig:5490-5502 */
xdg_toplevel_set_title(term->window->xdg_toplevel, title);  render_shim_xdg_toplevel_set_title(
                                                              term.window.?.xdg_toplevel, title);
```

`xdg_toplevel` is `NULL` in the zeroed `wl_window`; libwayland's generated inline dereferences it in `wl_proxy_get_version()` and faults. C at the same call site does exactly the same thing: `term->window->xdg_toplevel` is also `NULL`, with no guard in `render_refresh_title()` or `render_update_title()`. The mirror declares `xdg_toplevel: ?*anyopaque`, so there is no layout or field-name gap; the ABI probe passes and the six smoke launches exercise real proxies successfully.

Minimal repro (same precondition in either language):

```c
struct terminal *term = term_new();
static struct config conf = {.title = "foot"};
struct wl_window win = {0};                 /* xdg_toplevel == NULL */
term->conf = &conf;
term->window = &win;
term->render.title.last_update.tv_sec -= 1; /* force the slow path */
term_set_window_title(term, "foot");         /* SIGSEGV in wl_proxy_get_version */
```

The product fix would be to guard `window->xdg_toplevel != NULL`; C does not have it, so that would be a deliberate new divergence, not a port correction. The correct fix is in the harness: either give the fake window a real/duplicate proxy or keep the rate-limit stamp fresh (e.g. stamp inside the test immediately before the title-setting call and avoid other work). Because the timing is load-dependent, the fault is intermittent: on this checkout all three build dirs completed valgrind with exit 0 (0 errors), so the 139 is not reproducible here. No product change is proposed.

## Completeness matrix

| C module | C functions (incl. statics/callbacks) | Zig bodies (same module or named port) | C-only logic still in shims | callbacks with no Zig equivalent | verdict |
|---|---:|---:|---|---|---|
| `wayland.c` | 76 | 76 | listener tables + `add_listener` forwarders in `wayland-shim.c` | none | complete; S-01 |
| `render.c` | 83 | 82 | presentation statistics + `struct presentation_context` in `terminal-shim.c` | none (`sync_output`, `presented`, `discarded`, `frame_callback`, `xcursor_callback`, `render_buffer_release_callback` all exist) | complete; S-03..S-07 |
| `input.c` | 50 | 50 | keyboard/pointer/touch listener tables in `terminal-shim.c` | none (all 6+10+5 table entries map to `input.zig` exports) | complete; S-08 |
| `selection.c` | 87 | 87 | data-source/offer/device tables in `wayland-shim.c` | none (`target/send/cancelled/.../drop/selection`, primary equivalents all map) | complete; S-09..S-12, S-15 |
| `shm.c` | 25 | 24 | `page_size()` and generated inlines in `shm-shim.c` | none (`buffer_release` → `shm.zig:buffer_release`) | complete |
| `ime.c` | 13 unique (21 with `#ifdef` duplicates) | 13 | text-input listener table in `wayland-shim.c` | none | complete |
| `url-mode.c` | 16 | 16 | none | none | complete |
| `key-binding.c` | 25 | 25 | none | n/a | complete |
| `cursor-shape.c` | 3 | 3 | none | n/a | complete |
| `notify.c` | 13 | 13 | tll/spawn helpers in `notify-shim.c` | none (`fdm_notify_stdout`, `notif_done` exist) | complete; S-02, S-13, S-14 |
| `user-notification.c` | 1 | 1 | none | n/a | complete |

The only C bodies deliberately left in shims are the ones §14 already accounts for: generated protocol inlines/listener tables, the `#ifdef` platform tests, the C-only `struct presentation_context`/exit-time statistics logger (`terminal-shim.c`), and the tll/spawn helpers. No callback table entry points at a missing Zig export.

### Listener-table mapping (shim entry → Zig export)

| Table (shim) | Entries → Zig export |
|---|---|
| `wl_keyboard_listener` (`terminal-shim.c:1038`) | `keyboard_keymap`, `keyboard_enter`, `keyboard_leave`, `keyboard_key`, `keyboard_modifiers`, `keyboard_repeat_info` |
| `wl_pointer_listener` (`terminal-shim.c:1047`) | `wl_pointer_enter`, `wl_pointer_leave`, `wl_pointer_motion`, `wl_pointer_button`, `wl_pointer_axis`, `wl_pointer_frame`, `wl_pointer_axis_source`, `wl_pointer_axis_stop`, `wl_pointer_axis_discrete`, `wl_pointer_axis_value120` |
| `wl_touch_listener` (`terminal-shim.c:1062`) | `wl_touch_down`, `wl_touch_up`, `wl_touch_motion`, `wl_touch_frame`, `wl_touch_cancel` |
| `wl_data_source_listener` (`wayland-shim.c:19`) | `selection_data_source_{target,send,cancelled,dnd_drop_performed,dnd_finished,action}` |
| `zwp_primary_selection_source_v1_listener` (`wayland-shim.c:28`) | `selection_primary_source_{send,cancelled}` |
| `wl_data_offer_listener` (`wayland-shim.c:34`) | `selection_offer`, `selection_offer_source_actions`, `selection_offer_action` |
| `zwp_primary_selection_offer_v1_listener` (`wayland-shim.c:40`) | `selection_primary_offer` |
| `wl_data_device_listener` (`wayland-shim.c:45`) | `selection_data_device_{data_offer,enter,leave,motion,drop,selection}` |
| `zwp_primary_selection_device_v1_listener` (`wayland-shim.c:54`) | `selection_primary_device_{data_offer,selection}` |
| `zwp_text_input_v3_listener` (`wayland-shim.c:100`) | `ime_{enter,leave,preedit_string,commit_string,delete_surrounding_text,done}` |
| `wl_buffer_listener` (`shm-shim.c:45`) | `buffer_release` (`shm.zig`) |
| `wl_callback_listener` ×2 (`terminal-shim.c:1858`, `:1873`) | `frame_callback` (data = terminal), `xcursor_callback` (data = seat) |
| `wp_presentation_feedback_listener` (`terminal-shim.c:1810`) | `sync_output`, `presented`, `discarded` |
| `wl_registry`, `wl_output`, `zxdg_output_v1`, `wl_surface`, `xdg_surface`, `xdg_toplevel`, decoration, wm_base, shm, seat, presentation, color-manager, fractional-scale, background-effect, activation-token (`wayland-shim.c`) | corresponding exports in `wayland.zig`; each `add_*_listener` passes the same user-data pointer as C (`wayl`, `mon`, `win`, `seat`, `ctx`) |

## Shim table

Classification follows §12.9/`doc/shim-audit.md`: **a** = keep (generated protocol/C-type knowledge), **b** = delete (mirror accessor), **c** = port the leaked logic. All class-b accessors in these four files had already been removed at this base, so the current table has no class-b entries.

| file | functions | a | b | c | action |
|---|---:|---:|---:|---:|---|
| `wayland-shim.c` | 24 | 24 | 0 | 0 | keep all |
| `shm-shim.c` | 11 | 10 | 0 | 1 | port `page_size()` |
| `notify-shim.c` | 20 | 2 | 0 | 18 | port the 18 tll/spawn helpers |
| `terminal-shim.c` | 205 | 185 | 0 | 20 | port the 20 logic helpers; keep the 185 protocol/mirror adapters and three listener tables |
| **total** | **260** | **221** | **0** | **39** | class-c bodies total **468** lines |

### Class-c functions and body line counts

| file | function | body lines |
|---|---|---:|
| `shm-shim.c` | `page_size()` | 14 |
| `notify-shim.c` | `notify_tll_free_and_free_actions()` | 3 |
| `notify-shim.c` | `notify_active_first()` | 4 |
| `notify-shim.c` | `notify_active_next()` | 10 |
| `notify-shim.c` | `notify_spawn_expand_action_arg()` | 7 |
| `notify-shim.c` | `notify_active_remove()` | 8 |
| `notify-shim.c` | `notify_wayl_terms_first()` | 4 |
| `notify-shim.c` | `notify_wayl_terms_next()` | 10 |
| `notify-shim.c` | `notify_spawn_expand_close()` | 5 |
| `notify-shim.c` | `notify_active_push_back()` | 3 |
| `notify-shim.c` | `notify_active_back()` | 4 |
| `notify-shim.c` | `notify_active_len()` | 3 |
| `notify-shim.c` | `notify_active_back_after_push()` | 3 |
| `notify-shim.c` | `notify_actions_first()` | 4 |
| `notify-shim.c` | `notify_actions_next()` | 10 |
| `notify-shim.c` | `notify_actions_len()` | 3 |
| `notify-shim.c` | `notify_actions_zero()` | 3 |
| `notify-shim.c` | `notify_spawn_expand_command()` | 13 |
| `notify-shim.c` | `notify_fdm_add_stdout()` | 3 |
| `terminal-shim.c` | `terminal_shim_urls_mode_active()` | 3 |
| `terminal-shim.c` | `terminal_shim_precompose()` | 12 |
| `terminal-shim.c` | `emoji_vs_compare()` | 13 |
| `terminal-shim.c` | `terminal_shim_emoji_vs_width()` | 22 |
| `terminal-shim.c` | `wayland_shim_surface_damage_buffer()` | 6 |
| `terminal-shim.c` | `wayland_shim_subsurface_set_position()` | 6 |
| `terminal-shim.c` | `wayland_shim_set_opaque_region()` | 19 |
| `terminal-shim.c` | `wayland_shim_set_opaque_region_rect()` | 11 |
| `terminal-shim.c` | `render_shim_clip_rect()` | 6 |
| `terminal-shim.c` | `render_shim_close_button()` | 33 |
| `terminal-shim.c` | `render_shim_curly_underline()` | 25 |
| `terminal-shim.c` | `terminal_shim_linear_blending()` | 3 |
| `terminal-shim.c` | `terminal_shim_grid_is_high_bit_depth()` | 4 |
| `terminal-shim.c` | `terminal_shim_fcft_font_options_configure()` | 18 |
| `terminal-shim.c` | `wayland_shim_iface_id()` | 57 |
| `terminal-shim.c` | `wayland_shim_registry_bind()` | 80 |
| `terminal-shim.c` | `wayland_shim_toplevel_icon_set()` | 7 |
| `terminal-shim.c` | `log_presentation_statistics()` | 10 |
| `terminal-shim.c` | `render_shim_presentation_stat_add()` | 10 |
| `terminal-shim.c` | `render_shim_presentation_ctx_new()` | 9 |

All other in-scope shim functions are class a. `wayland-shim.c`'s 24 functions are the listener-table `add_*_listener()` forwarders plus `keyboard_leave`/`pointer_leave`; `shm-shim.c`'s 10 are the generated `wl_shm`/`wl_buffer` inlines, platform feature probes and format constants; `notify-shim.c`'s 2 are `notify_xstrjoin()` and `notify_pipe2()`; `terminal-shim.c`'s 185 are the generated xdg/seat/data-device/IME/region/pixman forwarders, the ABI-pinned field accessors, the presentation-context accessors, and the three listener tables. Names are unchanged from `doc/shim-audit.md` at commit `c2524928`.

## Top 10 — minimal repros

1. **S-01** `conf.csd.title_height = 26; term.scale = 1; csd_reload_font(win, -1);` → C asks fcft for `pixelsize=13`, Zig for `pixelsize=26`. Titlebar font is 2× too large.
2. **S-02** Spawn a tracked notification (helper writes to stdout), let `notif_done()` fire, then write again to the old pipe: C's fd was removed by `fdm_del()`, Zig's is still polled; after fd reuse the callback can match the wrong `notification`.
3. **S-03** `term.scale = 126.0f/120; render_resize(term, 10, 20, 0);` with a configured window → C physical width 11, Zig 10.
4. **S-04** Same fractional scale, `conf.pad_left + conf.pad_right = 10`, grid width 100 → `set_size_from_grid()` truncates differently by one pixel.
5. **S-05** `render_resize()` with CSD borders enabled at `scale = 1.05f`; the `xdg_toplevel_set_min_size`/`xdg_surface_set_window_geometry` arguments differ by one in the last snap step.
6. **S-06** `term.scale = 100.0f/120; render_render_timer(term, t);` → C OSD margin 3, Zig 2; same for scrollback indicator and search box.
7. **S-07** Load a cursor with `hotspot_x = 11`, set `scale = 132.0f/120`, move the pointer over the grid → C sends hotspot 10, Zig 9.
8. **S-08** Feed a synthetic `wl_keyboard.key` event with `key = 0xfffffff9` → C passes `key=1` to `key_press_release()`, Zig panics on overflow.
9. **S-09** Set `clipboard.mime_type = UNSET` and deliver `wl_data_device.drop`: C logs the compositor bug, Zig silently ignores it.
10. **S-10** Open a clipboard transfer, send no data for two seconds: C logs the timeout warning, Zig does not.

## Verified-identical list

The following were checked side by side and found behaviourally identical (no finding):

* **Protocol requests and ordering**: `wayl_init`, `handle_global`/`handle_global_remove`, `wayl_win_init`/`wayl_win_destroy`, `xdg_surface_configure` (state capture, CSD geometry subtraction, `ack_configure` before resize, forced-size and commit decisions), `wayl_get_activation_token`/`activation_token_done`, `wayl_activate`, `wayl_flush`/`wayl_roundtrip`, `wayl_win_alpha_changed`, `wayl_win_subsurface_new{,_with_custom_parent}`/`destroy`, `csd_instantiate`/`csd_destroy`, `render_resize`'s final `set_min_size`/`set_window_geometry`/damage/attach/commit sequence, `grid_render`'s `wl_surface_frame` → scale → presentation-feedback → attach/commit sequence, `render_overlay`, `render_csd*`, IME `enable`/`disable`/`set_cursor_rectangle`, selection offer/receive/DnD request order, and the shm pool creation/sealing/mmap/`wl_shm_pool_create_buffer` sequence. Request destinations, user-data pointers and serial use match C in every table row above.
* **Destroy/release/finish placement**: `seat_destroy`, `monitor_destroy`, `wayl_destroy`, `wayl_win_destroy`, `shm` pool/buffer refcount teardown, `wl_callback_destroy`, `wp_presentation_feedback_destroy`, `xdg_activation_token_v1_destroy`, `wl_data_offer_finish/destroy` in `receive_dnd_done`, `zwp_text_input_v3_destroy`.
* **Geometry still in f32**: `get_csd_data()` (including `top_offset`, `top_bottom_width`, `left_right_height`), `snapToScale()`, `roundfDiv()`, `render_csd()` position rounding, `render_render_timer()`'s viewport destination, IME `scaleInt()`, pointer enter/motion fixed-point scaling, and the scroll auto-scroll divisor.
* **State machines**: buffer age/pre-applied damage hand-off (age/size gates, `-3` queue push, `.start/.stop` reset, worker `done` semaphore), `frame_callback`/FDM-hook pending-flag deferral, pointer button trackers and click counting (`CLOCK_MONOTONIC` + `timespec_sub`), touch HELD→DRAGGING/SCROLLING transitions and focus save/restore, keyboard focus swap and repeat timer, selection paste guard/offer ownership/DnD window tracking, scroll timer arming/re-arming, and URL-mode snapshot/sub-surface lifecycle.
* **Memory/fds**: `mmap`/`munmap` pairing in `keyboard_keymap` and `shm`, `memfd`/`ftruncate`/seal pairing, `pipe2` read/write-end ownership in selection and notify, `free()` of C allocations with C `free`, and the deliberate `-1` fd reset in `execute_binding()` (`MIGRATION_PLAN.md` §14, "Post-D4c").
* **Deliberate divergences already recorded in §14**: NULL guards where C dereferences (e.g. no mouse/keyboard focus, NULL surface), omitted `LOG_DBG`, xdg-shell request forwarders living only in C, listener tables staying in shims, packed struct mirrors, `@intFromEnum`, and the `pipe_fd[0] = -1` fix. These are not reported as findings. S-14 is a *new* safe divergence from C's assertion and is reported because §14 does not cover it.
