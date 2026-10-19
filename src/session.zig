//! One program in one terminal: the program, its terminal, the faces it is
//! drawn in and where the grid sits. The window and the headless runner
//! both drive this; neither knows the other.
const std = @import("std");
const config = @import("config.zig");
const theme = @import("theme.zig");
const font = @import("font.zig");
const render = @import("render.zig");
const vt_mod = @import("vt.zig");
const Program = @import("Program.zig");

pub const Vt = vt_mod.Vt;
const c = vt_mod.c;

/// Nanoseconds on the awake clock, the one AppKit's event timestamps are on (CLOCK_UPTIME_RAW on macOS).
pub fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds); // safe: the awake clock counts up from boot
}

/// Variables that would tell the program it runs in another terminal.
const foreign = [_][]const u8{
    "TMUX",        "TMUX_PANE",           "STY",          "TERM_SESSION_ID", "VTE_VERSION",  "WT_SESSION",
    "LC_TERMINAL", "LC_TERMINAL_VERSION", "INSIDE_EMACS", "TERMINFO",        "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
    "COLORTERM",   "TERM",
};
const foreign_prefixes = [_][]const u8{ "KITTY_", "GHOSTTY_", "ITERM_", "WEZTERM_", "ALACRITTY_", "KONSOLE_", "HULL_" };

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: config.App,
    fonts: font.Fonts,
    vt: Vt,
    program: Program = undefined,
    font_bytes: font.Fonts.Bytes,
    fallback: []const []const u8,
    /// Bumped when the faces change: the renderer's atlas starts over.
    font_epoch: u32 = 0,
    spawned: bool = false,
    ended: bool = false,
    /// Device pixels per point.
    scale: f32,
    layout: render.Layout,
    /// The canvas size, device pixels.
    w: u32,
    h: u32,
    started_ns: u64,
    first_frame_ns: ?u64 = null,
    first_image_ns: ?u64 = null,
    /// Bytes the program has written.
    output_bytes: u64 = 0,

    /// A session for `app` at `scale` device pixels per point, its window
    /// `cols`×`rows` cells. The program is not started yet.
    pub fn init(s: *Session, gpa: std.mem.Allocator, io: std.Io, app: config.App, font_bytes: font.Fonts.Bytes, fallback: []const []const u8, scale: f32) !void {
        const t = app.terminal;
        const th = try config.colors(t);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .app = app,
            .fonts = try font.Fonts.init(gpa, font_bytes, fallback, t.font_size * scale, t.adjust_cell_width * scale, t.adjust_cell_height * scale),
            .vt = undefined,
            .font_bytes = font_bytes,
            .fallback = fallback,
            .scale = scale,
            .layout = undefined,
            .w = 0,
            .h = 0,
            .started_ns = now(io),
        };
        errdefer s.fonts.deinit();
        const cw = s.fonts.cell_w;
        const ch = s.fonts.cell_h;
        const px = padX(s);
        const py = padY(s);
        s.w = app.window.cols * cw + 2 * px;
        s.h = app.window.rows * ch + 2 * py;
        s.layout = .{ .pad_x = px, .pad_y = py, .cell_w = cw, .cell_h = ch, .scale = scale };
        try s.vt.init(app.window.cols, app.window.rows, cw, ch, th, t);
    }

    pub fn deinit(s: *Session) void {
        if (s.spawned) s.program.stop();
        s.vt.deinit();
        s.fonts.deinit();
    }

    fn padX(s: *const Session) u32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(s.app.terminal.padding_x)) * s.scale));
    }
    fn padY(s: *const Session) u32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(s.app.terminal.padding_y)) * s.scale));
    }

    /// Starts the program: its argv, in `cwd`, with the parent's environment
    /// less any other terminal's, and hull's own. `wake` is called from
    /// another task when the program has written or said something.
    pub fn spawn(s: *Session, argv: []const []const u8, parent_env: *const std.process.Environ.Map, cwd: ?[]const u8, wake: ?Program.Wake) !void {
        var env: std.process.Environ.Map = .init(s.gpa);
        defer env.deinit();
        var it = parent_env.iterator();
        outer: while (it.next()) |e| {
            for (foreign) |k| if (std.mem.eql(u8, e.key_ptr.*, k)) continue :outer;
            for (foreign_prefixes) |p| if (std.mem.startsWith(u8, e.key_ptr.*, p)) continue :outer;
            try env.put(e.key_ptr.*, e.value_ptr.*);
        }
        // What the program may know: that it runs in hull, as which app, and
        // the settings hull owns that a program may offer its player.
        const own = [_][2][]const u8{
            .{ "TERM", "xterm-256color" },
            .{ "COLORTERM", "truecolor" },
            .{ "TERM_PROGRAM", "hull" },
            .{ "TERM_PROGRAM_VERSION", vt_mod.version },
            .{ "HULL", vt_mod.version },
            .{ "HULL_APP", s.app.id },
            .{ "HULL_THEME", s.app.terminal.theme },
        };
        for (own) |kv| try env.put(kv[0], kv[1]);
        if (parent_env.get("LANG") == null) try env.put("LANG", "en_US.UTF-8");
        try s.program.start(s.gpa, s.io, .{ .argv = argv, .environ = &env, .cwd = cwd, .size = s.winsize(), .wake = wake });
        s.spawned = true;
        s.vt.program = &s.program;
    }

    fn winsize(s: *const Session) Program.Size {
        return .{
            .rows = s.vt.rows,
            .cols = s.vt.cols,
            .x_pixel = @intCast(@min(@as(u32, s.vt.cols) * s.layout.cell_w, 65535)),
            .y_pixel = @intCast(@min(@as(u32, s.vt.rows) * s.layout.cell_h, 65535)),
        };
    }

    /// Reads all the program has written. Whether the program ended.
    pub fn pump(s: *Session) bool {
        if (!s.spawned or s.ended) return s.ended;
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = s.program.take(&buf) orelse {
                s.ended = true;
                return true;
            };
            if (n == 0) return false;
            s.output_bytes += n;
            s.vt.feed(buf[0..n]);
        }
    }

    /// The canvas is now `w`×`h` device pixels: the grid that fits, the
    /// leftover shared out as padding.
    pub fn resize(s: *Session, w: u32, h: u32) void {
        s.w = w;
        s.h = h;
        const cw = s.layout.cell_w;
        const ch = s.layout.cell_h;
        const px = padX(s);
        const py = padY(s);
        const cols: u16 = @intCast(@max(1, (w -| 2 * px) / cw));
        const rows: u16 = @intCast(@max(1, (h -| 2 * py) / ch));
        s.layout.pad_x = (w - @min(w, cols * cw)) / 2;
        s.layout.pad_y = (h - @min(h, rows * ch)) / 2;
        if (cols == s.vt.cols and rows == s.vt.rows and cw == s.vt.cell_w and ch == s.vt.cell_h) return;
        s.vt.resize(cols, rows, cw, ch);
        if (s.spawned) s.program.resize(s.winsize());
    }

    /// The faces at a new size: the cell, and so the grid, follow.
    pub fn setFontSize(s: *Session, pt: f32) !void {
        const t = s.app.terminal;
        const next = try font.Fonts.init(s.gpa, s.font_bytes, s.fallback, pt * s.scale, t.adjust_cell_width * s.scale, t.adjust_cell_height * s.scale);
        s.fonts.deinit();
        s.fonts = next;
        s.app.terminal.font_size = pt;
        s.font_epoch += 1;
        s.layout.cell_w = next.cell_w;
        s.layout.cell_h = next.cell_h;
        s.resize(s.w, s.h);
    }

    pub fn setPadding(s: *Session, pt: u16) void {
        s.app.terminal.padding_x = pt;
        s.app.terminal.padding_y = pt;
        s.resize(s.w, s.h);
    }

    /// A theme's colours as the terminal's defaults, and the program told
    /// if it asked to hear of it (mode 2031): it asks OSC 4/10/11 again.
    pub fn setTheme(s: *Session, th: theme.Theme) void {
        s.vt.setColors(th);
        if (s.vt.mode(c.ghostty_mode_new(2031, false))) s.send(if (th.dark) "\x1b[?997;1n" else "\x1b[?997;2n");
    }

    pub fn send(s: *Session, bytes: []const u8) void {
        if (s.spawned and !s.ended) s.program.write(bytes);
    }

    pub fn key(s: *Session, k: vt_mod.Key) void {
        var buf: [128]u8 = undefined;
        const out = s.vt.encodeKey(k, &buf);
        if (out.len > 0) s.send(out) else if (k.text.len > 0 and k.action != .release) s.send(k.text);
    }

    pub fn focus(s: *Session, focused: bool) void {
        var buf: [16]u8 = undefined;
        s.send(s.vt.encodeFocus(focused, &buf));
    }

    /// Draws and presents a frame through `r`.
    pub fn draw(s: *Session, r: *render.Renderer) render.Stats {
        if (r.epoch != s.font_epoch) {
            r.resetGlyphs();
            r.epoch = s.font_epoch;
        }
        const st = r.draw(&s.vt, &s.fonts, s.w, s.h, s.layout);
        const t = now(s.io);
        if (s.first_frame_ns == null and s.output_bytes > 0) s.first_frame_ns = t;
        if (s.first_image_ns == null and st.images > 0) s.first_image_ns = t;
        return st;
    }
};
