# Audit 1 — VT core and terminal state

> **Status (endgame, 2026-11-25, base `98f999c6`).** Findings are closed as
> follows; the body below is the audit as written and is not rewritten.
>
> | id | status |
> |---|---|
> | VT-01, VT-02, VT-03 | fixed `01f734c7` |
> | VT-04 | fixed `cbb3b171` |
> | VT-05 | fixed `4a5f3382` |
> | VT-06 | fixed `75be865f` (debug output compiled out, as C does) |
> | VT-07 | fixed `75be865f` (guard kept, comment added) |
> | VT-08 | found by the 120-seed campaign after this audit: `term_cursor_up()`/
>   `term_cursor_down()` trapped (Debug/ReleaseSafe) on a cursor outside the
>   scroll region, reachable by setting a region and then switching to the alt
>   screen. C's release build has no assert there. Asserts dropped; regression
>   check `test_cursor_outside_region`. |
>
> Regression checks for VT-01…VT-03 live in `tests/test-terminal.c`
> (`test_csi_private_dispatch`, `test_sgr_bad_colour_keeps_parsing`); VT-06
> has `test_osc_unknown_is_silent`. VT-04 is exercised by the fuzz seed 118
> (`0x01` URI chunk).

Scope: `vt`, `csi`, `dcs`, `osc`, `sixel`, `terminal`, `grid`, `composed`,
`extract`, `search`, `char32`, `tokenize`, `unicode-mode`, `box-drawing`,
`hsl`, `quirks`, `terminal_types.zig`, plus `csi/dcs/grid/sixel/vt/terminal-shim.c`.
C baseline: `origin/master` @ `18754871^` (pre-migration C). Worktree branch:
`audit-vt`, HEAD `18754871`. Read-only audit: no product file changed.
Verification run (all clean): `ninja -C build`, `meson test -C build
--no-rebuild` (5/5), `scripts/dev-check.sh`, `valgrind -q --error-exitcode=99
./build/tests/test-terminal`. The harness does **not** feed bytes through
`vt_from_slave()`; it calls terminal primitives directly, which is why findings
VT-01/02/04 escape it.

Counts: 601 C functions inventoried; 588 ported, 13 deliberate exceptions, 0
unmapped. Findings: 5 `bug`, 1 `risk`, 1 `nit` (style: 0).

## Findings

| id | file:line (Zig) | C reference (file:line) | class | severity | evidence | suggested fix |
|---|---|---|---|---|---|---|
| VT-01 | `csi.zig:765-769` | `csi.c:800,1485,1645,1786,1816,1862,1872,1934,2153` | behaviour | bug | `csi_dispatch()` handles `private == 0` only; `caseQuestion`, `caseGreater`, `caseLess`, `caseSpace`, `caseBang`, `caseEquals`, `caseQuestionDollar`, `caseDollar`, `caseHash` are defined at `csi.zig:1265-1742` but never called; `nm build/csi.o` shows no symbols for them (Zig dead-code-eliminated). Every DECSET/DECRST/XT*/DECRQM/soft-reset/kitty-keyboard sequence is a no-op. | Restore the C `switch (term->vt.private)` dispatch: `'?'`→`caseQuestion` (with `(private>>8)&0xff == '$'` → `caseQuestionDollar`), `'>'`→`caseGreater`, `'<'`→`caseLess`, `' '`→`caseSpace`, `'!'`→`caseBang`, `'='`→`caseEquals`, `'$'`→`caseDollar`, `'#'`→`caseHash`. |
| VT-02 | `csi.zig:156` | `csi.c:237-241` | behaviour | bug | In the `38/48/58` case, C's `break` leaves the `switch` and continues the parameter loop; Zig's `break` leaves the `while`. An unrecognised colour form (`38:1`, `38:3`, …) therefore skips all remaining SGR parameters in the same CSI. | Replace `break` with `continue` (or restructure as `if (handled) { … }`), preserving the C "skip this parameter, keep parsing" semantics. |
| VT-03 | `terminal.zig:1373-1374` | `terminal.c:3173-3181` | memory | bug | Reverse scroll frees the row at `abs_r` but the C line `if (term->render.last_cursor.row == row) term->render.last_cursor.row = NULL;` is a comment. The field is mirrored (`terminal_types.zig:706`) and the same clearing is implemented in `term_erase_scrollback` (`terminal.zig:2452`). `render.zig:600-603` later dereferences the stale pointer → use-after-free. | Use the mirrored field directly: `if (term.render.last_cursor.row == current_row) term.render.last_cursor.row = null;` before `grid_row_free()`. |
| VT-04 | `selection.zig:2120-2128`, `2161-2190` | `selection.c:2157-2170`, `2199-2313` | behaviour | bug | URI-list clipboard receive of a single `0x01`: `receiveChunk()` calls `ctx.decoder(ctx, p, 0)` (`skip_one()` with `i == 0`); `fdmReceiveDecoderUri()` does not realloc for `size == 0` and then unb wraps `ctx.buf.data` at line 2128. C's decoder performs `memcpy(NULL,p,0)`/`memmove(NULL,..,0)` — UB by the standard, tolerated by libc — so the C sequence silently survives. See "Open defect" below. | Add `if (size == 0) return;` at the top of `fdmReceiveDecoderUri()` (decoder-side contract fix); optionally also skip zero-length `skip_one()` calls in `receiveChunk()`. |
| VT-05 | `osc.zig:193-194` | `osc.c:300-315` | behaviour | bug | C resets `errno = 0` before `strtoul()` and rejects `errno != 0`; Zig checks only `end[0] != ']'`. `OSC 11 ; [999999999999999999999]#000000 BEL` is accepted by Zig (alpha clamped to 100%) but rejected by C (background unchanged). | Declare `extern fn __errno_location() *c_int`, set it to 0 before `strtoul`, and return false when non-zero (as `osc_dispatch()` case 9 already does). |
| VT-06 | `osc.zig:12-14`, `607` | `osc.c:24` (`LOG_ENABLE_DBG 0`) | behaviour | risk | C's `UNHANDLED()`/`LOG_DBG()` compile to nothing. Zig routes `logDbg()` and `unhandled()` through `std.debug.print`, which writes to stderr in normal builds: every unknown OSC sequence and every OSC buffer resize emits text where C is silent. Other Zig modules use `extern fn log_msg(...)`; these two do not. | Route through the existing C logger with `LOG_CLASS_DEBUG`, or make `logDbg()`/`unhandled()` compile-time no-ops under the same option as C. |
| VT-07 | `sixel.zig:480-486` | `sixel.c:1642-1646` | behaviour | nit | Zig guards the background fill with `alloc_new_height_u > old_height_u`; C computes `memset_u32(..., (alloc_new_height - old_height) * new_width)` unconditionally, which underflows to a huge `size_t` if height shrinks with the same width. The Zig guard is the correct fix for C UB, but no comment records it. | Keep the guard and add a one-line comment: "C underflows this count when shrinking; skip". |

### Evidence snippets

VT-01 — private CSI dispatch (C `csi.c:800,1485`; Zig `csi.zig:765-769`, helper at 1265):

```c
/* C */
switch (term->vt.private) {
case 0:   { /* ... */ break; }
case '?': { switch (final) { case 'h': for (...) decset(...); break; /* ... */ } break; }
case '>': { /* secondary DA, XTVERSION, kitty push */ break; }
case '#': { /* XTPUSHCOLORS, DECSCNM, ... */ break; }
}
```
```zig
/* Zig */
export fn csi_dispatch(term: *types.Terminal, final: u8) callconv(.c) void {
    switch (term.vt.private) {
        0 => case0Dispatch(term, final),
        else => {}, // TODO: cases '$', '>', '?', '!', ...
    }
}
fn caseQuestion(term: *types.Terminal, final: u8) void { /* unreachable */ }
```

VT-02 — `break` target (C `csi.c:237-241`; Zig `csi.zig:148-156`):

```c
/* C: inside for (i ...) switch (param) */
else {
    UNHANDLED_SGR(i);
    break;          /* leaves switch; loop continues */
}
```
```zig
/* Zig: inside while (i < n) switch (param) */
} else {
    handled = false;
}
if (!handled) break;   /* leaves while; remaining params dropped */
```

VT-03 — freed `last_cursor.row` (C `terminal.c:3173-3181`; Zig `terminal.zig:1368-1374`):

```c
const int abs_r = grid_row_absolute(term->grid, r);
struct row *row = term->grid->rows[abs_r];
grid_row_free(row);
term->grid->rows[abs_r] = NULL;
if (term->render.last_cursor.row == row)
    term->render.last_cursor.row = NULL;
```
```zig
const current_row = term.grid.?.rows.?[@intCast(abs_r)];
grid_row_free(current_row);
term.grid.?.rows.?[@intCast(abs_r)] = null;
// C: if (term->render.last_cursor.row == row) term->render.last_cursor.row = NULL;
// render.last_cursor.row is opaque here; shim later if needed.
```

VT-04 — zero-length decoder call (`selection.c:2199-2235` macro, `2157-2170`;
`selection.zig:2161-2190`, `2120-2128`):

```c
#define skip_one() do { ctx->decoder(ctx, p, i); p += i + 1; left -= i + 1; } while (0)
case '\x01': if (!no_strip) { skip_one(); goto again; }   /* i == 0 here */
```
```zig
0x01, ... => {
    if (!ctx.no_strip) {
        ctx.decoder(ctx, p, i);   /* i == 0 */
        ...
    }
}
fn fdmReceiveDecoderUri(ctx: *ClipboardReceive, data: [*]u8, size: usize) void {
    while (ctx.buf.idx + size > ctx.buf.sz) { ... }   /* 0 > 0: no alloc */
    const buf = ctx.buf.data.?;                       /* panic on first byte */
```

VT-05 — `errno` after `strtoul` (`osc.c:300-315`; `osc.zig:188-198`):

```c
errno = 0;
unsigned long percent = strtoul(start, &end, 10);
if (errno != 0 || *end != ']')
    return false;
```
```zig
const percent = strtoul(start, &end, 10);
if (end[0] != ']') return false;
have_alpha = true;
const pct_capped: c_ulong = @min(percent, 100);
```

VT-06 — debug logging (`osc.c:24`; `osc.zig:12-14,607`):

```c
#define LOG_ENABLE_DBG 0
#define UNHANDLED() LOG_DBG("unhandled: OSC: %.*s", ...)
/* osc_dispatch(): default: UNHANDLED();  -> no output */
```
```zig
fn logDbg(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("osc: " ++ fmt ++ "\n", args);
}
fn unhandled(term: *types.Terminal) void {
    std.debug.print("osc: unhandled: OSC: {s}\n", .{term.vt.osc.data.?[0..term.vt.osc.idx]});
}
```

VT-07 — resize count (`sixel.c:1642-1646`; `sixel.zig:480-486`):

```c
if (initialize_bg) {
    memset_u32(&new_data[old_height * new_width], bg,
               (alloc_new_height - old_height) * new_width);
}
```
```zig
if (initialize_bg and alloc_new_height_u > old_height_u) {
    memset_u32(new_data + old_height_u * new_width, bg,
               (alloc_new_height_u - old_height_u) * new_width);
}
```

