//! Zig port of key-binding.c (D5): the per-(seat, config) key-binding sets.
//!
//! A `struct key_set` is built for every (seat, config) pair on demand: it
//! embeds a `struct key_binding_set` (the public part other modules read),
//! the conf/seat it belongs to, and the cached virtual→real modifier
//! mappings. The config's bindings are converted into runtime
//! `struct key_binding`s here, including the "combo with an explicit
//! modifier *and* a shifted symbol" repair and the most-modifiers-first
//! sort.
//!
//! `struct key_set`, `struct vmod_map` and `struct key_binding_manager` moved
//! from key-binding.c into key-binding.h so the ABI probe can pin their
//! layout; the Zig mirrors live in terminal_types.zig.

const std = @import("std");
const types = @import("terminal_types.zig");
const tll = @import("tll.zig");

const Config = types.Config;
const Seat = types.Seat;
const Terminal = types.Terminal;
const Wayland = types.Wayland;
const KeyBinding = types.KeyBinding;
const KeyBindingSet = types.KeyBindingSet;
const KeyBindingManager = types.KeyBindingManager;
const KeySet = types.KeySet;
const VmodMap = types.VmodMap;

// ── libxkbcommon ──────────────────────────────────────────────────────────
const XKB_MOD_INVALID: u32 = 0xffffffff;
const XKB_STATE_MODS_DEPRESSED: u32 = 1 << 0;

