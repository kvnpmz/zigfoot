const std = @import("std");
const build_options = @import("build_options");

/// Mirrors `#if defined(FOOT_GRAPHEME_CLUSTERING)` in `struct vt`
/// (terminal.h). Must match the C build's `-DFOOT_GRAPHEME_CLUSTERING`.
pub const grapheme_clustering = build_options.grapheme_clustering;

// Expected C layout, verified with a probe compiled with the exact meson
// flags in both configurations (`-Dgrapheme-clustering=disabled` drops
// `grapheme_state`/`codepoint_merging_ok` from `struct vt`).
const vt_size: usize = if (grapheme_clustering) 1792 else 1784;
const vt_utf8_offset: usize = if (grapheme_clustering) 16 else 8;
const terminal_size: usize = if (grapheme_clustering) 5976 else 5968;
const terminal_grid_offset: usize = if (grapheme_clustering) 1840 else 1832;
const terminal_render_offset: usize = if (grapheme_clustering) 3872 else 3864;
const terminal_selection_offset: usize = if (grapheme_clustering) 3712 else 3704;
const terminal_is_searching_offset: usize = if (grapheme_clustering) 3768 else 3760;
const terminal_search_offset: usize = if (grapheme_clustering) 3776 else 3768;
const terminal_url_offset: usize = if (grapheme_clustering) 4592 else 4584;
const terminal_grapheme_shaping_offset: usize = if (grapheme_clustering) 5968 else 5960;

pub const ColorSource = enum(c_int) {
    default,
    base16,
    base256,
    rgb,
};

pub const Coord = extern struct {
    col: c_int,
    row: c_int,
};

pub const Range = extern struct {
    start: Coord,
    end: Coord,
};

pub const Cursor = extern struct {
    point: Coord,
    lcf: bool,
};

pub const CursorOrigin = enum(c_int) {
    absolute,
    relative,
};

pub const Charset = enum(c_int) {
    ascii,
    graphic,
};

pub const TermSurface = enum(c_int) {
    none,
    grid,
    title,
    border_left,
    border_right,
    border_top,
    border_bottom,
    button_minimize,
    button_maximize,
    button_close,
};

pub const SelectionKind = enum(c_int) {
    none,
    char_wise,
    word_wise,
    quote_wise,
    line_wise,
    block,
};

pub const SelectionDirection = enum(c_int) {
    undir,
    left,
    right,
};

pub const SelectionScrollDirection = enum(c_int) {
    not,
    up,
    down,
};

pub const SearchDirection = enum(c_int) {
    backward_same_position,
    backward,
    forward,
};

pub const CursorStyle = enum(c_int) {
    block,
    underline,
    beam,
    hollow,
};

pub const WhichColorTheme = enum(c_int) {
    dark,
    light,
    color_theme_1,
    color_theme_2,
};

pub const PtmxBuffer = extern struct {
    data: ?*anyopaque,
    len: usize,
    idx: usize,
};

pub const Colors = extern struct {
    fg: u32,
    bg: u32,
    table: [256]u32,
    alpha: u16,
    cursor_fg: u32,
    cursor_bg: u32,
    selection_fg: u32,
    selection_bg: u32,
    active_theme: WhichColorTheme,
};

pub const CursorKeys = enum(c_int) {
    dontcare,
    normal,
    application,
};

pub const KeypadKeys = enum(c_int) {
    dontcare,
    numerical,
    application,
};

pub const MouseTracking = enum(c_int) {
    none,
    x10,
    click,
    drag,
    motion,
};

pub const MouseReporting = enum(c_int) {
    normal,
    utf8,
    sgr,
    urxvt,
    sgr_pixels,
};

pub const TllInt = extern struct {
    head: ?*anyopaque,
    tail: ?*anyopaque,
    length: usize,
};

pub const Meta = extern struct {
    esc_prefix: bool,
    eight_bit: bool,
};

pub const Flash = extern struct {
    active: bool,
    fd: c_int,
};

pub const BlinkState = enum(c_int) {
    on,
    off,
};

pub const Blink = extern struct {
    state: BlinkState,
    fd: c_int,
};

pub const Margins = extern struct {
    left: c_int,
    right: c_int,
    top: c_int,
    bottom: c_int,
};