## Completeness matrix

601 C functions (pure `static inline` wrappers and `IGNORE_WARNING` macro
invocations excluded). "exception" = deliberately not ported: debug-only
string helpers/`_DEBUG` verifiers, `#if 0` code, or C-side wrapper with the
behaviour ported under an `_impl` name. Line numbers are from the respective
source file.

| Module | C function (C line) | Zig function (Zig line) | Status |
|---|---|---|---|
| vt | `esc_as_string` (86) | `—` | exception |
| vt | `action_ignore` (107) | `action_ignore` (75) | ported |
| vt | `action_clear` (112) | `action_clear` (79) | ported |
| vt | `action_execute` (119) | `action_execute` (84) | ported |
| vt | `action_print` (294) | `action_print` (159) | ported |
| vt | `action_param_lazy_init` (301) | `action_param_lazy_init` (165) | ported |
| vt | `action_param_new` (315) | `action_param_new` (175) | ported |
| vt | `action_param_new_subparam` (345) | `action_param_new_subparam` (192) | ported |
| vt | `action_param` (375) | `action_param` (208) | ported |
| vt | `action_collect` (395) | `action_collect` (217) | ported |
| vt | `tab_set` (444) | `tab_set` (229) | ported |
| vt | `action_esc_dispatch` (465) | `action_esc_dispatch` (240) | ported |
| vt | `action_csi_dispatch` (593) | `action_csi_dispatch` (303) | ported |
| vt | `action_osc_start` (599) | `action_osc_start` (307) | ported |
| vt | `action_osc_end` (605) | `action_osc_end` (312) | ported |
| vt | `action_osc_put` (624) | `action_osc_put` (325) | ported |
| vt | `action_hook` (632) | `action_hook` (331) | ported |
| vt | `action_unhook` (638) | `action_unhook` (335) | ported |
| vt | `action_put` (644) | `action_put` (340) | ported |
| vt | `action_utf8_print` (650) | `action_utf8_print` (344) | ported |
| vt | `action_utf8_21` (656) | `action_utf8_21` (348) | ported |
| vt | `action_utf8_22` (663) | `action_utf8_22` (352) | ported |
| vt | `action_utf8_31` (671) | `action_utf8_31` (357) | ported |
| vt | `action_utf8_32` (678) | `action_utf8_32` (361) | ported |
| vt | `action_utf8_33` (685) | `action_utf8_33` (365) | ported |
| vt | `action_utf8_41` (703) | `action_utf8_41` (372) | ported |
| vt | `action_utf8_42` (710) | `action_utf8_42` (376) | ported |
| vt | `action_utf8_43` (717) | `action_utf8_43` (380) | ported |
| vt | `action_utf8_44` (724) | `action_utf8_44` (384) | ported |
| vt | `anywhere` (745) | `anywhere` (391) | ported |
| vt | `state_ground_switch` (761) | `state_ground_switch` (401) | ported |
| vt | `state_escape_switch` (781) | `state_escape_switch` (413) | ported |
| vt | `state_escape_intermediate_switch` (808) | `state_escape_intermediate_switch` (434) | ported |
| vt | `state_csi_entry_switch` (825) | `state_csi_entry_switch` (445) | ported |
| vt | `state_csi_param_switch` (847) | `state_csi_param_switch` (460) | ported |
| vt | `state_csi_intermediate_switch` (870) | `state_csi_intermediate_switch` (475) | ported |
| vt | `state_csi_ignore_switch` (888) | `state_csi_ignore_switch` (487) | ported |
| vt | `state_osc_string_switch` (905) | `state_osc_string_switch` (498) | ported |
| vt | `state_dcs_entry_switch` (929) | `state_dcs_entry_switch` (508) | ported |
| vt | `state_dcs_param_switch` (950) | `state_dcs_param_switch` (523) | ported |
| vt | `state_dcs_intermediate_switch` (971) | `state_dcs_intermediate_switch` (538) | ported |
| vt | `state_dcs_ignore_switch` (989) | `state_dcs_ignore_switch` (550) | ported |
| vt | `state_dcs_passthrough_switch` (1003) | `state_dcs_passthrough_switch` (558) | ported |
| vt | `state_sos_pm_apc_string_switch` (1026) | `state_sos_pm_apc_string_switch` (569) | ported |
| vt | `state_utf8_21_switch` (1039) | `state_utf8_21_switch` (577) | ported |
| vt | `state_utf8_31_switch` (1049) | `state_utf8_31_switch` (584) | ported |
| vt | `state_utf8_32_switch` (1059) | `state_utf8_32_switch` (591) | ported |
| vt | `state_utf8_41_switch` (1069) | `state_utf8_41_switch` (598) | ported |
| vt | `state_utf8_42_switch` (1079) | `state_utf8_42_switch` (605) | ported |
| vt | `state_utf8_43_switch` (1089) | `state_utf8_43_switch` (612) | ported |
| vt | `vt_from_slave` (1101) | `vt_from_slave` (619) | ported |
| csi | `sgr_reset` (32) | `sgr_reset` (26) | ported |
| csi | `csi_as_string` (43) | `—` | exception |
| csi | `csi_sgr` (77) | `csi_sgr` (36) | ported |
| csi | `decset_decrst` (321) | `decset_decrst` (428) | ported |
| csi | `decset` (605) | `decset` (622) | ported |
| csi | `decrst` (611) | `decrst` (626) | ported |
| csi | `decrpm` (629) | `decrpm` (678) | ported |
| csi | `decrqm` (635) | `decrqm` (686) | ported |
| csi | `xtsave` (683) | `xtsave` (267) | ported |
| csi | `xtrestore` (728) | `xtrestore` (312) | ported |
| csi | `params_to_rectangular_area` (778) | `params_to_rectangular_area` (646) | ported |
| csi | `csi_dispatch` (796) | `csi_dispatch` (765) | ported |
| dcs | `ensure_size` (15) | `ensureSize` (57) | ported |
| dcs | `hex_decode` (33) | `hexDecode` (76) | ported |
| dcs | `lookup_capability` (85) | `lookupCapability` (99) | ported |
| dcs | `xtgettcap_reply` (112) | `xtgettcapReply` (131) | ported |
| dcs | `xtgettcap_put` (179) | `xtgettcapPut` (207) | ported |
| dcs | `xtgettcap_unhook` (197) | `xtgettcapUnhook` (217) | ported |
| dcs | `append_sgr_attr_n` (232) | `appendSgrAttrN` (244) | ported |
| dcs | `decrqss_put` (242) | `decrqssPut` (258) | ported |
| dcs | `decrqss_unhook` (255) | `decrqssUnhook` (265) | ported |
| dcs | `dcs_hook` (447) | `dcs_hook` (405) | ported |
| dcs | `dcs_put` (512) | `dcs_put` (458) | ported |
| dcs | `dcs_unhook` (521) | `dcs_unhook` (462) | ported |
| osc | `osc_to_clipboard` (27) | `osc_to_clipboard` (360) | ported |
| osc | `from_clipboard_cb` (117) | `fromClipboardCb` (426) | ported |
| osc | `from_clipboard_done` (162) | `fromClipboardDone` (466) | ported |
| osc | `osc_from_clipboard` (188) | `osc_from_clipboard` (492) | ported |
| osc | `osc_selection` (261) | `osc_selection` (556) | ported |
| osc | `osc_flash` (287) | `osc_flash` (94) | ported |
| osc | `parse_legacy_color` (294) | `parse_legacy_color` (178) | ported |
| osc | `parse_rgb` (366) | `parse_rgb` (236) | ported |
| osc | `osc_set_pwd` (444) | `osc_set_pwd` (98) | ported |
| osc | `osc_uri` (466) | `osc_uri` (131) | ported |
| osc | `osc_notify` (526) | `osc_notify_impl` (857) | ported |
| osc | `verify_kitty_id_is_valid` (581) | `verify_kitty_id_is_valid` (904) | ported |
| osc | `kitty_notification` (606) | `kitty_notification_impl` (939) | ported |
| osc | `kitty_text_size` (1129) | `kitty_text_size_impl` (1306) | ported |
| osc | `osc_dispatch` (1260) | `osc_dispatch` (622) | ported |
| osc | `osc_ensure_size` (1695) | `osc_ensure_size` (16) | ported |
| sixel | `color_decode_srgb` (24) | `color_decode_srgb` (118) | ported |
| sixel | `sixel_fini` (58) | `sixel_fini` (106) | ported |
| sixel | `sixel_init` (66) | `sixel_init` (998) | ported |
| sixel | `sixel_invalidate_cache` (190) | `sixel_invalidate_cache` (869) | ported |
| sixel | `sixel_destroy` (207) | `sixel_destroy` (882) | ported |
| sixel | `sixel_destroy_all` (220) | `sixel_destroy_all` (891) | ported |
| sixel | `sixel_erase` (231) | `sixel_erase` (904) | ported |
| sixel | `verify_list_order` (258) | `—` | exception |
| sixel | `verify_no_wraparound_crossover` (298) | `—` | exception |
| sixel | `verify_scrollback_consistency` (319) | `—` | exception |
| sixel | `verify_no_overlap` (343) | `—` | exception |
| sixel | `verify_sixels` (380) | `—` | exception |
| sixel | `sixel_insert` (389) | `sixel_insert` (924) | ported |
| sixel | `sixel_scroll_up` (417) | `sixel_scroll_up` (945) | ported |
| sixel | `sixel_scroll_down` (450) | `sixel_scroll_down` (966) | ported |
| sixel | `blend_new_image_over_old` (476) | `blend_new_image_over_old` (1178) | ported |
| sixel | `sixel_overwrite` (661) | `sixel_overwrite_internal` (1382) | ported |
| sixel | `_sixel_overwrite_by_rectangle` (772) | `_sixel_overwrite_by_rectangle` (1498) | ported |
| sixel | `sixel_overwrite_by_rectangle` (860) | `sixel_overwrite_by_rectangle` (1554) | ported |
| sixel | `sixel_overwrite_by_row` (885) | `sixel_overwrite_by_row` (1581) | ported |
| sixel | `sixel_overwrite_at_cursor` (942) | `sixel_overwrite_at_cursor` (1638) | ported |
| sixel | `sixel_cell_size_changed` (952) | `sixel_cell_size_changed` (1649) | ported |
| sixel | `sixel_sync_cache` (962) | `sixel_sync_cache` (1692) | ported |
| sixel | `sixel_reflow_grid` (1045) | `sixel_reflow_grid` (1763) | ported |
| sixel | `sixel_reflow` (1123) | `sixel_reflow` (1865) | ported |
| sixel | `sixel_unhook` (1132) | `sixel_unhook` (1873) | ported |
| sixel | `memset_u32` (1425) | `memset_u32` (177) | ported |
| sixel | `resize_horizontally` (1432) | `resize_horizontally` (310) | ported |
| sixel | `resize_vertically` (1492) | `resize_vertically` (372) | ported |
| sixel | `resize` (1546) | `resize` (420) | ported |
| sixel | `sixel_add_generic` (1659) | `sixel_add_generic` (182) | ported |
| sixel | `sixel_add_ar_11` (1676) | `sixel_add_ar_11` (203) | ported |
| sixel | `sixel_add_many_generic` (1701) | `sixel_add_many_generic` (220) | ported |
| sixel | `sixel_add_one_ar_11` (1731) | `sixel_add_one_ar_11` (249) | ported |
| sixel | `sixel_add_many_ar_11` (1758) | `sixel_add_many_ar_11` (278) | ported |
| sixel | `decsixel_generic` (1791) | `decsixel_generic` (501) | ported |
| sixel | `decsixel_ar_11` (1857) | `decsixel_ar_11` (554) | ported |
| sixel | `decgra` (1866) | `decgra` (562) | ported |
| sixel | `decgri_generic` (1982) | `decgri_generic` (624) | ported |
| sixel | `decgri_ar_11` (2015) | `decgri_ar_11` (647) | ported |
| sixel | `decgci` (2030) | `decgci` (659) | ported |
| sixel | `sixel_put_generic` (2115) | `sixel_put_generic` (772) | ported |
| sixel | `sixel_put_ar_11` (2128) | `sixel_put_ar_11` (783) | ported |
| sixel | `sixel_colors_report_current` (2141) | `sixel_colors_report_current` (19) | ported |
| sixel | `sixel_colors_reset` (2150) | `sixel_colors_reset` (25) | ported |
| sixel | `sixel_colors_set` (2162) | `sixel_colors_set` (34) | ported |
| sixel | `sixel_colors_report_max` (2177) | `sixel_colors_report_max` (48) | ported |
| sixel | `sixel_geometry_report_current` (2186) | `sixel_geometry_report_current` (54) | ported |
| sixel | `sixel_geometry_reset` (2199) | `sixel_geometry_reset` (69) | ported |
| sixel | `sixel_geometry_set` (2208) | `sixel_geometry_set` (75) | ported |
| sixel | `sixel_geometry_report_max` (2217) | `sixel_geometry_report_max` (81) | ported |
| terminal | `enqueue_data_for_slave` (53) | `enqueueDataForSlave` (2019) | ported |
| terminal | `data_to_slave` (65) | `dataToSlave` (2037) | ported |
| terminal | `term_paste_data_to_slave` (95) | `term_paste_data_to_slave` (2072) | ported |
| terminal | `term_to_slave` (116) | `term_to_slave` (2095) | ported |
| terminal | `fdm_ptmx_out` (144) | `fdm_ptmx_out` (2159) | ported |
| terminal | `add_utmp_record` (196) | `add_utmp_record` (4052) | ported |
| terminal | `del_utmp_record` (212) | `del_utmp_record` (4072) | ported |
| terminal | `fdm_ptmx` (244) | `fdm_ptmx` (2230) | ported |
| terminal | `term_ptmx_pause` (392) | `term_ptmx_pause` (2209) | ported |
| terminal | `term_ptmx_resume` (400) | `term_ptmx_resume` (2215) | ported |
| terminal | `fdm_flash` (408) | `fdm_flash` (1077) | ported |
| terminal | `fdm_blink` (440) | `fdm_blink` (1100) | ported |
| terminal | `term_arm_blink_timer` (492) | `term_arm_blink_timer` (1142) | ported |
| terminal | `cursor_refresh` (524) | `cursor_refresh` (1166) | ported |
| terminal | `fdm_cursor_blink` (535) | `fdm_cursor_blink` (1180) | ported |
| terminal | `fdm_delayed_render` (565) | `fdm_delayed_render` (3891) | ported |
| terminal | `fdm_app_sync_updates_timeout` (612) | `fdm_app_sync_updates_timeout` (2768) | ported |
| terminal | `fdm_title_update_timeout` (635) | `fdm_title_update_timeout` (2823) | ported |
| terminal | `fdm_icon_update_timeout` (659) | `fdm_icon_update_timeout` (2834) | ported |
| terminal | `fdm_app_id_update_timeout` (683) | `fdm_app_id_update_timeout` (2845) | ported |
| terminal | `initialize_render_workers` (707) | `initialize_render_workers` (3972) | ported |
| terminal | `free_custom_glyph` (758) | `freeCustomGlyph` (46) | ported |
| terminal | `free_custom_glyphs` (770) | `freeCustomGlyphs` (61) | ported |
| terminal | `term_line_height_update` (783) | `term_line_height_update` (101) | ported |
| terminal | `term_set_fonts` (814) | `term_set_fonts` (132) | ported |
| terminal | `get_font_dpi` (881) | `get_font_dpi` (525) | ported |
| terminal | `get_font_subpixel` (939) | `get_font_subpixel` (554) | ported |
| terminal | `term_pt_or_px_as_pixels` (984) | `term_pt_or_px_as_pixels` (11) | ported |
| terminal | `font_loader_thread` (1005) | `fontLoaderThread` (251) | ported |
| terminal | `reload_fonts` (1014) | `reload_fonts` (257) | ported |
| terminal | `load_fonts_from_conf` (1149) | `load_fonts_from_conf` (413) | ported |
| terminal | `term_init` (1172) | `term_init` (5103) | ported |
| terminal | `term_window_configured` (1514) | `term_window_configured` (3869) | ported |
| terminal | `shutdown_maybe_done` (1591) | `shutdown_maybe_done` (4170) | ported |
| terminal | `fdm_client_terminated` (1614) | `fdm_client_terminated` (4203) | ported |
| terminal | `fdm_shutdown` (1634) | `fdm_shutdown` (4237) | ported |
| terminal | `fdm_terminate_timeout` (1666) | `fdm_terminate_timeout` (4267) | ported |
| terminal | `term_shutdown` (1712) | `term_shutdown` (4326) | ported |
| terminal | `sig_alarm` (1813) | `sigAlarm` (4479) | ported |
| terminal | `term_destroy` (1820) | `term_destroy` (4525) | ported |
| terminal | `erase_cell_range` (2062) | `erase_cell_range` (3486) | ported |
| terminal | `erase_line` (2087) | `erase_line` (3516) | ported |
| terminal | `term_theme_apply` (2097) | `term_theme_apply` (3026) | ported |
| terminal | `term_reset` (2110) | `term_reset` (4835) | ported |
| terminal | `term_font_size_adjust_by_points` (2260) | `adjustFontSizeByPoints` (624) | ported |
| terminal | `term_font_size_adjust_by_pixels` (2284) | `adjustFontSizeByPixels` (646) | ported |
| terminal | `term_font_size_adjust_by_percent` (2307) | `adjustFontSizeByPercent` (667) | ported |
| terminal | `term_font_size_increase` (2331) | `term_font_size_increase` (688) | ported |
| terminal | `term_font_size_decrease` (2345) | `term_font_size_decrease` (699) | ported |
| terminal | `term_font_size_reset` (2359) | `term_font_size_reset` (710) | ported |
| terminal | `term_fractional_scaling` (2365) | `term_fractional_scaling` (493) | ported |
| terminal | `term_preferred_buffer_scale` (2373) | `term_preferred_buffer_scale` (498) | ported |
| terminal | `term_update_scale` (2379) | `term_update_scale` (558) | ported |
| terminal | `term_font_dpi_changed` (2420) | `term_font_dpi_changed` (580) | ported |
| terminal | `term_font_subpixel_changed` (2454) | `term_font_subpixel_changed` (603) | ported |
| terminal | `term_font_baseline` (2480) | `term_font_baseline` (95) | ported |
| terminal | `term_damage_rows` (2499) | `term_damage_rows` (836) | ported |
| terminal | `term_damage_rows_in_view` (2511) | `term_damage_rows_in_view` (840) | ported |
| terminal | `term_damage_all` (2523) | `term_damage_all` (848) | ported |
| terminal | `term_damage_view` (2529) | `term_damage_view` (852) | ported |
| terminal | `term_damage_cursor` (2535) | `term_damage_cursor` (856) | ported |
| terminal | `term_damage_margins` (2542) | `term_damage_margins` (865) | ported |
| terminal | `term_damage_color` (2548) | `term_damage_color` (882) | ported |
| terminal | `term_damage_scroll` (2638) | `term_damage_scroll` (960) | ported |
| terminal | `term_erase` (2666) | `term_erase` (1457) | ported |
| terminal | `term_erase_scrollback` (2695) | `term_erase_scrollback` (2399) | ported |
| terminal | `term_row_rel_to_abs` (2909) | `term_row_rel_to_abs` (1069) | ported |
| terminal | `term_cursor_to` (2924) | `term_cursor_to` (726) | ported |
| terminal | `term_cursor_home` (2940) | `term_cursor_home` (743) | ported |
| terminal | `term_cursor_col` (2946) | `term_cursor_col` (747) | ported |
| terminal | `term_cursor_left` (2956) | `term_cursor_left` (755) | ported |
| terminal | `term_cursor_right` (2966) | `term_cursor_right` (763) | ported |
| terminal | `term_cursor_up` (2976) | `term_cursor_up` (774) | ported |
| terminal | `term_cursor_down` (2986) | `term_cursor_down` (790) | ported |
| terminal | `cursor_blink_rearm_timer` (2996) | `cursor_blink_rearm_timer` (1204) | ported |
| terminal | `cursor_blink_disarm_timer` (3033) | `cursor_blink_disarm_timer` (1233) | ported |
| terminal | `term_cursor_blink_update` (3041) | `term_cursor_blink_update` (1239) | ported |
| terminal | `selection_on_top_region` (3059) | `selection_on_top_region` (1282) | ported |
| terminal | `selection_on_bottom_region` (3067) | `selection_on_bottom_region` (1286) | ported |
| terminal | `term_scroll_partial` (3075) | `term_scroll_partial` (1294) | ported |
| terminal | `term_scroll` (3142) | `term_scroll` (1346) | ported |
| terminal | `term_scroll_reverse_partial` (3148) | `term_scroll_reverse_partial` (1350) | ported |
| terminal | `term_scroll_reverse` (3239) | `term_scroll_reverse` (1420) | ported |
| terminal | `term_carriage_return` (3245) | `term_carriage_return` (988) | ported |
| terminal | `term_linefeed` (3251) | `term_linefeed` (1424) | ported |
| terminal | `term_reverse_index` (3264) | `term_reverse_index` (1436) | ported |
| terminal | `term_reset_view` (3273) | `term_reset_view` (992) | ported |
| terminal | `term_save_cursor` (3283) | `term_save_cursor` (1000) | ported |
| terminal | `term_restore_cursor` (3291) | `term_restore_cursor` (1025) | ported |
| terminal | `term_visual_focus_in` (3308) | `term_visual_focus_in` (1006) | ported |
| terminal | `term_visual_focus_out` (3319) | `term_visual_focus_out` (1015) | ported |
| terminal | `term_send_visibility_report` (3330) | `term_send_visibility_report` (2696) | ported |
| terminal | `term_kbd_focus_in` (3338) | `term_kbd_focus_in` (3461) | ported |
| terminal | `term_kbd_focus_out` (3357) | `term_kbd_focus_out` (4102) | ported |
| terminal | `linux_mouse_button_to_x` (3379) | `linuxMouseButtonToX` (3106) | ported |
| terminal | `encode_xbutton` (3406) | `encodeXbutton` (3126) | ported |
| terminal | `report_mouse_click` (3427) | `reportMouseClick` (3140) | ported |
| terminal | `report_mouse_motion` (3471) | `reportMouseMotion` (3197) | ported |
| terminal | `term_mouse_grabbed` (3477) | `term_mouse_grabbed` (3688) | ported |
| terminal | `term_mouse_down` (3498) | `term_mouse_down` (3216) | ported |
| terminal | `term_mouse_up` (3537) | `term_mouse_up` (3258) | ported |
| terminal | `term_mouse_motion` (3580) | `term_mouse_motion` (3304) | ported |
| terminal | `term_xcursor_update_for_seat` (3628) | `term_xcursor_update_for_seat` (3809) | ported |
| terminal | `term_xcursor_update` (3678) | `term_xcursor_update` (3851) | ported |
| terminal | `term_set_window_title` (3685) | `term_set_window_title` (2927) | ported |
| terminal | `term_set_app_id` (3707) | `term_set_app_id` (2948) | ported |
| terminal | `term_icon` (3747) | `term_icon` (2988) | ported |
| terminal | `term_flash` (3764) | `term_flash` (2742) | ported |
| terminal | `term_bell` (3780) | `term_bell` (3420) | ported |
| terminal | `term_spawn_new` (3826) | `term_spawn_new` (2994) | ported |
| terminal | `term_enable_app_sync_updates` (3842) | `term_enable_app_sync_updates` (2856) | ported |
| terminal | `term_disable_app_sync_updates` (3873) | `term_disable_app_sync_updates` (2886) | ported |
| terminal | `print_linewrap` (3888) | `print_linewrap` (3356) | ported |
| terminal | `print_insert` (3917) | `print_insert` (3381) | ported |
| terminal | `print_spacer` (3938) | `print_spacer` (1487) | ported |
| terminal | `term_fill` (3961) | `term_fill` (1496) | ported |
| terminal | `term_print` (4015) | `term_print` (1560) | ported |
| terminal | `ascii_printer_generic` (4114) | `ascii_printer_generic` (1655) | ported |
| terminal | `ascii_printer_fast` (4120) | `ascii_printer_fast` (1659) | ported |
| terminal | `ascii_printer_single_shift` (4162) | `ascii_printer_single_shift` (1692) | ported |
| terminal | `term_update_ascii_printer` (4173) | `term_update_ascii_printer` (1701) | ported |
| terminal | `term_single_shift` (4194) | `term_single_shift` (1710) | ported |
| terminal | `emoji_vs_compare` (4203) | `—` | exception |
| terminal | `term_process_and_print_non_ascii` (4234) | `term_process_and_print_non_ascii` (1769) | ported |
| terminal | `term_surface_kind` (4460) | `term_surface_kind` (4122) | ported |
| terminal | `rows_to_text` (4485) | `rowsToText` (2493) | ported |
| terminal | `term_scrollback_to_text` (4520) | `term_scrollback_to_text` (2536) | ported |
| terminal | `term_view_to_text` (4548) | `term_view_to_text` (2567) | ported |
| terminal | `term_command_output_to_text` (4556) | `term_command_output_to_text` (2577) | ported |
| terminal | `term_ime_is_enabled` (4640) | `term_ime_is_enabled` (3565) | ported |
| terminal | `term_ime_enable` (4650) | `term_ime_enable` (3569) | ported |
| terminal | `term_ime_disable` (4669) | `term_ime_disable` (3591) | ported |
| terminal | `term_ime_reset` (4688) | `term_ime_reset` (3613) | ported |
| terminal | `term_ime_set_cursor_rect` (4708) | `term_ime_set_cursor_rect` (3628) | ported |
| terminal | `term_osc8_open` (4724) | `term_osc8_open` (2662) | ported |
| terminal | `term_osc8_close` (4737) | `term_osc8_close` (2673) | ported |
| terminal | `term_set_user_mouse_cursor` (4747) | `term_set_user_mouse_cursor` (2683) | ported |
| terminal | `term_enable_size_notifications` (4757) | `term_enable_size_notifications` (2706) | ported |
| terminal | `term_disable_size_notifications` (4766) | `term_disable_size_notifications` (2713) | ported |
| terminal | `term_send_size_notification` (4775) | `term_send_size_notification` (2720) | ported |
| terminal | `term_theme_switch_to_dark` (4791) | `term_theme_switch_to_dark` (3057) | ported |
| terminal | `term_theme_switch_to_light` (4811) | `term_theme_switch_to_light` (3064) | ported |
| terminal | `term_theme_toggle` (4831) | `term_theme_toggle` (3071) | ported |
| terminal | `term_theme_get` (4856) | `term_theme_get` (3078) | ported |
| grid | `grid_row_abs_to_sb` (34) | `grid_row_abs_to_sb` (1922) | ported |
| grid | `grid_row_sb_to_abs` (44) | `grid_row_sb_to_abs` (1926) | ported |
| grid | `grid_sb_start_ignore_uninitialized` (54) | `grid_sb_start_ignore_uninitialized` (1930) | ported |
| grid | `grid_row_abs_to_sb_precalc_sb_start` (68) | `grid_row_abs_to_sb_precalc_sb_start` (1934) | ported |
| grid | `grid_row_sb_to_abs_precalc_sb_start` (77) | `grid_row_sb_to_abs_precalc_sb_start` (1938) | ported |
| grid | `ensure_row_has_extra_data` (86) | `ensureRowHasExtraData` (441) | ported |
| grid | `verify_no_overlapping_ranges_of_type` (93) | `—` | exception |
| grid | `verify_no_overlapping_ranges` (126) | `—` | exception |
| grid | `verify_ranges_of_type_are_sorted` (133) | `—` | exception |
| grid | `verify_ranges_are_sorted` (167) | `—` | exception |
| grid | `range_ensure_size` (174) | `rangeEnsureSize` (151) | ported |
| grid | `range_insert` (189) | `rangeInsert` (167) | ported |
| grid | `range_append_by_ref` (220) | `rangeAppendByRef` (209) | ported |
| grid | `range_append` (243) | `rangeAppend` (236) | ported |
| grid | `range_delete` (261) | `rangeDelete` (259) | ported |
| grid | `grid_snapshot` (274) | `grid_snapshot` (1942) | ported |
| grid | `grid_free` (404) | `grid_free` (1946) | ported |
| grid | `grid_swap_row` (422) | `grid_swap_row` (1950) | ported |
| grid | `grid_row_alloc` (438) | `grid_row_alloc` (1954) | ported |
| grid | `grid_row_free` (459) | `grid_row_free` (1958) | ported |
| grid | `grid_resize_without_reflow` (471) | `grid_resize_without_reflow` (1962) | ported |
| grid | `reflow_range_start` (641) | `reflowRangeStart` (1093) | ported |
| grid | `reflow_range_end` (664) | `reflowRangeEnd` (1114) | ported |
| grid | `_line_wrap` (699) | `lineWrap` (1142) | ported |
| grid | `tp_cmp` (783) | `tpCmp` (1206) | ported |
| grid | `grid_resize_and_reflow` (816) | `grid_resize_and_reflow` (1975) | ported |
| grid | `ranges_match` (1300) | `rangesMatch` (285) | ported |
| grid | `range_match_data` (1319) | `rangeMatchData` (298) | ported |
| grid | `grid_row_range_put` (1337) | `grid_row_range_put` (1997) | ported |
| grid | `grid_row_uri_range_put` (1444) | `grid_row_uri_range_put` (2006) | ported |
| grid | `grid_row_underline_range_put` (1458) | `grid_row_underline_range_put` (2010) | ported |
| grid | `grid_row_range_erase` (1537) | `grid_row_range_erase` (2014) | ported |
| grid | `grid_row_uri_range_erase` (1591) | `grid_row_uri_range_erase` (2023) | ported |
| grid | `grid_row_underline_range_erase` (1598) | `grid_row_underline_range_erase` (2027) | ported |
| composed | `composed_key_from_chars` (10) | `composed_key_from_chars` (32) | ported |
| composed | `composed_key_from_key` (23) | `composed_key_from_key` (18) | ported |
| composed | `composed_lookup` (55) | `composed_lookup` (44) | ported |
| composed | `composed_lookup_without_collision` (70) | `composed_lookup_without_collision` (55) | ported |
| composed | `composed_insert` (105) | `composed_insert` (88) | ported |
| composed | `composed_free` (139) | `composed_free` (116) | ported |
| extract | `extract_begin` (24) | `extract_begin` (64) | ported |
| extract | `ensure_size` (40) | `ensureSize` (33) | ported |
| extract | `extract_finish_wide` (58) | `extract_finish_wide` (76) | ported |
| extract | `extract_finish` (127) | `extract_finish` (147) | ported |
| extract | `extract_one` (156) | `extract_one` (166) | ported |
| search | `ensure_view_is_allocated` (39) | `ensureViewIsAllocated` (128) | ported |
| search | `search_ensure_size` (67) | `searchEnsureSize` (157) | ported |
| search | `has_wrapped_around_left` (86) | `hasWrappedAroundLeft` (175) | ported |
| search | `has_wrapped_around_right` (93) | `hasWrappedAroundRight` (181) | ported |
| search | `search_cancel_keep_selection` (100) | `searchCancelKeepSelection` (679) | ported |
| search | `search_begin` (132) | `search_begin` (707) | ported |
| search | `search_cancel` (165) | `search_cancel` (733) | ported |
| search | `search_selection_cancelled` (175) | `search_selection_cancelled` (741) | ported |
| search | `search_update_selection` (183) | `searchUpdateSelection` (354) | ported |
| search | `matches_cell` (270) | `matchesCell` (186) | ported |
| search | `find_next` (308) | `findNext` (224) | ported |
| search | `search_find_next` (428) | `search_find_next` (422) | ported |
| search | `search_matches_new_iter` (539) | `search_matches_new_iter` (541) | ported |
| search | `search_matches_next` (548) | `search_matches_next` (548) | ported |
| search | `add_wchars` (623) | `addWchars` (606) | ported |
| search | `search_add_chars` (650) | `search_add_chars` (641) | ported |
| search | `coord_advance_left` (666) | `coordAdvanceLeft` (751) | ported |
| search | `coord_advance_right` (688) | `coordAdvanceRight` (771) | ported |
| search | `search_extend_find_char` (710) | `searchExtendFindChar` (791) | ported |
| search | `search_extend_find_char_left` (749) | `searchExtendFindCharLeft` (826) | ported |
| search | `search_extend_find_char_right` (755) | `searchExtendFindCharRight` (830) | ported |
| search | `search_extend_find_word` (761) | `searchExtendFindWord` (834) | ported |
| search | `search_extend_find_word_left` (810) | `searchExtendFindWordLeft` (874) | ported |
| search | `search_extend_find_word_right` (817) | `searchExtendFindWordRight` (878) | ported |
| search | `search_extend_find_line` (824) | `searchExtendFindLine` (882) | ported |
| search | `search_extend_find_line_up` (859) | `searchExtendFindLineUp` (919) | ported |
| search | `search_extend_find_line_down` (865) | `searchExtendFindLineDown` (923) | ported |
| search | `search_extend_left` (871) | `searchExtendLeft` (927) | ported |
| search | `search_extend_right` (936) | `searchExtendRight` (996) | ported |
| search | `distance_next_word` (987) | `distanceNextWord` (1048) | ported |
| search | `distance_prev_word` (1015) | `distancePrevWord` (1079) | ported |
| search | `from_clipboard_cb` (1041) | `fromClipboardCb` (1190) | ported |
| search | `from_clipboard_done` (1048) | `fromClipboardDone` (1194) | ported |
| search | `execute_binding` (1058) | `executeBinding` (1201) | ported |
| search | `search_input` (1402) | `search_input` (1550) | ported |
| char32 | `mbsntoc32` (164) | `mbsntoc32` (15) | ported |
| char32 | `ambstoc32` (277) | `ambstoc32` (52) | ported |
| char32 | `ac32tombs` (360) | `ac32tombs` (93) | ported |
| tokenize | `push_argv` (12) | `push_argv` (11) | ported |
| tokenize | `tokenize_cmdline` (33) | `tokenize_cmdline` (39) | ported |
| unicode-mode | `unicode_mode_activate` (10) | `unicode_mode_activate` (66) | ported |
| unicode-mode | `unicode_mode_deactivate` (22) | `unicode_mode_deactivate` (76) | ported |
| unicode-mode | `unicode_mode_updated` (32) | `unicode_mode_updated` (84) | ported |
| unicode-mode | `unicode_mode_input` (44) | `unicode_mode_input` (93) | ported |
| box-drawing | `change_buffer_format` (46) | `box_change_buffer_format` (78) | ported |
| box-drawing | `_thickness` (69) | `box_thickness` (68) | ported |
| box-drawing | `_hline` (82) | `hline` (220) | ported |
| box-drawing | `_vline` (96) | `vline` (224) | ported |
| box-drawing | `_rect` (110) | `rect` (228) | ported |
| box-drawing | `_hline_middle` (124) | `box_hline_middle` (163) | ported |
| box-drawing | `_hline_middle_left` (131) | `box_hline_middle_left` (168) | ported |
| box-drawing | `_hline_middle_right` (139) | `box_hline_middle_right` (178) | ported |
| box-drawing | `_vline_middle` (147) | `box_vline_middle` (188) | ported |
| box-drawing | `_vline_middle_up` (154) | `box_vline_middle_up` (193) | ported |
| box-drawing | `_vline_middle_down` (162) | `box_vline_middle_down` (203) | ported |
| box-drawing | `draw_box_drawings_light_horizontal` (181) | `draw_box_drawings_light_horizontal` (432) | ported |
| box-drawing | `draw_box_drawings_heavy_horizontal` (187) | `draw_box_drawings_heavy_horizontal` (436) | ported |
| box-drawing | `draw_box_drawings_light_vertical` (193) | `draw_box_drawings_light_vertical` (440) | ported |
| box-drawing | `draw_box_drawings_heavy_vertical` (199) | `draw_box_drawings_heavy_vertical` (444) | ported |
| box-drawing | `draw_box_drawings_dash_horizontal` (205) | `draw_box_drawings_dash_horizontal` (275) | ported |
| box-drawing | `draw_box_drawings_dash_vertical` (263) | `draw_box_drawings_dash_vertical` (338) | ported |
| box-drawing | `draw_box_drawings_light_triple_dash_horizontal` (321) | `draw_box_drawings_light_triple_dash_horizontal` (400) | ported |
| box-drawing | `draw_box_drawings_heavy_triple_dash_horizontal` (327) | `draw_box_drawings_heavy_triple_dash_horizontal` (404) | ported |
| box-drawing | `draw_box_drawings_light_triple_dash_vertical` (333) | `draw_box_drawings_light_triple_dash_vertical` (408) | ported |
| box-drawing | `draw_box_drawings_heavy_triple_dash_vertical` (339) | `draw_box_drawings_heavy_triple_dash_vertical` (412) | ported |
| box-drawing | `draw_box_drawings_light_quadruple_dash_horizontal` (345) | `draw_box_drawings_light_quadruple_dash_horizontal` (416) | ported |
| box-drawing | `draw_box_drawings_heavy_quadruple_dash_horizontal` (351) | `draw_box_drawings_heavy_quadruple_dash_horizontal` (420) | ported |
| box-drawing | `draw_box_drawings_light_quadruple_dash_vertical` (357) | `draw_box_drawings_light_quadruple_dash_vertical` (424) | ported |
| box-drawing | `draw_box_drawings_heavy_quadruple_dash_vertical` (363) | `draw_box_drawings_heavy_quadruple_dash_vertical` (428) | ported |
| box-drawing | `draw_box_drawings_light_down_and_right` (369) | `draw_box_drawings_light_down_and_right` (448) | ported |
| box-drawing | `draw_box_drawings_down_light_and_right_heavy` (376) | `draw_box_drawings_down_light_and_right_heavy` (453) | ported |
| box-drawing | `draw_box_drawings_down_heavy_and_right_light` (383) | `draw_box_drawings_down_heavy_and_right_light` (458) | ported |
| box-drawing | `draw_box_drawings_heavy_down_and_right` (390) | `draw_box_drawings_heavy_down_and_right` (463) | ported |
| box-drawing | `draw_box_drawings_light_down_and_left` (397) | `draw_box_drawings_light_down_and_left` (468) | ported |
| box-drawing | `draw_box_drawings_down_light_and_left_heavy` (404) | `draw_box_drawings_down_light_and_left_heavy` (473) | ported |
| box-drawing | `draw_box_drawings_down_heavy_and_left_light` (411) | `draw_box_drawings_down_heavy_and_left_light` (478) | ported |
| box-drawing | `draw_box_drawings_heavy_down_and_left` (418) | `draw_box_drawings_heavy_down_and_left` (483) | ported |
| box-drawing | `draw_box_drawings_light_up_and_right` (425) | `draw_box_drawings_light_up_and_right` (488) | ported |
| box-drawing | `draw_box_drawings_up_light_and_right_heavy` (432) | `draw_box_drawings_up_light_and_right_heavy` (493) | ported |
| box-drawing | `draw_box_drawings_up_heavy_and_right_light` (439) | `draw_box_drawings_up_heavy_and_right_light` (498) | ported |
| box-drawing | `draw_box_drawings_heavy_up_and_right` (446) | `draw_box_drawings_heavy_up_and_right` (503) | ported |
| box-drawing | `draw_box_drawings_light_up_and_left` (453) | `draw_box_drawings_light_up_and_left` (508) | ported |
| box-drawing | `draw_box_drawings_up_light_and_left_heavy` (460) | `draw_box_drawings_up_light_and_left_heavy` (513) | ported |
| box-drawing | `draw_box_drawings_up_heavy_and_left_light` (467) | `draw_box_drawings_up_heavy_and_left_light` (518) | ported |
| box-drawing | `draw_box_drawings_heavy_up_and_left` (474) | `draw_box_drawings_heavy_up_and_left` (523) | ported |
| box-drawing | `draw_box_drawings_light_vertical_and_right` (481) | `draw_box_drawings_light_vertical_and_right` (528) | ported |
| box-drawing | `draw_box_drawings_vertical_light_and_right_heavy` (488) | `draw_box_drawings_vertical_light_and_right_heavy` (533) | ported |
| box-drawing | `draw_box_drawings_up_heavy_and_right_down_light` (495) | `draw_box_drawings_up_heavy_and_right_down_light` (538) | ported |
| box-drawing | `draw_box_drawings_down_heavy_and_right_up_light` (503) | `draw_box_drawings_down_heavy_and_right_up_light` (544) | ported |
| box-drawing | `draw_box_drawings_vertical_heavy_and_right_light` (511) | `draw_box_drawings_vertical_heavy_and_right_light` (550) | ported |
| box-drawing | `draw_box_drawings_down_light_and_right_up_heavy` (518) | `draw_box_drawings_down_light_and_right_up_heavy` (555) | ported |
| box-drawing | `draw_box_drawings_up_light_and_right_down_heavy` (526) | `draw_box_drawings_up_light_and_right_down_heavy` (561) | ported |
| box-drawing | `draw_box_drawings_heavy_vertical_and_right` (534) | `draw_box_drawings_heavy_vertical_and_right` (567) | ported |
| box-drawing | `draw_box_drawings_light_vertical_and_left` (541) | `draw_box_drawings_light_vertical_and_left` (572) | ported |
| box-drawing | `draw_box_drawings_vertical_light_and_left_heavy` (548) | `draw_box_drawings_vertical_light_and_left_heavy` (577) | ported |
| box-drawing | `draw_box_drawings_up_heavy_and_left_down_light` (555) | `draw_box_drawings_up_heavy_and_left_down_light` (582) | ported |
| box-drawing | `draw_box_drawings_down_heavy_and_left_up_light` (563) | `draw_box_drawings_down_heavy_and_left_up_light` (588) | ported |
| box-drawing | `draw_box_drawings_vertical_heavy_and_left_light` (571) | `draw_box_drawings_vertical_heavy_and_left_light` (594) | ported |
| box-drawing | `draw_box_drawings_down_light_and_left_up_heavy` (578) | `draw_box_drawings_down_light_and_left_up_heavy` (599) | ported |
| box-drawing | `draw_box_drawings_up_light_and_left_down_heavy` (586) | `draw_box_drawings_up_light_and_left_down_heavy` (605) | ported |
| box-drawing | `draw_box_drawings_heavy_vertical_and_left` (594) | `draw_box_drawings_heavy_vertical_and_left` (611) | ported |
| box-drawing | `draw_box_drawings_light_down_and_horizontal` (601) | `draw_box_drawings_light_down_and_horizontal` (616) | ported |
| box-drawing | `draw_box_drawings_left_heavy_and_right_down_light` (608) | `draw_box_drawings_left_heavy_and_right_down_light` (621) | ported |
| box-drawing | `draw_box_drawings_right_heavy_and_left_down_light` (616) | `draw_box_drawings_right_heavy_and_left_down_light` (627) | ported |
| box-drawing | `draw_box_drawings_down_light_and_horizontal_heavy` (624) | `draw_box_drawings_down_light_and_horizontal_heavy` (633) | ported |
| box-drawing | `draw_box_drawings_down_heavy_and_horizontal_light` (631) | `draw_box_drawings_down_heavy_and_horizontal_light` (638) | ported |
| box-drawing | `draw_box_drawings_right_light_and_left_down_heavy` (638) | `draw_box_drawings_right_light_and_left_down_heavy` (643) | ported |
| box-drawing | `draw_box_drawings_left_light_and_right_down_heavy` (646) | `draw_box_drawings_left_light_and_right_down_heavy` (649) | ported |
| box-drawing | `draw_box_drawings_heavy_down_and_horizontal` (654) | `draw_box_drawings_heavy_down_and_horizontal` (655) | ported |
| box-drawing | `draw_box_drawings_light_up_and_horizontal` (661) | `draw_box_drawings_light_up_and_horizontal` (660) | ported |
| box-drawing | `draw_box_drawings_left_heavy_and_right_up_light` (668) | `draw_box_drawings_left_heavy_and_right_up_light` (665) | ported |
| box-drawing | `draw_box_drawings_right_heavy_and_left_up_light` (676) | `draw_box_drawings_right_heavy_and_left_up_light` (671) | ported |
| box-drawing | `draw_box_drawings_up_light_and_horizontal_heavy` (684) | `draw_box_drawings_up_light_and_horizontal_heavy` (677) | ported |
| box-drawing | `draw_box_drawings_up_heavy_and_horizontal_light` (691) | `draw_box_drawings_up_heavy_and_horizontal_light` (682) | ported |
| box-drawing | `draw_box_drawings_right_light_and_left_up_heavy` (698) | `draw_box_drawings_right_light_and_left_up_heavy` (687) | ported |
| box-drawing | `draw_box_drawings_left_light_and_right_up_heavy` (706) | `draw_box_drawings_left_light_and_right_up_heavy` (693) | ported |
| box-drawing | `draw_box_drawings_heavy_up_and_horizontal` (714) | `draw_box_drawings_heavy_up_and_horizontal` (699) | ported |
| box-drawing | `draw_box_drawings_light_vertical_and_horizontal` (721) | `draw_box_drawings_light_vertical_and_horizontal` (704) | ported |
| box-drawing | `draw_box_drawings_left_heavy_and_right_vertical_light` (728) | `draw_box_drawings_left_heavy_and_right_vertical_light` (709) | ported |
| box-drawing | `draw_box_drawings_right_heavy_and_left_vertical_light` (736) | `draw_box_drawings_right_heavy_and_left_vertical_light` (715) | ported |
| box-drawing | `draw_box_drawings_vertical_light_and_horizontal_heavy` (744) | `draw_box_drawings_vertical_light_and_horizontal_heavy` (721) | ported |
| box-drawing | `draw_box_drawings_up_heavy_and_down_horizontal_light` (751) | `draw_box_drawings_up_heavy_and_down_horizontal_light` (726) | ported |
| box-drawing | `draw_box_drawings_down_heavy_and_up_horizontal_light` (759) | `draw_box_drawings_down_heavy_and_up_horizontal_light` (732) | ported |
| box-drawing | `draw_box_drawings_vertical_heavy_and_horizontal_light` (767) | `draw_box_drawings_vertical_heavy_and_horizontal_light` (738) | ported |
| box-drawing | `draw_box_drawings_left_up_heavy_and_right_down_light` (774) | `draw_box_drawings_left_up_heavy_and_right_down_light` (743) | ported |
| box-drawing | `draw_box_drawings_right_up_heavy_and_left_down_light` (783) | `draw_box_drawings_right_up_heavy_and_left_down_light` (750) | ported |
| box-drawing | `draw_box_drawings_left_down_heavy_and_right_up_light` (792) | `draw_box_drawings_left_down_heavy_and_right_up_light` (757) | ported |
| box-drawing | `draw_box_drawings_right_down_heavy_and_left_up_light` (801) | `draw_box_drawings_right_down_heavy_and_left_up_light` (764) | ported |
| box-drawing | `draw_box_drawings_down_light_and_up_horizontal_heavy` (810) | `draw_box_drawings_down_light_and_up_horizontal_heavy` (771) | ported |
| box-drawing | `draw_box_drawings_up_light_and_down_horizontal_heavy` (818) | `draw_box_drawings_up_light_and_down_horizontal_heavy` (777) | ported |
| box-drawing | `draw_box_drawings_right_light_and_left_vertical_heavy` (826) | `draw_box_drawings_right_light_and_left_vertical_heavy` (783) | ported |
| box-drawing | `draw_box_drawings_left_light_and_right_vertical_heavy` (834) | `draw_box_drawings_left_light_and_right_vertical_heavy` (789) | ported |
| box-drawing | `draw_box_drawings_heavy_vertical_and_horizontal` (842) | `draw_box_drawings_heavy_vertical_and_horizontal` (795) | ported |
| box-drawing | `draw_box_drawings_light_double_dash_horizontal` (849) | `draw_box_drawings_light_double_dash_horizontal` (806) | ported |
| box-drawing | `draw_box_drawings_heavy_double_dash_horizontal` (855) | `draw_box_drawings_heavy_double_dash_horizontal` (810) | ported |
| box-drawing | `draw_box_drawings_light_double_dash_vertical` (861) | `draw_box_drawings_light_double_dash_vertical` (814) | ported |
| box-drawing | `draw_box_drawings_heavy_double_dash_vertical` (867) | `draw_box_drawings_heavy_double_dash_vertical` (818) | ported |
| box-drawing | `draw_box_drawings_double_horizontal` (873) | `draw_box_drawings_double_horizontal` (822) | ported |
| box-drawing | `draw_box_drawings_double_vertical` (883) | `draw_box_drawings_double_vertical` (829) | ported |
| box-drawing | `draw_box_drawings_down_single_and_right_double` (893) | `draw_box_drawings_down_single_and_right_double` (836) | ported |
| box-drawing | `draw_box_drawings_down_double_and_right_single` (906) | `draw_box_drawings_down_double_and_right_single` (845) | ported |
| box-drawing | `draw_box_drawings_double_down_and_right` (919) | `draw_box_drawings_double_down_and_right` (854) | ported |
| box-drawing | `draw_box_drawings_down_single_and_left_double` (933) | `draw_box_drawings_down_single_and_left_double` (864) | ported |
| box-drawing | `draw_box_drawings_down_double_and_left_single` (946) | `draw_box_drawings_down_double_and_left_single` (873) | ported |
| box-drawing | `draw_box_drawings_double_down_and_left` (959) | `draw_box_drawings_double_down_and_left` (882) | ported |
| box-drawing | `draw_box_drawings_up_single_and_right_double` (973) | `draw_box_drawings_up_single_and_right_double` (892) | ported |
| box-drawing | `draw_box_drawings_up_double_and_right_single` (986) | `draw_box_drawings_up_double_and_right_single` (901) | ported |
| box-drawing | `draw_box_drawings_double_up_and_right` (999) | `draw_box_drawings_double_up_and_right` (910) | ported |
| box-drawing | `draw_box_drawings_up_single_and_left_double` (1013) | `draw_box_drawings_up_single_and_left_double` (920) | ported |
| box-drawing | `draw_box_drawings_up_double_and_left_single` (1026) | `draw_box_drawings_up_double_and_left_single` (929) | ported |
| box-drawing | `draw_box_drawings_double_up_and_left` (1039) | `draw_box_drawings_double_up_and_left` (938) | ported |
| box-drawing | `draw_box_drawings_vertical_single_and_right_double` (1053) | `draw_box_drawings_vertical_single_and_right_double` (948) | ported |
| box-drawing | `draw_box_drawings_vertical_double_and_right_single` (1066) | `draw_box_drawings_vertical_double_and_right_single` (957) | ported |
| box-drawing | `draw_box_drawings_double_vertical_and_right` (1078) | `draw_box_drawings_double_vertical_and_right` (965) | ported |
| box-drawing | `draw_box_drawings_vertical_single_and_left_double` (1093) | `draw_box_drawings_vertical_single_and_left_double` (976) | ported |
| box-drawing | `draw_box_drawings_vertical_double_and_left_single` (1106) | `draw_box_drawings_vertical_double_and_left_single` (985) | ported |
| box-drawing | `draw_box_drawings_double_vertical_and_left` (1118) | `draw_box_drawings_double_vertical_and_left` (993) | ported |
| box-drawing | `draw_box_drawings_down_single_and_horizontal_double` (1133) | `draw_box_drawings_down_single_and_horizontal_double` (1004) | ported |
| box-drawing | `draw_box_drawings_down_double_and_horizontal_single` (1145) | `draw_box_drawings_down_double_and_horizontal_single` (1012) | ported |
| box-drawing | `draw_box_drawings_double_down_and_horizontal` (1158) | `draw_box_drawings_double_down_and_horizontal` (1021) | ported |
| box-drawing | `draw_box_drawings_up_single_and_horizontal_double` (1173) | `draw_box_drawings_up_single_and_horizontal_double` (1032) | ported |
| box-drawing | `draw_box_drawings_up_double_and_horizontal_single` (1186) | `draw_box_drawings_up_double_and_horizontal_single` (1041) | ported |
| box-drawing | `draw_box_drawings_double_up_and_horizontal` (1199) | `draw_box_drawings_double_up_and_horizontal` (1050) | ported |
| box-drawing | `draw_box_drawings_vertical_single_and_horizontal_double` (1214) | `draw_box_drawings_vertical_single_and_horizontal_double` (1061) | ported |
| box-drawing | `draw_box_drawings_vertical_double_and_horizontal_single` (1226) | `draw_box_drawings_vertical_double_and_horizontal_single` (1069) | ported |
| box-drawing | `draw_box_drawings_double_vertical_and_horizontal` (1238) | `draw_box_drawings_double_vertical_and_horizontal` (1077) | ported |
| box-drawing | `set_a1_bit` (1256) | `setA1Bit` (1409) | ported |
| box-drawing | `draw_box_drawings_light_arc` (1266) | `draw_box_drawings_light_arc` (2799) | ported |
| box-drawing | `draw_box_drawings_light_diagonal_upper_right_to_lower_left` (1548) | `draw_box_drawings_light_diagonal_upper_right_to_lower_left` (2239) | ported |
| box-drawing | `draw_box_drawings_light_diagonal_upper_left_to_lower_right` (1579) | `draw_box_drawings_light_diagonal_upper_left_to_lower_right` (2268) | ported |
| box-drawing | `draw_box_drawings_light_diagonal_cross` (1610) | `draw_box_drawings_light_diagonal_cross` (2297) | ported |
| box-drawing | `draw_box_drawings_light_left` (1617) | `draw_box_drawings_light_left` (1321) | ported |
| box-drawing | `draw_box_drawings_light_up` (1623) | `draw_box_drawings_light_up` (1325) | ported |
| box-drawing | `draw_box_drawings_light_right` (1629) | `draw_box_drawings_light_right` (1329) | ported |
| box-drawing | `draw_box_drawings_light_down` (1635) | `draw_box_drawings_light_down` (1333) | ported |
| box-drawing | `draw_box_drawings_heavy_left` (1641) | `draw_box_drawings_heavy_left` (1337) | ported |
| box-drawing | `draw_box_drawings_heavy_up` (1647) | `draw_box_drawings_heavy_up` (1341) | ported |
| box-drawing | `draw_box_drawings_heavy_right` (1653) | `draw_box_drawings_heavy_right` (1345) | ported |
| box-drawing | `draw_box_drawings_heavy_down` (1659) | `draw_box_drawings_heavy_down` (1349) | ported |
| box-drawing | `draw_box_drawings_light_left_and_heavy_right` (1665) | `draw_box_drawings_light_left_and_heavy_right` (1353) | ported |
| box-drawing | `draw_box_drawings_light_up_and_heavy_down` (1672) | `draw_box_drawings_light_up_and_heavy_down` (1358) | ported |
| box-drawing | `draw_box_drawings_heavy_left_and_light_right` (1679) | `draw_box_drawings_heavy_left_and_light_right` (1363) | ported |
| box-drawing | `draw_box_drawings_heavy_up_and_light_down` (1686) | `draw_box_drawings_heavy_up_and_light_down` (1368) | ported |
| box-drawing | `draw_upper_half_block` (1693) | `draw_upper_half_block` (1113) | ported |
| box-drawing | `draw_lower_one_eighth_block` (1699) | `draw_lower_one_eighth_block` (1117) | ported |
| box-drawing | `draw_lower_one_quarter_block` (1705) | `draw_lower_one_quarter_block` (1121) | ported |
| box-drawing | `draw_lower_three_eighths_block` (1711) | `draw_lower_three_eighths_block` (1125) | ported |
| box-drawing | `draw_lower_half_block` (1717) | `draw_lower_half_block` (1129) | ported |
| box-drawing | `draw_lower_five_eighths_block` (1723) | `draw_lower_five_eighths_block` (1133) | ported |
| box-drawing | `draw_lower_three_quarters_block` (1729) | `draw_lower_three_quarters_block` (1137) | ported |
| box-drawing | `draw_lower_seven_eighths_block` (1735) | `draw_lower_seven_eighths_block` (1141) | ported |
| box-drawing | `draw_upper_one_quarter_block` (1741) | `draw_upper_one_quarter_block` (1145) | ported |
| box-drawing | `draw_upper_three_eighths_block` (1747) | `draw_upper_three_eighths_block` (1149) | ported |
| box-drawing | `draw_upper_five_eighths_block` (1753) | `draw_upper_five_eighths_block` (1153) | ported |
| box-drawing | `draw_upper_three_quarters_block` (1759) | `draw_upper_three_quarters_block` (1157) | ported |
| box-drawing | `draw_upper_seven_eighths_block` (1765) | `draw_upper_seven_eighths_block` (1161) | ported |
| box-drawing | `draw_full_block` (1771) | `draw_full_block` (1165) | ported |
| box-drawing | `draw_left_seven_eighths_block` (1777) | `draw_left_seven_eighths_block` (1169) | ported |
| box-drawing | `draw_left_three_quarters_block` (1783) | `draw_left_three_quarters_block` (1173) | ported |
| box-drawing | `draw_left_five_eighths_block` (1789) | `draw_left_five_eighths_block` (1177) | ported |
| box-drawing | `draw_left_half_block` (1795) | `draw_left_half_block` (1181) | ported |
| box-drawing | `draw_left_three_eighths_block` (1801) | `draw_left_three_eighths_block` (1185) | ported |
| box-drawing | `draw_left_one_quarter_block` (1807) | `draw_left_one_quarter_block` (1189) | ported |
| box-drawing | `draw_vertical_one_eighth_block_n` (1813) | `draw_vertical_one_eighth_block_n` (1193) | ported |
| box-drawing | `draw_left_one_eighth_block` (1821) | `draw_left_one_eighth_block` (1199) | ported |
| box-drawing | `draw_vertical_one_eighth_block_2` (1827) | `draw_vertical_one_eighth_block_2` (1203) | ported |
| box-drawing | `draw_vertical_one_eighth_block_3` (1833) | `draw_vertical_one_eighth_block_3` (1207) | ported |
| box-drawing | `draw_vertical_one_eighth_block_4` (1839) | `draw_vertical_one_eighth_block_4` (1211) | ported |
| box-drawing | `draw_vertical_one_eighth_block_5` (1845) | `draw_vertical_one_eighth_block_5` (1215) | ported |
| box-drawing | `draw_vertical_one_eighth_block_6` (1851) | `draw_vertical_one_eighth_block_6` (1219) | ported |
| box-drawing | `draw_vertical_one_eighth_block_7` (1857) | `draw_vertical_one_eighth_block_7` (1223) | ported |
| box-drawing | `draw_right_half_block` (1863) | `draw_right_half_block` (1227) | ported |
| box-drawing | `draw_pixman_shade` (1869) | `drawPixmanShade` (1417) | ported |
| box-drawing | `draw_light_shade` (1878) | `draw_light_shade` (1439) | ported |
| box-drawing | `draw_medium_shade` (1901) | `draw_medium_shade` (1461) | ported |
| box-drawing | `draw_dark_shade` (1924) | `draw_dark_shade` (1483) | ported |
| box-drawing | `draw_horizontal_one_eighth_block_n` (1947) | `draw_horizontal_one_eighth_block_n` (1231) | ported |
| box-drawing | `draw_upper_one_eighth_block` (1955) | `draw_upper_one_eighth_block` (1237) | ported |
| box-drawing | `draw_horizontal_one_eighth_block_2` (1961) | `draw_horizontal_one_eighth_block_2` (1241) | ported |
| box-drawing | `draw_horizontal_one_eighth_block_3` (1967) | `draw_horizontal_one_eighth_block_3` (1245) | ported |
| box-drawing | `draw_horizontal_one_eighth_block_4` (1973) | `draw_horizontal_one_eighth_block_4` (1249) | ported |
| box-drawing | `draw_horizontal_one_eighth_block_5` (1979) | `draw_horizontal_one_eighth_block_5` (1253) | ported |
| box-drawing | `draw_horizontal_one_eighth_block_6` (1985) | `draw_horizontal_one_eighth_block_6` (1257) | ported |
| box-drawing | `draw_horizontal_one_eighth_block_7` (1991) | `draw_horizontal_one_eighth_block_7` (1261) | ported |
| box-drawing | `draw_right_one_eighth_block` (1997) | `draw_right_one_eighth_block` (1265) | ported |
| box-drawing | `quad_upper_left` (2003) | `quadUpperLeft` (1505) | ported |
| box-drawing | `quad_upper_right` (2009) | `quadUpperRight` (1509) | ported |
| box-drawing | `quad_lower_left` (2015) | `quadLowerLeft` (1513) | ported |
| box-drawing | `quad_lower_right` (2021) | `quadLowerRight` (1517) | ported |
| box-drawing | `draw_quadrant` (2027) | `draw_quadrant` (1521) | ported |
| box-drawing | `draw_braille` (2069) | `draw_braille` (1559) | ported |
| box-drawing | `sextant_upper_left` (2158) | `sextantUpperLeft` (1689) | ported |
| box-drawing | `sextant_middle_left` (2164) | `sextantMiddleLeft` (1693) | ported |
| box-drawing | `sextant_lower_left` (2170) | `sextantLowerLeft` (1697) | ported |
| box-drawing | `sextant_upper_right` (2176) | `sextantUpperRight` (1701) | ported |
| box-drawing | `sextant_middle_right` (2182) | `sextantMiddleRight` (1705) | ported |
| box-drawing | `sextant_lower_right` (2188) | `sextantLowerRight` (1709) | ported |
| box-drawing | `draw_sextant` (2194) | `draw_sextant` (1713) | ported |
| box-drawing | `octant_upper_left` (2313) | `octantUpperLeft` (1822) | ported |
| box-drawing | `octant_middle_up_left` (2319) | `octantMiddleUpLeft` (1826) | ported |
| box-drawing | `octant_middle_down_left` (2325) | `octantMiddleDownLeft` (1830) | ported |
| box-drawing | `octant_lower_left` (2331) | `octantLowerLeft` (1834) | ported |
| box-drawing | `octant_upper_right` (2337) | `octantUpperRight` (1838) | ported |
| box-drawing | `octant_middle_up_right` (2343) | `octantMiddleUpRight` (1842) | ported |
| box-drawing | `octant_middle_down_right` (2349) | `octantMiddleDownRight` (1846) | ported |
| box-drawing | `octant_lower_right` (2355) | `octantLowerRight` (1850) | ported |
| box-drawing | `draw_octant` (2361) | `draw_octant` (1854) | ported |
| box-drawing | `draw_wedge_triangle` (2705) | `draw_wedge_triangle` (2302) | ported |
| box-drawing | `draw_wedge_triangle_inverted` (2972) | `draw_wedge_triangle_inverted` (2740) | ported |
| box-drawing | `draw_wedge_triangle_and_box` (2982) | `draw_wedge_triangle_and_box` (2761) | ported |
| box-drawing | `draw_left_and_lower_one_eighth_block` (3013) | `draw_left_and_lower_one_eighth_block` (1269) | ported |
| box-drawing | `draw_left_and_upper_one_eighth_block` (3020) | `draw_left_and_upper_one_eighth_block` (1274) | ported |
| box-drawing | `draw_right_and_upper_one_eighth_block` (3027) | `draw_right_and_upper_one_eighth_block` (1279) | ported |
| box-drawing | `draw_right_and_lower_one_eighth_block` (3034) | `draw_right_and_lower_one_eighth_block` (1284) | ported |
| box-drawing | `draw_upper_and_lower_one_eighth_block` (3041) | `draw_upper_and_lower_one_eighth_block` (1289) | ported |
| box-drawing | `draw_horizontal_one_eighth_1358_block` (3048) | `draw_horizontal_one_eighth_1358_block` (1294) | ported |
| box-drawing | `draw_right_one_quarter_block` (3057) | `draw_right_one_quarter_block` (1301) | ported |
| box-drawing | `draw_right_three_eighths_block` (3063) | `draw_right_three_eighths_block` (1305) | ported |
| box-drawing | `draw_right_five_eighths_block` (3069) | `draw_right_five_eighths_block` (1309) | ported |
| box-drawing | `draw_right_three_quarters_block` (3075) | `draw_right_three_quarters_block` (1313) | ported |
| box-drawing | `draw_right_seven_eighths_block` (3081) | `draw_right_seven_eighths_block` (1317) | ported |
| box-drawing | `draw_glyph` (3087) | `drawGlyph` (3051) | ported |
| box-drawing | `box_drawing` (3326) | `box_drawing` (3247) | ported |
| hsl | `hsl_to_rgb` (6) | `hsl_to_rgb` (3) | ported |
| quirks | `is_weston` (13) | `isWeston` (35) | ported |
| quirks | `quirk_weston_subsurface_desync_on` (29) | `quirk_weston_subsurface_desync_on` (54) | ported |
| quirks | `quirk_weston_subsurface_desync_off` (38) | `quirk_weston_subsurface_desync_off` (61) | ported |
| quirks | `quirk_weston_csd_on` (47) | `quirk_weston_csd_on` (76) | ported |
| quirks | `quirk_weston_csd_off` (59) | `quirk_weston_csd_off` (87) | ported |
| quirks | `is_sway` (72) | `—` | exception |

