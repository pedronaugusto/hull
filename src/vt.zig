//! The program's terminal: libghostty-vt through its C API, with the
//! effects that answer the program (device attributes, version, sizes) and
//! the colours hull's theme starts it with. OSC 4, 10 and 11 queries are
//! answered by libghostty-vt from those colours; a program that sets them
//! changes them.
//!
//! hull's own setting rides on an OSC of its own, 7701, read here before
//! libghostty-vt (which ignores an OSC it does not know):
//!
//!     ESC ] 7701 ; background-opacity=90 ST    set (clamped to 80..100)
//!     ESC ] 7701 ; background-opacity=? ST     ask; answered the same way
const std = @import("std");
pub const c = @import("vt");
const theme_mod = @import("theme.zig");
const config = @import("config.zig");
const Pty = @import("pty.zig").Pty;

pub const version = "0.0.0";
pub const xtversion = "hull " ++ version;

pub const Vt = struct {
    term: c.GhosttyTerminal = null,
    render: c.GhosttyRenderState = null,
    rows_it: c.GhosttyRenderStateRowIterator = null,
    cells: c.GhosttyRenderStateRowCells = null,
    placements: c.GhosttyKittyGraphicsPlacementIterator = null,
    key_encoder: c.GhosttyKeyEncoder = null,
    key_event: c.GhosttyKeyEvent = null,

    pty: ?*Pty = null,
    cols: u16,
    rows: u16,
    cell_w: u32,
    cell_h: u32,
    dark: bool,
    /// hull's background opacity, percent, 80..100.
    opacity: u8,
    /// Set when the program changed the opacity or the title.
    opacity_changed: bool = false,
    title_changed: bool = false,
    scan: Scan = .{},

    pub fn init(v: *Vt, cols: u16, rows: u16, cell_w: u32, cell_h: u32, th: theme_mod.Theme, term_cfg: config.Terminal) !void {
        v.* = .{ .cols = cols, .rows = rows, .cell_w = cell_w, .cell_h = cell_h, .dark = th.dark, .opacity = term_cfg.background_opacity };
        try ok(c.ghostty_terminal_new(null, &v.term, cols, rows));
        errdefer v.deinit();
        const lines: usize = term_cfg.scrollback;
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines);
        try ok(c.ghostty_terminal_resize(v.term, cols, rows, cell_w, cell_h));

        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_USERDATA, v);
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&writePty));
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_SIZE, @ptrCast(&size));
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_XTVERSION, @ptrCast(&xtVersion));
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, @ptrCast(&deviceAttributes));
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, @ptrCast(&colorScheme));
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @ptrCast(&titleChanged));

        // The theme, as the terminal's defaults: what OSC 4/10/11 report
        // and what an OSC 104/110/111 reset returns to.
        var fg = rgb(th.foreground);
        var bg = rgb(th.background);
        var cur = rgb(th.cursor);
        var pal: [256]c.GhosttyColorRgb = undefined;
        for (th.palette(), 0..) |p, i| pal[i] = rgb(p);
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg);
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg);
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cur);
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &pal);

        var style: c.GhosttyTerminalCursorStyle = switch (term_cfg.cursor_style) {
            .block => c.GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK,
            .bar => c.GHOSTTY_TERMINAL_CURSOR_STYLE_BAR,
            .underline => c.GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE,
            .block_hollow => c.GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW,
        };
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style);
        var blink = term_cfg.cursor_blink;
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink);

        // Kitty graphics: on, with every medium a local program may use.
        var limit: u64 = 320 * 1024 * 1024;
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit);
        var yes = true;
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &yes);
        // The temporary-file medium, restricted to the temporary directory.
        const tmp: []const u8 = if (std.c.getenv("TMPDIR")) |d| std.mem.span(d) else "/tmp";
        var tmp_s: c.GhosttyString = .{ .ptr = tmp.ptr, .len = tmp.len };
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, &tmp_s);
        _ = c.ghostty_terminal_set(v.term, c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &yes);

        try ok(c.ghostty_render_state_new(null, &v.render));
        try ok(c.ghostty_render_state_row_iterator_new(null, &v.rows_it));
        try ok(c.ghostty_render_state_row_cells_new(null, &v.cells));
        try ok(c.ghostty_kitty_graphics_placement_iterator_new(null, &v.placements));
        try ok(c.ghostty_key_encoder_new(null, &v.key_encoder));
        try ok(c.ghostty_key_event_new(null, &v.key_event));
        var alt: c.GhosttyOptionAsAlt = if (term_cfg.option_as_alt) c.GHOSTTY_OPTION_AS_ALT_TRUE else c.GHOSTTY_OPTION_AS_ALT_FALSE;
        c.ghostty_key_encoder_setopt(v.key_encoder, c.GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &alt);
    }

    pub fn deinit(v: *Vt) void {
        if (v.key_event) |e| c.ghostty_key_event_free(e);
        if (v.key_encoder) |e| c.ghostty_key_encoder_free(e);
        if (v.placements) |p| c.ghostty_kitty_graphics_placement_iterator_free(p);
        if (v.cells) |p| c.ghostty_render_state_row_cells_free(p);
        if (v.rows_it) |p| c.ghostty_render_state_row_iterator_free(p);
        if (v.render) |p| c.ghostty_render_state_free(p);
        if (v.term) |t| c.ghostty_terminal_free(t);
        v.term = null;
    }

    /// The program's output, into the terminal.
    pub fn feed(v: *Vt, bytes: []const u8) void {
        v.scan.feed(v, bytes);
        c.ghostty_terminal_vt_write(v.term, bytes.ptr, bytes.len);
    }

    pub fn resize(v: *Vt, cols: u16, rows: u16, cell_w: u32, cell_h: u32) void {
        v.cols = cols;
        v.rows = rows;
        v.cell_w = cell_w;
        v.cell_h = cell_h;
        _ = c.ghostty_terminal_resize(v.term, cols, rows, cell_w, cell_h);
    }

    pub fn mode(v: *Vt, m: c.GhosttyMode) bool {
        var q: c.GhosttyTerminalModeConfig = .{ .mode = m, .value = false };
        if (c.ghostty_terminal_get(v.term, c.GHOSTTY_TERMINAL_DATA_MODE, &q) != c.GHOSTTY_SUCCESS) return false;
        return q.value;
    }

    /// Whether the program is inside a synchronized update (mode 2026).
    pub fn synchronized(v: *Vt) bool {
        return v.mode(c.ghostty_mode_new(2026, false));
    }

    /// The title the program set, or empty.
    pub fn title(v: *Vt) []const u8 {
        var s: c.GhosttyString = .{ .ptr = null, .len = 0 };
        if (c.ghostty_terminal_get(v.term, c.GHOSTTY_TERMINAL_DATA_TITLE, &s) != c.GHOSTTY_SUCCESS) return "";
        if (s.ptr == null) return "";
        return s.ptr[0..s.len];
    }

    /// Encodes one key for the program in the modes it asked for (the
    /// kitty keyboard protocol among them) into `out`.
    pub fn encodeKey(v: *Vt, k: Key, out: []u8) []const u8 {
        c.ghostty_key_encoder_setopt_from_terminal(v.key_encoder, v.term);
        const e = v.key_event;
        c.ghostty_key_event_set_action(e, @intFromEnum(k.action));
        c.ghostty_key_event_set_key(e, k.key);
        c.ghostty_key_event_set_mods(e, k.mods);
        c.ghostty_key_event_set_consumed_mods(e, k.consumed);
        c.ghostty_key_event_set_unshifted_codepoint(e, k.unshifted);
        c.ghostty_key_event_set_composing(e, false);
        if (k.text.len > 0 and k.action != .release)
            c.ghostty_key_event_set_utf8(e, k.text.ptr, k.text.len)
        else
            c.ghostty_key_event_set_utf8(e, null, 0);
        var n: usize = 0;
        if (c.ghostty_key_encoder_encode(v.key_encoder, e, out.ptr, out.len, &n) != c.GHOSTTY_SUCCESS) return "";
        return out[0..n];
    }

    /// Focus in or out, if the program asked to hear it (mode 1004).
    pub fn encodeFocus(v: *Vt, focused: bool, out: []u8) []const u8 {
        if (!v.mode(c.ghostty_mode_new(1004, false))) return "";
        var n: usize = 0;
        if (c.ghostty_focus_encode(if (focused) c.GHOSTTY_FOCUS_GAINED else c.GHOSTTY_FOCUS_LOST, out.ptr, out.len, &n) != c.GHOSTTY_SUCCESS) return "";
        return out[0..n];
    }

    fn reply(v: *Vt, bytes: []const u8) void {
        if (v.pty) |p| p.write(bytes);
    }

    fn setOpacity(v: *Vt, value: []const u8) void {
        if (std.mem.eql(u8, value, "?")) {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "\x1b]7701;background-opacity={d}\x1b\\", .{v.opacity}) catch return;
            v.reply(s);
            return;
        }
        const n = std.fmt.parseInt(i64, value, 10) catch return;
        const next = config.clampOpacity(n);
        if (next != v.opacity) {
            v.opacity = next;
            v.opacity_changed = true;
        }
    }
};