pub const Composed = extern struct {
    chars: ?[*]u32,
    left: ?*Composed,
    right: ?*Composed,
    key: u32,
    count: u8,
    width: u8,
    forced_width: u8,
    _pad0: u8 = undefined,
};

pub const CharsetDesignator = enum(c_int) {
    g0,
    g1,
    g2,
    g3,
};

pub const Charsets = extern struct {
    selected: CharsetDesignator,
    saved: CharsetDesignator,
    set: [4]Charset,
};

pub const ScrollRegion = extern struct {
    start: c_int,
    end: c_int,
};

pub const DamageType = enum(c_int) {
    scroll,
    scroll_reverse,
    scroll_in_view,
    scroll_reverse_in_view,
};

pub const Damage = extern struct {
    type: DamageType,
    region: ScrollRegion,
    lines: u16,
};

pub const Attributes = packed struct(u64) {
    bold: bool,
    dim: bool,
    italic: bool,
    underline: bool,
    strikethrough: bool,
    blink: bool,
    conceal: bool,
    reverse: bool,
    fg: u24,

    clean: bool,
    fg_src: u2,
    bg_src: u2,
    confined: bool,
    selected: bool,
    url: bool,
    bg: u24,
};

pub const Cell = extern struct {
    wc: u32,
    attrs: Attributes align(4),
};

pub const UriRangeData = extern struct {
    id: u64,
    uri: ?[*:0]u8,
};
test "terminal types layout" {
    try @import("std").testing.expectEqual(@as(usize, 8), @sizeOf(Coord));
    try @import("std").testing.expectEqual(@as(usize, 16), @sizeOf(Range));
    try @import("std").testing.expectEqual(@as(usize, 12), @sizeOf(Cursor));
    try @import("std").testing.expectEqual(@as(usize, 8), @sizeOf(ScrollRegion));
}

pub const UnderlineStyle = c_int;

pub const UnderlineRangeData = extern struct {
    style: UnderlineStyle,
    color_src: ColorSource,
    color: u32,
};

pub const RowRangeData = extern union {
    uri: UriRangeData,
    underline: UnderlineRangeData,
};

pub const RowRange = extern struct {
    start: c_int,
    end: c_int,
    data: RowRangeData,
};

pub const RowRangeType = enum(c_int) {
    uri,
    underline,
};

pub const RowRanges = extern struct {
    v: ?[*]RowRange,
    size: c_int,
    count: c_int,
};

test "range types layout" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(UnderlineRangeData));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(RowRangeData));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(RowRange));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(RowRanges));
}

pub const RowData = extern struct {
    uri_ranges: RowRanges,
    underline_ranges: RowRanges,
};

pub const Row = extern struct {
    cells: ?[*]Cell,
    extra: ?*RowData,
    dirty: bool,
    linebreak: bool,
    shell_integration: extern struct {
        prompt_marker: bool,
        cmd_start: c_int,
        cmd_end: c_int,
    },
};

test "row layout" {
    try @import("std").testing.expectEqual(@as(usize, 32), @sizeOf(Row));
}

pub const KittyKbdFlags = enum(c_int) {
    disambiguate = 0x01,
    report_event = 0x02,
    report_alternate = 0x04,
    report_all = 0x08,
    report_associated = 0x10,
    supported = 0x1f,
};

pub const Grid = extern struct {
    num_rows: c_int,
    num_cols: c_int,
    offset: c_int,
    view: c_int,
    cursor: Cursor,
    saved_cursor: Cursor,
    saved_attrs: Attributes,
    rows: ?[*]?*Row,
    cur_row: ?*Row,
    scroll_damage: DamageList,
    sixel_images: SixelList,
    kitty_kbd_flags: [8]KittyKbdFlags,
    kitty_kbd_idx: u8,
};

test "grid basic layout" {
    try @import("std").testing.expectEqual(@as(usize, 4), @sizeOf(KittyKbdFlags));
}

test "cell and attributes layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Attributes));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Cell));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RowData));
}

pub const DamageNode = extern struct {
    item: Damage,
    prev: ?*DamageNode,
    next: ?*DamageNode,
};