## Shim table

Scope: functions in the six shims that the owned Zig modules call. `terminal-shim.c`
entries are limited to that call set; its render/wayland/selection-only
functions belong to other audits. Class per MIGRATION_PLAN §12.9: (a) keep —
C-only knowledge; (b) delete — struct-mirror accessor; (c) port, do not
delete — carries behaviour (body line count given).

| file | function | class | action | body lines |
|---|---|---|---|---|
| csi-shim.c | `csi_xtsave_get`, `csi_xtsave_set` | b | delete after `xtsave` bitfield mirror is pinned | 5, 7 |
| csi-shim.c | `csi_c32width` | a | keep (`#ifdef FOOT_GRAPHEME_CLUSTERING`, static inline) | 7 |
| csi-shim.c | `csi_window_first_output_px_width`, `..._height` | c | port the `tll_foreach`/first-output loop into `csi.zig` | 7, 7 |
| csi-shim.c | `csi_window_on_outputs_count` | b | delete when `wayland` window mirror is pinned | 4 |
| csi-shim.c | `csi_window_title_stack_len/push/pop` | b | delete with `Tll(char *)` mirror | 3, 3, 4 |
| csi-shim.c | `csi_foot_version_major/minor/patch/extra` | a | keep (`version.h` macros) | 1 each |
| dcs-shim.c | `dcs_terminfo_capabilities`, `..._size` | a | keep (`static const` array in `foot-terminfo.h`) | 3, 3 |
| grid-shim.c | `grid_resize_and_reflow` | b | keep until `term->composed` mirror + ABI probe; body is an adapter only | 6 |
| sixel-shim.c | `sixel_wayl_do_linear_blending`, `sixel_shm_chain_bit_depth` | a | keep (opaque `wayland`/shm structs) | 3, 3 |
| sixel-shim.c | `sixel_conf_sixel_palette_copy` | c | port the clamp + copy loop into `sixel.zig` | 6 |
| sixel-shim.c | `sixel_pixman_fmt_*`, `sixel_pixman_type_argb` | a | keep (pixman enum ABI) | 3 each |
| vt-shim.c | `vt_call_ascii_printer` | a | keep (C function-pointer call) | 3 |
| vt-shim.c | `vt_tab_stops_insert_before` | c | port the ordered-insert loop with the `Tll(int)` mirror | 9 |
| vt-shim.c | `vt_tab_stops_next_after` | c | port the search loop | 6 |
| vt-shim.c | `vt_tab_stops_push_back/len/back` | b | delete with `Tll(int)` mirror | 3, 3, 3 |
| terminal-shim.c | `terminal_shim_mb_cur_max` | a | keep (`MB_CUR_MAX` macro) | 3 |
| terminal-shim.c | `terminal_shim_urls_mode_active`, `terminal_shim_term_reset_grapheme_state` | a | keep (static inline / feature macro) | 3, 3 |
| terminal-shim.c | `quirk_shim_subsurface_set_desync/sync`, `terminal_shim_wl_surface_commit` | a | keep (generated protocol inlines) | 3 each |
| terminal-shim.c | `terminal_shim_grid_row*`, `terminal_shim_erase_line` | b | delete after grid/ABI mirror (forwarders only) | 3-4 |
| terminal-shim.c | `terminal_shim_fcft_font_*`, `terminal_shim_fcft_font_metrics` | a | keep (opaque fcft struct) | 3, 9 |
| terminal-shim.c | `terminal_shim_precompose` | c | port null-guard + `fcft_precompose` call once fcft signature is mirrored | 16 |
| terminal-shim.c | `terminal_shim_emoji_vs_width` (+ static `emoji_vs_compare`) | c | port table + `bsearch` (generated header is (a), comparison logic is (c)) | 23 |
| terminal-shim.c | `terminal_shim_fcft_font_options_configure` | c | port option-setting sequence into `terminal.zig` | 23 |
| terminal-shim.c | `terminal_shim_linear_blending`, `terminal_shim_grid_is_high_bit_depth` | a | keep (opaque render-chain structs) | 3, 4 |
| terminal-shim.c | `terminal_shim_c32ncmp/c32ncasecmp/isc32print/isc32space/hasc32upper` | a | keep (libc/wchar inlines) | 3-4 |
| terminal-shim.c | `terminal_shim_thrd_err_as_string`, `terminal_shim_wifexited/wexitstatus/wifsignaled/wtermsig` | a | keep (`libc` macros) | 3-4 |
| terminal-shim.c | `terminal_shim_xdg_toplevel_set_maximized/fullscreen` | a | keep (generated protocol inlines) | 3-5 |