/// One key as the platform saw it, for `Vt.encodeKey`.
pub const Key = struct {
    action: Action,
    /// The physical key, libghostty's W3C code.
    key: c.GhosttyKey,
    mods: c.GhosttyMods = 0,
    consumed: c.GhosttyMods = 0,
    /// The text the key produced under the layout and mods, if any.
    text: []const u8 = "",
    /// The key's character with no modifiers, 0 for none.
    unshifted: u32 = 0,

    pub const Action = enum(c_uint) { release = 0, press = 1, repeat = 2 };
};

/// Finds `ESC ] 7701 ; key=value (BEL | ESC \)` in output however it is
/// split across reads.
const Scan = struct {
    state: enum { ground, esc, osc_num, payload, payload_esc } = .ground,
    num: u32 = 0,
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn feed(s: *Scan, v: *Vt, bytes: []const u8) void {
        for (bytes) |b| switch (s.state) {
            .ground => if (b == 0x1b) {
                s.state = .esc;
            },
            .esc => if (b == ']') {
                s.state = .osc_num;
                s.num = 0;
            } else {
                s.state = if (b == 0x1b) .esc else .ground;
            },
            .osc_num => if (b >= '0' and b <= '9') {
                s.num = s.num *| 10 +| (b - '0');
            } else if (b == ';' and s.num == 7701) {
                s.state = .payload;
                s.len = 0;
            } else {
                s.state = if (b == 0x1b) .esc else .ground;
            },
            .payload => if (b == 0x07) {
                s.done(v);
            } else if (b == 0x1b) {
                s.state = .payload_esc;
            } else if (s.len < s.buf.len) {
                s.buf[s.len] = b;
                s.len += 1;
            } else {
                s.state = .ground;
            },
            .payload_esc => if (b == '\\') s.done(v) else {
                s.state = .esc;
            },
        };
    }

    fn done(s: *Scan, v: *Vt) void {
        s.state = .ground;
        const p = s.buf[0..s.len];
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse return;
        if (std.mem.eql(u8, p[0..eq], "background-opacity")) v.setOpacity(p[eq + 1 ..]);
    }
};