pub const DamageList = extern struct {
    head: ?*DamageNode,
    tail: ?*DamageNode,
    length: usize,
};

pub const Sixel = extern struct {
    pix: ?*anyopaque,
    width: c_int,
    height: c_int,
    rows: c_int,
    cols: c_int,
    pos: Coord,
    @"opaque": bool,
    cell_width: c_int,
    cell_height: c_int,
    original: extern struct {
        data: ?*anyopaque,
        pix: ?*anyopaque,
        width: c_int,
        height: c_int,
    },
    scaled: extern struct {
        data: ?*anyopaque,
        pix: ?*anyopaque,
        width: c_int,
        height: c_int,
    },
};

pub const SixelNode = extern struct {
    item: Sixel,
    prev: ?*SixelNode,
    next: ?*SixelNode,
};

pub const SixelList = extern struct {
    head: ?*SixelNode,
    tail: ?*SixelNode,
    length: usize,
};

pub const VtSubparams = extern struct {
    idx: u8,
    cur: ?[*]c_uint,
    value: [16]c_uint,
    dummy: c_uint,
};

pub const VtParam = extern struct {
    value: c_uint,
    sub: VtSubparams,
};

pub const Vt = extern struct {
    state: c_int,
    last_printed: u32,
    // `#if defined(FOOT_GRAPHEME_CLUSTERING)` in terminal.h. Zero-sized in
    // the disabled layout, where `utf8` moves down to offset 8 (Vt: 1784
    // bytes instead of 1792).
    grapheme_state: if (grapheme_clustering) i32 else u0,
    codepoint_merging_ok: if (grapheme_clustering) bool else u0,
    _pad0: if (grapheme_clustering) [3]u8 else u0 = undefined,
    utf8: u32,
    params: extern struct {
        idx: u8,
        _pad0: [7]u8 = undefined,
        cur: ?*VtParam,
        v: [16]VtParam,
        dummy: VtParam,
    },
    private: u32,
    _pad1: [4]u8 = undefined,
    attrs: Attributes,
    osc: extern struct {
        data: ?[*]u8,
        size: usize,
        idx: usize,
        bel: bool,
        _pad0: [7]u8 = undefined,
    },
    osc8: extern struct {
        id: u64,
        uri: ?[*:0]u8,
    },
    underline: UnderlineRangeData,
    _pad2: [4]u8 = undefined,
    dcs: extern struct {
        data: ?[*]u8,
        size: usize,
        idx: usize,
        put_handler: ?*const fn (?*anyopaque, u8) callconv(.c) void,
        unhook_handler: ?*const fn (?*anyopaque) callconv(.c) void,
    },
};

test "layout matches C probe (probe_layout.c)" {
    const t = std.testing;

    try t.expectEqual(@as(usize, 152), @sizeOf(Grid));
    try t.expectEqual(@as(usize, 40), @offsetOf(Grid, "saved_attrs"));
    try t.expectEqual(@as(usize, 48), @offsetOf(Grid, "rows"));
    try t.expectEqual(@as(usize, 64), @offsetOf(Grid, "scroll_damage"));
    try t.expectEqual(@as(usize, 88), @offsetOf(Grid, "sixel_images"));
    try t.expectEqual(@as(usize, 112), @offsetOf(Grid, "kitty_kbd_flags"));

    try t.expectEqual(@as(usize, 32), @sizeOf(Row));
    try t.expectEqual(@as(usize, 8), @offsetOf(Row, "extra"));
    try t.expectEqual(@as(usize, 20), @offsetOf(Row, "shell_integration"));

    try t.expectEqual(@as(usize, 12), @sizeOf(Cell));

    try t.expectEqual(@as(usize, 96), @sizeOf(Sixel));
    try t.expectEqual(@as(usize, 32), @offsetOf(Sixel, "opaque"));
    try t.expectEqual(@as(usize, 48), @offsetOf(Sixel, "original"));
    try t.expectEqual(@as(usize, 72), @offsetOf(Sixel, "scaled"));

    try t.expectEqual(@as(usize, 24), @sizeOf(RowRange));
    try t.expectEqual(@as(usize, 8), @offsetOf(RowRange, "data"));

    try t.expectEqual(@as(usize, 16), @sizeOf(Damage));
    try t.expectEqual(@as(usize, 88), @sizeOf(VtSubparams));
    try t.expectEqual(@as(usize, 96), @sizeOf(VtParam));
    try t.expectEqual(vt_size, @sizeOf(Vt));
    try t.expectEqual(vt_utf8_offset, @offsetOf(Vt, "utf8"));
    try t.expectEqual(@as(usize, 32), @sizeOf(DamageNode));
}