Class-c backlog total in scope: 8 functions / 77 body lines. None is a
"delete the wrapper" candidate.

## Top 10 (smallest reproducing scenario)

1. **VT-01 / DECSET** — feed `ESC [ ? 2 5 h` to `vt_from_slave()`: C hides the cursor (`hide_cursor = true`), Zig leaves it visible.
2. **VT-01 / reports** — feed `ESC [ ? 1 0 0 4 h`: C emits `ESC[I`/`ESC[O` via `term_to_slave()`, Zig emits nothing.
3. **VT-01 / alt screen** — feed `ESC [ ? 1 0 4 9 h`: C cancels selection, saves cursor, switches to `term.alt` and erases it; Zig does none of it.
4. **VT-02** — feed `ESC [ 3 8 ; 1 ; 3 1 m`, then `A`: C prints bold red (`attr.bold`, `fg_src=base16`, `fg=1`), Zig prints unstyled.
5. **VT-03** — render one frame (sets `render.last_cursor.row`), send `ESC [ 1 T` (reverse scroll by 1), render again: `dirty_old_cursor()` dereferences the freed row.
6. **VT-04** — URI-list clipboard offer, first (and only) byte `0x01`: `receiveChunk()` → `fdmReceiveDecoderUri()` panics at `selection.zig:2128`.
7. **VT-05** — `OSC 11 ; [999999999999999999999]#000000 BEL`: C ignores the malformed alpha prefix, Zig accepts it and changes the background colour.
8. **VT-06** — feed `OSC 999 BEL`: C silent; Zig writes `osc: unhandled: OSC: 999` to stderr.
9. **VT-07** — with opaque sixel bg, call `sixel_geometry_set()` shrinking height while width is unchanged: C underflows the `memset` count (UB); Zig skips it — correct but undocumented.
10. **VT-01 / kitty flags** — feed `ESC [ = 1 u` then `ESC [ > u`: C sets/reads kitty keyboard flags, Zig no-ops both; the helper bodies exist but are unreachable.