fn ok(r: c.GhosttyResult) !void {
    if (r != c.GHOSTTY_SUCCESS) return error.Ghostty;
}

pub fn rgb(x: theme_mod.Rgb) c.GhosttyColorRgb {
    return .{ .r = x.r, .g = x.g, .b = x.b };
}

fn self(ud: ?*anyopaque) *Vt {
    return @ptrCast(@alignCast(ud.?));
}

fn writePty(_: c.GhosttyTerminal, ud: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    self(ud).reply(data[0..len]);
}

fn size(_: c.GhosttyTerminal, ud: ?*anyopaque, out: [*c]c.GhosttySizeReportSize) callconv(.c) bool {
    const v = self(ud);
    out.* = .{ .rows = v.rows, .columns = v.cols, .cell_width = v.cell_w, .cell_height = v.cell_h };
    return true;
}

fn xtVersion(_: c.GhosttyTerminal, _: ?*anyopaque) callconv(.c) c.GhosttyString {
    return .{ .ptr = xtversion.ptr, .len = xtversion.len };
}

fn deviceAttributes(_: c.GhosttyTerminal, _: ?*anyopaque, out: [*c]c.GhosttyDeviceAttributes) callconv(.c) bool {
    // DA1 as Ghostty answers: VT220 with 132 columns, selective erase
    // and ANSI colour; no sixel, so a program looks for kitty pictures.
    out.*.primary.conformance_level = c.GHOSTTY_DA_CONFORMANCE_VT220;
    out.*.primary.features[0] = c.GHOSTTY_DA_FEATURE_COLUMNS_132;
    out.*.primary.features[1] = c.GHOSTTY_DA_FEATURE_SELECTIVE_ERASE;
    out.*.primary.features[2] = c.GHOSTTY_DA_FEATURE_ANSI_COLOR;
    out.*.primary.num_features = 3;
    out.*.secondary.device_type = c.GHOSTTY_DA_DEVICE_TYPE_VT220;
    out.*.secondary.firmware_version = 1;
    out.*.secondary.rom_cartridge = 0;
    out.*.tertiary.unit_id = 0;
    return true;
}

fn colorScheme(_: c.GhosttyTerminal, ud: ?*anyopaque, out: [*c]c.GhosttyColorScheme) callconv(.c) bool {
    out.* = if (self(ud).dark) c.GHOSTTY_COLOR_SCHEME_DARK else c.GHOSTTY_COLOR_SCHEME_LIGHT;
    return true;
}

fn titleChanged(_: c.GhosttyTerminal, ud: ?*anyopaque) callconv(.c) void {
    self(ud).title_changed = true;
}

test "the opacity OSC, split across writes, set and clamped" {
    var v: Vt = undefined;
    try v.init(10, 4, 8, 16, theme_mod.rose_pine, .{});
    defer v.deinit();
    v.feed("\x1b]77");
    v.feed("01;background-opacity=9");
    v.feed("0\x1b\\");
    try std.testing.expectEqual(@as(u8, 90), v.opacity);
    v.feed("\x1b]7701;background-opacity=10\x07");
    try std.testing.expectEqual(@as(u8, 80), v.opacity);
}