pub const Render = extern struct {
    chains: extern struct {
        grid: ?*anyopaque,
        search: ?*anyopaque,
        scrollback_indicator: ?*anyopaque,
        render_timer: ?*anyopaque,
        url: ?*anyopaque,
        csd: ?*anyopaque,
        overlay: ?*anyopaque,
    },
    refresh: extern struct {
        grid: bool,
        csd: bool,
        search: bool,
        urls: bool,
    },
    pending: extern struct {
        grid: bool,
        csd: bool,
        search: bool,
        urls: bool,
    },
    margins: bool,
    urgency: bool,
    _pad0: [6]u8 = undefined,

    title: extern struct {
        last_update: [16]u8,
        timer_fd: c_int,
        _pad0: [4]u8 = undefined,
    },
    icon: extern struct {
        last_update: [16]u8,
        timer_fd: c_int,
        _pad0: [4]u8 = undefined,
    },
    app_id: extern struct {
        last_update: [16]u8,
        timer_fd: c_int,
        _pad0: [4]u8 = undefined,
    },

    scrollback_lines: u32,
    app_sync_updates: extern struct {
        enabled: bool,
        _pad0: [3]u8 = undefined,
        timer_fd: c_int,
    },

    workers: extern struct {
        count: u16,
        _pad0: [6]u8 = undefined,
        start: [32]u8,
        done: [32]u8,
        lock: [40]u8,
        queue: TllInt,
        threads: ?*anyopaque,
        buf: ?*anyopaque,
        preapplied_damage: extern struct {
            lock: [40]u8,
            cond: [48]u8,
            buf: ?*anyopaque,
            start: [16]u8,
            stop: [16]u8,
        },
    },

    last_cursor: extern struct {
        row: ?*Row,
        col: c_int,
        hidden: bool,
        _pad0: [3]u8 = undefined,
    },
    last_buf: ?*anyopaque,
    frames_since_last_immediate_release: usize,
    preapply_last_frame_damage: bool,
    _pad1: [3]u8 = undefined,
    last_overlay_style: c_int,
    last_overlay_buf: ?*anyopaque,
    last_overlay_clip: [24]u8,
    search_glyph_offset: usize,
    input_time: [16]u8,
};

test "Render layout matches C probe" {
    const t = std.testing;

    try t.expectEqual(@as(usize, 536), @sizeOf(Render));
    try t.expectEqual(@as(usize, 64), @offsetOf(Render, "margins"));

    try t.expectEqual(terminal_render_offset, @offsetOf(Terminal, "render"));
    try t.expectEqual(terminal_size, @sizeOf(Terminal));
    try t.expectEqual(terminal_grid_offset, @offsetOf(Terminal, "grid"));

    // Early fields: `bits_affecting_ascii_printer` is a 1-byte union in C.
    // It was modeled as a 6-byte bool struct, which pushed slave/ptmx 4
    // bytes down and made Zig read ptmx as 0 (term_to_slave wrote to fd 0).
    try t.expectEqual(@as(usize, 1), @sizeOf(@FieldType(Terminal, "bits_affecting_ascii_printer")));
    try t.expectEqual(@as(usize, 32), @offsetOf(Terminal, "bits_affecting_ascii_printer"));
    try t.expectEqual(@as(usize, 36), @offsetOf(Terminal, "slave"));
    try t.expectEqual(@as(usize, 40), @offsetOf(Terminal, "ptmx"));
    try t.expectEqual(@as(usize, 48), @offsetOf(Terminal, "vt"));

    // Fields after the opaque `_font_state` block. These were 8 bytes low
    // while `_font_state` was [104]u8, which silently corrupted selection
    // state and made the `term_erase_scrollback` UNITTEST abort at startup.
    try t.expectEqual(terminal_selection_offset, @offsetOf(Terminal, "selection"));
    try t.expectEqual(terminal_is_searching_offset, @offsetOf(Terminal, "is_searching"));
    try t.expectEqual(terminal_search_offset, @offsetOf(Terminal, "search"));
    try t.expectEqual(terminal_url_offset, @offsetOf(Terminal, "url"));
    try t.expectEqual(terminal_grapheme_shaping_offset, @offsetOf(Terminal, "grapheme_shaping"));
    try t.expectEqual(@as(usize, 160), @offsetOf(Render, "workers"));
    try t.expectEqual(@as(usize, 440), @offsetOf(Render, "last_cursor"));
    try t.expectEqual(@as(usize, 512), @offsetOf(Render, "search_glyph_offset"));
    try t.expectEqual(@as(usize, 520), @offsetOf(Render, "input_time"));
}