## Open defect verdict (URI-list `0x01`)

Root cause: **decoder contract**. `receiveChunk()`'s C-derived `skip_one()` can
call the decoder with `i == 0` whenever the first byte in a chunk is stripped
(`0x01` in the report, also `\r\n` at offset 0, `\b`, `\x7f`, `\0`). The decoder
is not documented to reject `size == 0`; `fdmReceiveDecoderUri()` uses
`size > 0` as its "allocate the buffer" trigger, so with `size == 0` and a fresh
context `ctx.buf.data` is still null and `.?` panics. The correct invariant is
"a decoder may be called with `size == 0` and must be a no-op"; fix the decoder
(`if (size == 0) return;`), not the caller — the caller's behaviour is exactly
C's and already avoids advancing the pointer incorrectly.

C had the same hole: `selection.c:2199-2235` calls `ctx->decoder(ctx, p, 0)`,
and `fdm_receive_decoder_uri()` (`selection.c:2157-2170`) then performs
`memcpy(NULL, p, 0)` and `memmove(&buf[0], &buf[0], 0)` on a null buffer. The
C standard does not permit a null pointer even for a zero-length `memcpy`, so
this is latent UB; glibc makes it harmless. The Zig crash is a real user-visible
regression on the same input, and the difference is not one of the verified
exceptions.

