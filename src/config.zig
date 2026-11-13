//! An app's hull.zon: who the app is, its program, its window policy and its
//! terminal. The app sets all of it; nothing comes from the user's terminal
//! configuration, because hull is not their terminal.
const std = @import("std");
const theme = @import("theme.zig");

pub const App = struct {
    /// The app's name: the bundle's, the window's title and the menu's.
    name: []const u8 = "hull",
    /// Reverse-DNS bundle identifier.
    id: []const u8 = "dev.hull.app",
    version: []const u8 = "0.0.0",
    /// The program and its arguments. In an app, a bare name is the program
    /// its build bundled, and none at all runs that program alone.
    program: []const []const u8 = &.{},
    window: Window = .{},
    terminal: Terminal = .{},
};

/// What hull's window allows. One window and nothing a terminal adds,
/// unless the app asks.
pub const Window = struct {
    /// The size the window opens at, in cells.
    cols: u16 = 100,
    rows: u16 = 30,
    resizable: bool = true,
    /// The smallest the window may be, in cells.
    min_cols: u16 = 40,
    min_rows: u16 = 12,
    /// Tabs, each its own program on its own terminal: off. An app that
    /// wants them turns them on; the spike does not build them.
    tabs: bool = false,
    /// Whether ⌘N opens a second window of the same app: off. One program
    /// per window either way.
    new_windows: bool = false,
    /// The window closes, and the app quits, when the program ends.
    quit_with_program: bool = true,
    /// A title the program sets (OSC 0 or 2) is the window's: off, so the
    /// window, the Dock and the menus carry the app's name alone.
    program_title: bool = false,
    /// ⌘Q and the close button send this to the program (as the key it is)
    /// instead of quitting at once, so a game can save first; null quits.
    close_key: ?[]const u8 = null,
};

pub const CursorStyle = enum { block, bar, underline, block_hollow };

/// The terminal hull draws: Ghostty's settings that matter to an app.
pub const Terminal = struct {
    /// Points; the cell is measured from the face at this size.
    font_size: f32 = 14,
    /// A TrueType/OpenType file beside hull.zon, or null for hull's own
    /// JetBrains Mono. Bold and italic are derived from it when absent.
    font: ?[]const u8 = null,
    font_bold: ?[]const u8 = null,
    font_italic: ?[]const u8 = null,
    font_bold_italic: ?[]const u8 = null,
    /// Faces tried, in order, for a character the font lacks (absolute
    /// paths, or beside hull.zon); one missing is skipped. hull has no
    /// system font discovery yet: these stand in for it.
    font_fallback: []const []const u8 = &.{
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Apple Symbols.ttf",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    },
    /// Extra space between cells, in points (Ghostty's adjust-cell-*).
    adjust_cell_width: f32 = 0,
    adjust_cell_height: f32 = 0,
    /// A theme hull knows by name (theme.zig), any of Ghostty's: rose-pine by default.
    theme: []const u8 = "rose-pine",
    /// The app's short list of themes, which its settings page offers first, in this order; every other one of
    /// Ghostty's follows. A name hull does not know is refused when the app is packaged.
    featured_themes: []const []const u8 = &.{ "rose-pine", "rose-pine-moon", "rose-pine-dawn" },
    /// Overrides of the theme: "#rrggbb".
    background: ?[]const u8 = null,
    foreground: ?[]const u8 = null,
    cursor_color: ?[]const u8 = null,
    palette: []const PaletteEntry = &.{},
    /// Space around the grid, in points; leftover pixels are shared out
    /// evenly (Ghostty's window-padding-balance).
    padding_x: u16 = 8,
    padding_y: u16 = 8,
    /// Percent, 80 to 100: how much of the window's background is drawn,
    /// while the window is windowed; full screen is always opaque, and the
    /// value waits for the window's return. Text and pictures are always
    /// whole; a picture's transparent ground shows this same background.
    background_opacity: u8 = 100,
    cursor_style: CursorStyle = .block,
    cursor_blink: bool = false,
    /// Option as Alt on macOS (Ghostty's macos-option-as-alt).
    option_as_alt: bool = true,
    /// Rows kept above the screen; a full-screen program keeps none.
    scrollback: u32 = 0,
    /// Draw bold text in the bright colours (Ghostty's bold-is-bright).
    bold_is_bright: bool = false,
};

/// The background opacity there may be: 80 to 100.
pub const opacity_min = 80;
pub const opacity_max = 100;

pub fn clampOpacity(v: i64) u8 {
    return @intCast(std.math.clamp(v, opacity_min, opacity_max));
}

pub const PaletteEntry = struct { index: u8, color: []const u8 };

/// Parses hull.zon. Strings live in `arena`.
pub fn parse(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: [:0]const u8) !App {
    var diag: std.zon.parse.Diagnostics = undefined;
    var app_ = std.zon.parse.fromSlice(App, .{ .gpa = gpa, .arena = arena, .source = source, .diagnostics = &diag }) catch |err| {
        if (err == error.ParseZon) diag.log("hull.zon");
        return err;
    };
    app_.terminal.background_opacity = clampOpacity(app_.terminal.background_opacity);
    for ([_][]const []const u8{ &.{app_.terminal.theme}, app_.terminal.featured_themes }) |names| for (names) |n| if (theme.byName(n) == null) {
        std.log.err("hull.zon: no theme is named '{s}': Ghostty's names, lower case, words joined by '-'", .{n});
        return error.UnknownTheme;
    };
    return app_;
}

/// The colours an app's terminal starts with: its theme with its overrides.
pub fn colors(t: Terminal) !theme.Theme {
    var th = (theme.byName(t.theme) orelse return error.UnknownTheme).*;
    if (t.background) |s| th.background = try rgb(s);
    if (t.foreground) |s| th.foreground = try rgb(s);
    if (t.cursor_color) |s| th.cursor = try rgb(s);
    for (t.palette) |p| if (p.index < 16) {
        th.ansi[p.index] = try rgb(p.color);
    };
    return th;
}

fn rgb(s: []const u8) !theme.Rgb {
    if (s.len != 7 or s[0] != '#') return error.BadColor;
    const v = try std.fmt.parseInt(u24, s[1..], 16);
    return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
}

test "parse an app" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const app = try parse(std.testing.allocator, arena.allocator(),
        \\.{ .name = "Example", .program = .{"example"}, .terminal = .{ .font_size = 16, .background_opacity = 50 } }
    );
    try std.testing.expectEqualStrings("Example", app.name);
    try std.testing.expectEqual(@as(f32, 16), app.terminal.font_size);
    try std.testing.expectEqual(@as(u8, 80), app.terminal.background_opacity);
    try std.testing.expect(!app.window.tabs);
}

test "any hull.zon parses or is refused, never crashes" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [2048:0]u8 = undefined;
            const seed = ".{ .name = \"Example\", .window = .{ .cols = 100 }, .terminal = .{ .theme = \"rose-pine\" } }";
            @memcpy(input[0..seed.len], seed);
            const n = smith.sliceWithHash(input[seed.len..], 0);
            input[seed.len + n] = 0;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            _ = parse(std.testing.allocator, arena.allocator(), input[0 .. seed.len + n :0]) catch return;
        }
    }.one, .{});
}

test {
    _ = @import("config_test.zig");
}