// C: union { struct { bool sixels:1, osc8:1, underline_style:1,
// underline_color:1, insert_mode:1, charset:1; }; uint8_t value; }.
// The bitfields are LSB-first on GCC/x86-64 (verified with a C probe);
// a packed struct keeps the existing `._.field` accessors working while
// occupying exactly one byte. A plain bool struct is 6 bytes and shifted
// `slave`/`ptmx` by 4 bytes.
pub const AsciiPrinterBits = packed struct(u8) {
    sixels: bool = false,
    osc8: bool = false,
    underline_style: bool = false,
    underline_color: bool = false,
    insert_mode: bool = false,
    charset: bool = false,
    _padding: u2 = 0,
};

pub const Terminal = extern struct {
    fdm: ?*anyopaque,
    reaper: ?*anyopaque,
    conf: ?*const anyopaque,
    ascii_printer: ?*const anyopaque,
    bits_affecting_ascii_printer: extern union {
        _: AsciiPrinterBits,
        value: u8,
    },
    slave: c_int,
    ptmx: c_int,
    vt: Vt,
    grid: ?*Grid,
    normal: Grid,
    alt: Grid,
    cols: c_int,
    rows: c_int,
    scroll_region: ScrollRegion,
    charsets: Charsets,
    saved_charsets: Charsets,
    auto_margin: bool,
    insert_mode: bool,
    reverse: bool,
    hide_cursor: bool,
    reverse_wrap: bool,
    bracketed_paste: bool,
    focus_events: bool,
    visibility_reports: bool,
    alt_scrolling: bool,
    modify_other_keys_2: bool,
    origin: CursorOrigin,
    cursor_keys_mode: CursorKeys,
    keypad_keys_mode: KeypadKeys,
    mouse_tracking: MouseTracking,
    mouse_reporting: MouseReporting,
    mouse_user_cursor: ?[*:0]u8,
    tab_stops: TllInt,
    composed_count: usize,
    composed: ?*Composed,
    // Mirrors terminal.h (112 bytes):
    //   struct { bool is_armed; int lower_fd; int upper_fd; } delayed_render_timer;
    //   struct fcft_font *fonts[4];
    //   struct config_font *font_sizes[4];
    //   struct pt_or_px font_line_height;
    //   float font_dpi, font_dpi_before_unmap;
    //   bool font_is_sized_by_dpi;
    //   int16_t font_x_ofs, font_y_ofs, font_baseline;
    //   enum fcft_subpixel font_subpixel;
    // NB: was [104]u8 — 8 bytes short, which shifted `selection` and
    // `is_searching` 8 bytes too low (see the ABI test at the bottom).
    _font_state: [112]u8 = undefined,
    custom_glyphs: extern struct {
        box_drawing: ?*anyopaque,
        braille: ?*anyopaque,
        octants: ?*anyopaque,
        legacy: ?*anyopaque,
    },
    is_sending_paste_data: bool,
    ptmx_buffers: TllInt,
    ptmx_paste_buffers: TllInt,
    meta: Meta,
    num_lock_modifier: bool,
    bell_action_enabled: bool,
    report_theme_changes: bool,
    xtsave: [4]u8,
    window_title_has_been_set: bool,
    window_title: ?[*:0]u8,
    window_title_stack: TllInt,
    app_id: ?[*:0]u8,
    flash: Flash,
    blink: Blink,
    scale: f32,
    scale_before_unmap: f32,
    width: c_int,
    height: c_int,
    stashed_width: c_int,
    stashed_height: c_int,
    margins: Margins,
    cell_width: c_int,
    cell_height: c_int,
    colors: Colors,
    color_stack: extern struct {
        stack: ?*Colors,
        idx: usize,
        size: usize,
    },
    cursor_style: CursorStyle,
    cursor_blink: extern struct {
        decset: bool,
        deccsusr: bool,
        fd: c_int,
        state: c_int,
    },
    selection: extern struct {
        kind: SelectionKind,
        direction: SelectionDirection,
        coords: Range,
        ongoing: bool,
        spaces_only: bool,
        pivot: Range,
        auto_scroll: extern struct {
            fd: c_int,
            col: c_int,
            direction: SelectionScrollDirection,
        },
    },
    is_searching: bool,
    // Pads is_searching up to `search` (C: 7 bytes of natural padding).
    _search_pad: [7]u8 = undefined,
    search: extern struct {
        buf: ?[*]u32,
        len: usize,
        sz: usize,
        cursor: usize,
        original_view: c_int,
        view_followed_offset: bool,
        match: Coord,
        match_len: usize,
        last: extern struct {
            buf: ?[*]u32,
            len: usize,
        },
    },
    wl: ?*anyopaque,
    window: ?*anyopaque,
    visual_focus: bool,
    kbd_focus: bool,
    active_surface: TermSurface,
    render: Render,
    interactive_resizing: extern struct {
        grid: ?*Grid,
        old_screen_rows: c_int,
        old_cols: c_int,
        old_hide_cursor: c_int,
        new_rows: c_int,
        selection_coords: Range,
    },
    sixel: extern struct {
        state: SixelState,
        pos: Coord,
        color_idx: c_int,
        private_palette: ?[*]u32,
        shared_palette: ?[*]u32,
        palette: ?[*]u32,
        color: u32,
        image: extern struct {
            data: ?[*]u32,
            p: ?[*]u32,
            width: c_int,
            height: c_int,
            alloc_height: c_int,
            bottom_pixel: c_uint,
        },
        pan: c_int,
        pad: c_int,
        // C bit-fields: `bool scrolling:1; bool use_private_palette:1; bool cursor_right_of_graphics:1;`
        // occupy 1 byte. Expose accessors rather than direct field access.
        _sixel_flags: u8,
        params: [5]c_uint,
        param: c_uint,
        param_idx: c_uint,
        repeat_count: c_uint,
        transparent_bg: bool,
        linear_blending: bool,
        use_10bit: bool,
        pixman_fmt: c_int,
        palette_size: c_uint,
        max_width: c_uint,
        max_height: c_uint,
    },
    url: extern struct {
        list: UrlList,
        keys: [5]u32,
        show_uri_on_jump_label: bool,
        grid_snapshot: ?*Grid,
        ime_reenable_after_url_mode: bool,
        launch: ?*const anyopaque,
    },
    ime_enabled: bool,
    unicode_mode: extern struct {
        active: bool,
        count: c_int,
        character: u32,
    },
    shutdown: extern struct {
        in_progress: bool,
        client_has_terminated: bool,
        terminate_timeout_fd: c_int,
        exit_status: c_int,
        next_signal: c_int,
        cb: ?*const anyopaque,
        cb_data: ?*anyopaque,
    },
    kitty_notification: Notification,
    active_notifications: TllNotification,
    notification_icons: [32]NotificationIcon,
    foot_exe: ?[*:0]u8,
    cwd: ?[*:0]u8,
    grapheme_shaping: bool,
    size_notifications: bool,
};