## Verified-identical list

Token-level comparison (comments/logging/names normalised) plus side-by-side
reads found the following correct; do not repeat them:

- **vt.zig**: `action_clear`, `action_execute`, `action_print`, all `action_param*`, `action_collect`, `action_esc_dispatch`, `action_csi_dispatch`, `action_osc_start/end/put`, `action_hook/put/unhook`, `action_utf8_print`, all `action_utf8_2x/3x/4x`, `anywhere`, every `state_*_switch`, `vt_from_slave`.
- **csi.zig**: `sgr_reset`, `decset_decrst`, `decset`, `decrst`, `xtsave`, `xtrestore`, `decrpm`, `decrqm`, `params_to_rectangular_area`, `case0Dispatch` and its `case0Extra`/`case0UnhandledDispatch`, `caseQuestion` (internals), `caseGreater`, `caseLess`, `caseSpace`, `caseBang`, `caseEquals`, `caseQuestionDollar`, `caseDollar`, `caseHash` (internals — see VT-01 for reachability).
- **dcs.zig**: `ensure_size`, `hex_decode`, `lookup_capability`, `xtgettcap_reply/put/unhook`, `append_sgr_attr_n`, `decrqss_put/unhook`, `dcs_hook/put/unhook`.
- **osc.zig**: `osc_ensure_size`, `osc_flash`, `osc_set_pwd`, `osc_uri` (including the `rand()` bit composition — `rand()` is non-negative so the sign casts agree), `parse_rgb`, `osc_to_clipboard`, `from_clipboard_cb/done`, `osc_from_clipboard`, `osc_selection`, `osc_dispatch` (apart from VT-05/06), `osc_notify_impl`, `kitty_notification_impl`, `kitty_text_size_impl`.
- **sixel.zig**: `sixel_colors_*`, `sixel_geometry_*`, `sixel_fini/init`, `color_decode_srgb`, all `sixel_add_*`/`resize_*`/`decsixel_*`/`decgri_*`/`decgra`/`decgci`, scroll/erase/insert/destroy/invalidate, `blend_new_image_over_old`, `sixel_overwrite_internal`, `_sixel_overwrite_by_rectangle`, `sixel_overwrite_by_rectangle/row/at_cursor`, `sixel_cell_size_changed`, `sixel_sync_cache`, `sixel_reflow*`, `sixel_unhook` (apart from VT-07).
- **terminal.zig**: all functions in the completeness matrix were token-compared; side-by-side reads covered `term_scroll_partial` (apart from VT-03), `term_scroll_reverse_partial`, `term_erase`, `term_erase_scrollback`, `term_fill`, `term_print`, `term_process_and_print_non_ascii`, `term_cursor_*`, `term_damage_*`, `term_reset`, `term_init`, `term_destroy`, PTMX/fdm paths, mouse reporting, IME, text extraction and theme/window paths. NULL guards where C dereferences are the documented exception.
- **grid.zig**: `rowAbsToSb`/`rowSbToAbs` family, `rowAlloc/Free`, `gridSnapshot`, `gridResizeWithoutReflow`, `gridResizeAndReflow`, `reflowRangeStart/End`, `lineWrap`, `tpCmp`, `zeroCells`, all range `put/erase` and ABI wrappers. `_DEBUG` verifier functions are the exception.
- **composed.zig**: all six functions (`composed_key_from_*`, lookup, lookup_without_collision, insert, free).
- **extract.zig**: all five functions.
- **search.zig**: all 35 C functions including `find_next`, `search_find_next`, `matchesCell`, `search_input` and extension primitives.
- **char32.zig**: `mbsntoc32`, `ambstoc32`, `ac32tombs`, `c32width/swidth`, all `c32*` string helpers. (`ambstoc32`/`ac32tombs` keep the old buffer on `realloc` failure where C returns null — safer, C-UB-adjacent.)
- **tokenize.zig**, **unicode-mode.zig**, **box-drawing.zig** (all 219 C functions, including the dash/arc/wedge/shade/braille/sextant/octant families), **hsl.zig**, **quirks.zig**: identical.
- **terminal_types.zig**: `expectAbi()` pins every mirrored field used by these modules; `meson test` `foot:foot:abi-probe-up-to-date` and `foot:zig-terminal_types` pass.