extern fn xkb_state_new(keymap: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn xkb_state_unref(state: ?*anyopaque) callconv(.c) void;
extern fn xkb_state_update_mask(
    state: ?*anyopaque,
    depressed: u32,
    latched: u32,
    locked: u32,
    depressed_layout: u32,
    latched_layout: u32,
    locked_layout: u32,
) callconv(.c) c_int;
extern fn xkb_state_serialize_mods(state: ?*anyopaque, components: u32) callconv(.c) u32;
extern fn xkb_state_key_get_one_sym(state: ?*anyopaque, key: u32) callconv(.c) u32;
extern fn xkb_state_key_get_layout(state: ?*anyopaque, key: u32) callconv(.c) u32;
extern fn xkb_keymap_mod_get_index(keymap: ?*anyopaque, name: [*:0]const u8) callconv(.c) u32;
extern fn xkb_keymap_mod_get_name(keymap: ?*anyopaque, idx: u32) callconv(.c) ?[*:0]const u8;
extern fn xkb_keymap_min_keycode(keymap: ?*anyopaque) callconv(.c) u32;
extern fn xkb_keymap_max_keycode(keymap: ?*anyopaque) callconv(.c) u32;
extern fn xkb_keymap_key_get_syms_by_level(
    keymap: ?*anyopaque,
    key: u32,
    layout: u32,
    level: u32,
    syms_out: *?[*]const u32,
) callconv(.c) c_int;
extern fn xkb_keymap_num_levels_for_key(keymap: ?*anyopaque, key: u32, layout: u32) callconv(.c) u32;
extern fn xkb_keymap_key_get_mods_for_level(
    keymap: ?*anyopaque,
    key: u32,
    layout: u32,
    level: u32,
    masks_out: [*]u32,
    masks_size: usize,
) callconv(.c) usize;
extern fn xkb_keysym_get_name(sym: u32, buffer: [*]u8, size: usize) callconv(.c) c_int;

extern fn xcalloc(n: usize, size: usize) callconv(.c) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn bug(
    file: [*:0]const u8,
    line: c_int,
    func: [*:0]const u8,
    fmt: [*:0]const u8,
    ...
) callconv(.c) noreturn;

const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;

/// xkbcommon-vmod.h's virtual modifier names, in key-binding.c's order.
const vmod_names = [8][*:0]const u8{
    "Alt",
    "Hyper",
    "LevelThree",
    "LevelFive",
    "Meta",
    "NumLock",
    "ScrollLock",
    "Super",
};

fn emptyTll() types.Tll(?*anyopaque) {
    return .{ .head = null, .tail = null, .length = 0 };
}

fn keySetList(mgr: *KeyBindingManager) *tll.Tll(KeySet) {
    return @ptrCast(&mgr.binding_sets);
}

fn keySetListConst(mgr: *const KeyBindingManager) *const tll.Tll(KeySet) {
    return @ptrCast(&mgr.binding_sets);
}

fn bindingList(set: *KeyBindingSet, comptime field: []const u8) *tll.Tll(KeyBinding) {
    return @ptrCast(&@field(set, field));
}

fn bindingListConst(set: *const KeyBindingSet, comptime field: []const u8) *const tll.Tll(KeyBinding) {
    return @ptrCast(&@field(set, field));
}

fn keyCodeList(binding: *KeyBinding) *tll.Tll(u32) {
    return @ptrCast(&binding._u.k.key_codes);
}

// ─────────────────────────────────────────────────────────────────────────
// Manager lifecycle
// ─────────────────────────────────────────────────────────────────────────

export fn key_binding_manager_new() callconv(.c) ?*KeyBindingManager {
    const mgr = xcalloc(1, @sizeOf(KeyBindingManager)) orelse unreachable;
    return @ptrCast(@alignCast(mgr));
}

export fn key_binding_manager_destroy(mgr: ?*KeyBindingManager) callconv(.c) void {
    const m = mgr orelse return;
    std.debug.assert(keySetListConst(m).len() == 0);
    free(m);
}

// ─────────────────────────────────────────────────────────────────────────
// Virtual → real modifier mappings
// ─────────────────────────────────────────────────────────────────────────

fn initializeVmodMappings(set: *KeySet) void {
    const seat = set.seat orelse return;
    const keymap = seat.kbd.xkb_keymap orelse return;

    for (&set.vmods, 0..) |*vmod, i|
        vmod.name = vmod_names[i];

    const scratch_state = xkb_state_new(keymap) orelse unreachable;

    for (&set.vmods) |*vmod| {
        const virt_idx = xkb_keymap_mod_get_index(keymap, vmod.name.?);

        if (virt_idx != XKB_MOD_INVALID) {
            const vmask: u32 = @as(u32, 1) << @intCast(virt_idx);
            _ = xkb_state_update_mask(scratch_state, vmask, 0, 0, 0, 0, 0);
            vmod.real_mask =
                xkb_state_serialize_mods(scratch_state, XKB_STATE_MODS_DEPRESSED) & ~vmask;
            vmod.virtual_mask = vmask;
        } else {
            vmod.virtual_mask = 0;
            vmod.real_mask = 0;
        }
    }

    xkb_state_unref(scratch_state);
}

// ─────────────────────────────────────────────────────────────────────────
// Building sets
// ─────────────────────────────────────────────────────────────────────────

export fn key_binding_new_for_seat(
    mgr: ?*KeyBindingManager,
    seat: ?*const Seat,
) callconv(.c) void {
    const m = mgr orelse return;
    const s = seat orelse return;
    const sets = keySetList(m);

    const wayl = s.wayl orelse return;
    const terms: *const tll.Tll(?*anyopaque) = @ptrCast(&wayl.terms);

    var it = (@constCast(terms)).foreach();
    while (it.next()) |node| {
        const term: *Terminal = @ptrCast(@alignCast(node.item orelse continue));

        sets.pushBack(.{
            .public = .{
                .key = emptyTll(),
                .search = emptyTll(),
                .url = emptyTll(),
                .mouse = emptyTll(),
                .selection_overrides = 0,
            },
            .conf = term.conf,
            .seat = s,
            .conf_ref_count = 1,
            .vmods = undefined,
        });

        initializeVmodMappings(sets.back());
        loadKeymap(sets.back());
    }
}

export fn key_binding_new_for_conf(
    mgr: ?*KeyBindingManager,
    wayl: ?*const Wayland,
    conf: ?*const Config,
) callconv(.c) void {
    const m = mgr orelse return;
    const w = wayl orelse return;
    const c = conf orelse return;
    const sets = keySetList(m);

    const seats: *const tll.Tll(Seat) = @ptrCast(&w.seats);

    var it = (@constCast(seats)).foreach();
    while (it.next()) |node| {
        const seat: *const Seat = &node.item;

        if (key_binding_for(m, c, seat)) |existing| {
            const ks: *KeySet = @ptrCast(@alignCast(existing));
            ks.conf_ref_count += 1;
            continue;
        }

        sets.pushBack(.{
            .public = .{
                .key = emptyTll(),
                .search = emptyTll(),
                .url = emptyTll(),
                .mouse = emptyTll(),
                .selection_overrides = 0,
            },
            .conf = c,
            .seat = seat,
            .conf_ref_count = 1,
            .vmods = undefined,
        });

        initializeVmodMappings(sets.back());
        loadKeymap(sets.back());

        // Chances are high this set will be requested next
        m.last_used_set = sets.back();
    }
}

export fn key_binding_for(
    mgr: ?*KeyBindingManager,
    conf: ?*const Config,
    seat: ?*const Seat,
) callconv(.c) ?*KeyBindingSet {
    const m = mgr orelse return null;

    if (m.last_used_set) |last_used| {
        if (last_used.conf == conf and last_used.seat == seat)
            return &last_used.public;
    }

    const sets = keySetListConst(m);

    var it = (@constCast(sets)).foreach();
    while (it.next()) |node| {
        const set = &node.item;

        if (set.conf != conf) continue;
        if (set.seat != seat) continue;

        m.last_used_set = set;
        return &set.public;
    }

    return null;
}

fn keyBindingSetDestroy(mgr: *KeyBindingManager, set: *KeySet) void {
    unloadKeymap(set);
    if (mgr.last_used_set == set)
        mgr.last_used_set = null;
    // Note: caller must remove from binding_sets
}

export fn key_binding_remove_seat(
    mgr: ?*KeyBindingManager,
    seat: ?*const Seat,
) callconv(.c) void {
    const m = mgr orelse return;
    const sets = keySetList(m);

    var it = sets.foreach();
    while (it.next()) |node| {
        const set = &node.item;

        if (set.seat != seat) continue;

        keyBindingSetDestroy(m, set);
        sets.removeNode(node);
    }
}

export fn key_binding_unref(
    mgr: ?*KeyBindingManager,
    conf: ?*const Config,
) callconv(.c) void {
    const m = mgr orelse return;
    const sets = keySetList(m);

    var it = sets.foreach();
    while (it.next()) |node| {
        const set = &node.item;

        if (set.conf != conf) continue;

        std.debug.assert(set.conf_ref_count > 0);
        set.conf_ref_count -= 1;
        if (set.conf_ref_count == 0) {
            keyBindingSetDestroy(m, set);
            sets.removeNode(node);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Config → runtime binding conversion
// ─────────────────────────────────────────────────────────────────────────

fn keyCodesForXkbSym(keymap: ?*anyopaque, sym: u32) tll.Tll(u32) {
    var key_codes = tll.Tll(u32){};

    // Find all key codes that map to this symbol.
    //
    // This allows us to match bindings in other layouts too.
    const state = xkb_state_new(keymap) orelse return key_codes;

    var code: u32 = xkb_keymap_min_keycode(keymap);
    const max_code = xkb_keymap_max_keycode(keymap);
    while (code <= max_code) : (code += 1) {
        if (xkb_state_key_get_one_sym(state, code) == sym)
            key_codes.pushBack(code);
    }

    xkb_state_unref(state);
    return key_codes;
}

/// Detect combos containing a shifted symbol and the corresponding modifier,
/// and replace the shifted symbol with its unshifted variant.
///
/// For example, "Control+Shift+U": Shift is consumed producing 'U', so the
/// combo would never match (consumed modifiers are filtered out when
/// matching). We look for a key code/level that produces `sym` and whose
/// required modifier set intersects `mods`, then return the level-0 symbol.
fn maybeRepairKeyCombo(seat: *const Seat, sym: u32, mods: u32) u32 {
    const keymap = seat.kbd.xkb_keymap orelse return sym;
    const xkb_state = seat.kbd.xkb_state orelse return sym;

    var code: u32 = xkb_keymap_min_keycode(keymap);
    const max_code = xkb_keymap_max_keycode(keymap);
    while (code <= max_code) : (code += 1) {
        const layout_idx = xkb_state_key_get_layout(xkb_state, code);

        // Get all unshifted symbols for this key
        var base_syms: ?[*]const u32 = null;
        const base_count = xkb_keymap_key_get_syms_by_level(
            keymap, code, layout_idx, 0, &base_syms);
        if (base_count == 0)
            continue;

        const base_syms_slice = base_syms.?[0..@intCast(base_count)];
        const base_sym = base_syms_slice[0];

        // No unshifted symbols, or unshifted symbol is same as 'sym'
        if (sym == base_sym)
            continue;

        // Name of the unshifted symbol, for logging
        var base_name: [100]u8 = undefined;
        _ = xkb_keysym_get_name(base_sym, &base_name, base_name.len);

        // Iterate all shift levels
        var level_idx: u32 = 1;
        const num_levels = xkb_keymap_num_levels_for_key(keymap, code, layout_idx);
        while (level_idx < num_levels) : (level_idx += 1) {
            // Get all symbols for current shift level
            var shifted_syms: ?[*]const u32 = null;
            const shifted_count = xkb_keymap_key_get_syms_by_level(
                keymap, code, layout_idx, level_idx, &shifted_syms);
            if (shifted_count == 0)
                continue;

            const shifted = shifted_syms.?[0..@intCast(shifted_count)];

            for (shifted) |shifted_sym| {
                if (shifted_sym != sym)
                    continue;

                // Get modifier sets that produces the current shift level
                var mod_masks: [16]u32 = undefined;
                const mod_mask_count = xkb_keymap_key_get_mods_for_level(
                    keymap, code, layout_idx, level_idx, &mod_masks, mod_masks.len);

                // Check if key combo's modifier set intersects
                for (mod_masks[0..mod_mask_count]) |mod_mask| {
                    if ((mod_mask & mods) != mod_mask)
                        continue;

                    var combo_buf: [64]u8 = undefined;
                    var combo_len: usize = 0;

                    var k: u5 = 0;
                    while (true) : (k += 1) {
                        if ((mods & (@as(u32, 1) << k)) != 0) {
                            const mod_name = xkb_keymap_mod_get_name(keymap, k) orelse "";
                            const name = std.mem.span(mod_name);
                            if (combo_len + name.len + 2 <= combo_buf.len) {
                                @memcpy(combo_buf[combo_len..][0..name.len], name);
                                combo_len += name.len;
                                combo_buf[combo_len] = '+';
                                combo_len += 1;
                            }
                        }
                        if (k == 31) break;
                    }

                    _ = xkb_keysym_get_name(
                        sym, combo_buf[combo_len..].ptr, combo_buf.len - combo_len);

                    log_msg(
                        LOG_CLASS_WARNING, "key-binding", "key-binding.zig",
                        @intCast(@src().line),
                        "%s: combo with both explicit modifier and shifted symbol " ++
                            "(level=%d, mod-mask=0x%08x), replacing with %s",
                        @as([*:0]const u8, @ptrCast(&combo_buf)),
                        level_idx,
                        mod_mask,
                        @as([*:0]const u8, @ptrCast(&base_name)));

                    // Replace with unshifted symbol
                    return base_sym;
                }
            }
        }
    }

    return sym;
}

/// Sort bindings such that bindings with the same symbol are sorted with the
/// binding having the most modifiers first.
///
/// This fixes an issue where the "wrong" key binding is triggered when used
/// with "consumed" modifiers: if Control+BackSpace is bound before
/// Control+Shift+BackSpace, the latter is never triggered, because Shift is
/// consumed and the first binding "matches" both. See foot#1280.
fn keyCmp(a: *const KeyBinding, b: *const KeyBinding) callconv(.c) i32 {
    std.debug.assert(a.type == b.type);

    const a_mod_count: i32 = @intCast(@popCount(a.mods));
    const b_mod_count: i32 = @intCast(@popCount(b.mods));

    switch (a.type) {
        .key => {
            if (a._u.k.sym != b._u.k.sym)
                return @bitCast(b._u.k.sym -% a._u.k.sym);
            return b_mod_count - a_mod_count;
        },

        .mouse => {
            if (a._u.m.button != b._u.m.button)
                return @bitCast(b._u.m.button -% a._u.m.button);
            if (a_mod_count != b_mod_count)
                return b_mod_count - a_mod_count;
            return b._u.m.count - a._u.m.count;
        },
    }
}

fn sortBindingList(list: *tll.Tll(KeyBinding)) void {
    list.sort(&keyCmp);
}

fn modsToMask(
    seat: *const Seat,
    vmods: []const VmodMap,
    mods: *const types.TllStr,
) u32 {
    var mask: u32 = 0;

    const names: *const tll.Tll(?[*:0]u8) = @ptrCast(mods);
    var it = (@constCast(names)).foreach();
    while (it.next()) |node| {
        const name = node.item orelse continue;

        const idx = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, name);
        if (idx == XKB_MOD_INVALID) {
            log_msg(
                LOG_CLASS_ERROR, "key-binding", "key-binding.zig", @intCast(@src().line),
                "%s: invalid modifier name", name);
            continue;
        }

        var mod: u32 = @as(u32, 1) << @intCast(idx);

        // Check if this is a virtual modifier, and if so, use the real
        // modifier it maps to instead
        for (vmods) |vmod| {
            if (vmod.virtual_mask == mod) {
                mask |= vmod.real_mask;
                mod = 0;
                break;
            }
        }

        mask |= mod;
    }

    return mask;
}

fn convertKeyBinding(
    set: *KeySet,
    conf_binding: *const types.ConfigKeyBinding,
    bindings: *tll.Tll(KeyBinding),
) void {
    const seat = set.seat orelse return;

    const mods = modsToMask(seat, &set.vmods, &conf_binding.modifiers);
    const sym = maybeRepairKeyCombo(seat, conf_binding._u.k.sym, mods);

    var binding: KeyBinding = undefined;
    binding.type = .key;
    binding.action = conf_binding.action;
    binding.mods = mods;
    binding.aux = @ptrCast(@constCast(&conf_binding.aux));
    binding._u.k.sym = sym;
    keyCodeList(&binding).* = keyCodesForXkbSym(seat.kbd.xkb_keymap, sym);

    bindings.pushBack(binding);
    sortBindingList(bindings);
}

fn convertKeyBindings(set: *KeySet) void {
    const conf = set.conf orelse return;
    const bindings = bindingList(&set.public, "key");

    var i: usize = 0;
    while (i < conf.bindings.key.count) : (i += 1) {
        const binding = &conf.bindings.key.arr.?[i];
        convertKeyBinding(set, binding, bindings);
    }
}

fn convertSearchBindings(set: *KeySet) void {
    const conf = set.conf orelse return;
    const bindings = bindingList(&set.public, "search");

    var i: usize = 0;
    while (i < conf.bindings.search.count) : (i += 1) {
        const binding = &conf.bindings.search.arr.?[i];
        convertKeyBinding(set, binding, bindings);
    }
}

fn convertUrlBindings(set: *KeySet) void {
    const conf = set.conf orelse return;
    const bindings = bindingList(&set.public, "url");

    var i: usize = 0;
    while (i < conf.bindings.url.count) : (i += 1) {
        const binding = &conf.bindings.url.arr.?[i];
        convertKeyBinding(set, binding, bindings);
    }
}

fn convertMouseBinding(set: *KeySet, conf_binding: *const types.ConfigKeyBinding) void {
    const seat = set.seat orelse return;
    const mouse = bindingList(&set.public, "mouse");

    var binding: KeyBinding = undefined;
    binding.type = .mouse;
    binding.action = conf_binding.action;
    binding.mods = modsToMask(seat, &set.vmods, &conf_binding.modifiers);
    binding.aux = @ptrCast(@constCast(&conf_binding.aux));
    binding._u.m.button = @bitCast(conf_binding._u.m.button);
    binding._u.m.count = conf_binding._u.m.count;

    mouse.pushBack(binding);
    sortBindingList(mouse);
}

fn convertMouseBindings(set: *KeySet) void {
    const conf = set.conf orelse return;

    var i: usize = 0;
    while (i < conf.bindings.mouse.count) : (i += 1) {
        const binding = &conf.bindings.mouse.arr.?[i];
        convertMouseBinding(set, binding);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Keymap load/unload
// ─────────────────────────────────────────────────────────────────────────

fn loadKeymap(set: *KeySet) void {
    const seat = set.seat orelse return;
    const conf = set.conf orelse return;

    if (seat.kbd.xkb_state == null or seat.kbd.xkb_keymap == null)
        return;

    convertKeyBindings(set);
    convertSearchBindings(set);
    convertUrlBindings(set);
    convertMouseBindings(set);

    set.public.selection_overrides = modsToMask(
        seat, &set.vmods, &conf.mouse.selection_override_modifiers);
}

export fn key_binding_load_keymap(
    mgr: ?*KeyBindingManager,
    seat: ?*const Seat,
) callconv(.c) void {
    const m = mgr orelse return;
    const sets = keySetList(m);

    var it = sets.foreach();
    while (it.next()) |node| {
        const set = &node.item;

        if (set.seat == seat) {
            initializeVmodMappings(set);
            loadKeymap(set);
        }
    }
}

fn keyBindingsDestroy(bindings: *tll.Tll(KeyBinding)) void {
    var it = bindings.foreach();
    while (it.next()) |node| {
        const bind = &node.item;
        switch (bind.type) {
            .key => keyCodeList(bind).freeList(),
            .mouse => {},
        }

        bindings.removeNode(node);
    }
}

fn unloadKeymap(set: *KeySet) void {
    keyBindingsDestroy(bindingList(&set.public, "key"));
    keyBindingsDestroy(bindingList(&set.public, "search"));
    keyBindingsDestroy(bindingList(&set.public, "url"));
    keyBindingsDestroy(bindingList(&set.public, "mouse"));
    set.public.selection_overrides = 0;
}

export fn key_binding_unload_keymap(
    mgr: ?*KeyBindingManager,
    seat: ?*const Seat,
) callconv(.c) void {
    const m = mgr orelse return;
    const sets = keySetList(m);

    var it = sets.foreach();
    while (it.next()) |node| {
        const set = &node.item;
        if (set.seat != seat)
            continue;

        unloadKeymap(set);
    }
}