// ── Notifications (mirrors notify.h) ──────────────────────────────

pub const NotifyWhen = enum(c_int) {
    always,
    unfocused,
    invisible,
};

pub const NotifyUrgency = enum(c_int) {
    normal,
    low,
    critical,
};

pub const TllStr = extern struct {
    head: ?*anyopaque,
    tail: ?*anyopaque,
    length: usize,
};

pub const Notification = extern struct {
    id: ?[*:0]u8,
    app_id: ?[*:0]u8,
    title: ?[*:0]u8,
    body: ?[*:0]u8,
    category: ?[*:0]u8,

    when: NotifyWhen,
    urgency: NotifyUrgency,
    expire_time: i32,

    actions: TllStr,

    icon_cache_id: ?[*:0]u8,
    icon_symbolic_name: ?[*:0]u8,
    icon_data: ?[*]u8,
    icon_data_sz: usize,

    focus: bool,
    may_be_programatically_closed: bool,
    report_activated: bool,
    report_closed: bool,

    muted: bool,
    sound_name: ?[*:0]u8,

    external_id: u32,
    activated: bool,
    button_count: u32,
    activated_button: u32,
    xdg_token: ?[*:0]u8,

    pid: c_int,
    stdout_fd: c_int,

    stdout_data: ?[*]u8,
    stdout_sz: usize,

    icon_path: ?[*:0]u8,
    icon_fd: c_int,
};

pub const NotificationIcon = extern struct {
    id: ?[*:0]u8,
    symbolic_name: ?[*:0]u8,
    tmp_file_name: ?[*:0]u8,
    tmp_file_fd: c_int,
};

comptime {
    if (@sizeOf(Notification) != 192)
        @compileError("Notification: sizeof mismatch with C struct notification");
    if (@offsetOf(Notification, "icon_fd") != 184)
        @compileError("Notification: icon_fd offset mismatch");
    if (@sizeOf(NotificationIcon) != 32)
        @compileError("NotificationIcon: sizeof mismatch");
    if (@offsetOf(NotificationIcon, "tmp_file_fd") != 24)
        @compileError("NotificationIcon: tmp_file_fd offset mismatch");
}

pub const SixelState = enum(c_int) {
    DECSIXEL = 0,
    DECGRA = 1,
    DECGRI = 2,
    DECGCI = 3,
};

pub const UrlAction = enum(c_int) {
    COPY = 0,
    LAUNCH = 1,
    PERSISTENT = 2,
};

pub const Url = extern struct {
    id: u64,
    url: ?[*:0]u8,
    key: ?[*]u32,
    range: Range,
    action: UrlAction,
    url_mode_dont_change_url_attr: bool,
    osc8: bool,
    duplicate: bool,
};

pub const UrlNode = extern struct {
    item: Url,
    prev: ?*UrlNode,
    next: ?*UrlNode,
};

pub const UrlList = extern struct {
    head: ?*UrlNode,
    tail: ?*UrlNode,
    length: usize,
};

pub const NotificationNode = extern struct {
    item: Notification,
    prev: ?*NotificationNode,
    next: ?*NotificationNode,
};

pub const TllNotification = extern struct {
    head: ?*NotificationNode,
    tail: ?*NotificationNode,
    length: usize,
};


// Sixel bit-field accessors (C: bool scrolling:1; bool use_private_palette:1; bool cursor_right_of_graphics:1)
pub inline fn sixelGetScrolling(t: *const Terminal) bool {
    return (t.sixel._sixel_flags & 0x01) != 0;
}
pub inline fn sixelSetScrolling(t: *Terminal, v: bool) void {
    if (v) t.sixel._sixel_flags |= 0x01 else t.sixel._sixel_flags &= ~@as(u8, 0x01);
}
pub inline fn sixelGetUsePrivatePalette(t: *const Terminal) bool {
    return (t.sixel._sixel_flags & 0x02) != 0;
}
pub inline fn sixelSetUsePrivatePalette(t: *Terminal, v: bool) void {
    if (v) t.sixel._sixel_flags |= 0x02 else t.sixel._sixel_flags &= ~@as(u8, 0x02);
}
pub inline fn sixelGetCursorRightOfGraphics(t: *const Terminal) bool {
    return (t.sixel._sixel_flags & 0x04) != 0;
}
pub inline fn sixelSetCursorRightOfGraphics(t: *Terminal, v: bool) void {
    if (v) t.sixel._sixel_flags |= 0x04 else t.sixel._sixel_flags &= ~@as(u8, 0x04);
}

comptime {
    if (@offsetOf(Terminal, "render") != terminal_render_offset)
        @compileError("Terminal: render offset drift");
}


pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

pub const Itimerspec = extern struct {
    it_interval: Timespec,
    it_value: Timespec,
};
