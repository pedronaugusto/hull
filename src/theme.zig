//! Themes hull knows by name: the terminal's default colours, which the
//! program reads back with OSC 4, 10 and 11 and may replace with the same.
//! They are Ghostty's own, every one it ships (iTerm2-Color-Schemes), read
//! from the same pinned folder when hull is built (`tools/themes.zig`), so a
//! theme is named as in Ghostty and has its colours: Rosé Pine first, hull's
//! default, then the rest by name.
const std = @import("std");
const ghostty = @import("ghostty_themes");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn hex(comptime s: []const u8) Rgb {
        @setEvalBranchQuota(10000);
        const v = std.fmt.parseInt(u24, s[1..], 16) catch unreachable; // glint-ignore: Z026 -- the themes' colours are written in this file as #rrggbb
        return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
    }
};

pub const Theme = struct {
    /// As hull's settings and hull.zon name it: `rose-pine-dawn`.
    name: []const u8,
    /// As Ghostty names it, which hull's settings show: `Rose Pine Dawn`.
    label: []const u8,
    background: Rgb,
    foreground: Rgb,
    cursor: Rgb,
    /// The sixteen ANSI colours; 16..255 are xterm's cube and greys.
    ansi: [16]Rgb,
    dark: bool,

    /// All 256 entries: the theme's sixteen, then xterm's.
    pub fn palette(t: Theme) [256]Rgb {
        var p: [256]Rgb = undefined;
        @memcpy(p[0..16], &t.ansi);
        const steps = [_]u8{ 0, 95, 135, 175, 215, 255 };
        for (0..216) |i| p[16 + i] = .{ .r = steps[i / 36], .g = steps[(i / 6) % 6], .b = steps[i % 6] };
        for (0..24) |i| {
            const v: u8 = @intCast(8 + 10 * i);
            p[232 + i] = .{ .r = v, .g = v, .b = v };
        }
        return p;
    }
};

/// Every theme, in the order a settings page shows them.
pub const all: [ghostty.all.len]Theme = blk: {
    @setEvalBranchQuota(1_000_000);
    var list: [ghostty.all.len]Theme = undefined;
    for (&list, ghostty.all) |*t, e| {
        var ansi: [16]Rgb = undefined;
        for (&ansi, e.ansi) |*o, c| o.* = of(c);
        t.* = .{ .name = e.name, .label = e.label, .background = of(e.background), .foreground = of(e.foreground), .cursor = of(e.cursor), .ansi = ansi, .dark = dark(of(e.background)) };
    }
    const done = list;
    break :blk done;
};

/// hull's default.
pub const rose_pine: *const Theme = &all[0];

fn of(c: u24) Rgb {
    return .{ .r = @truncate(c >> 16), .g = @truncate(c >> 8), .b = @truncate(c) };
}

// A dark theme is one whose background is darker than middle grey.
fn dark(c: Rgb) bool {
    return 2126 * @as(u32, c.r) + 7152 * @as(u32, c.g) + 722 * @as(u32, c.b) < 10000 * 255 / 2;
}

pub fn byName(name: []const u8) ?*const Theme {
    for (&all) |*t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

test "Ghostty's themes, Rosé Pine first, each found by its name" {
    try std.testing.expectEqualStrings("rose-pine", rose_pine.name);
    try std.testing.expectEqualStrings("Rose Pine Dawn", byName("rose-pine-dawn").?.label);
    try std.testing.expect(!byName("rose-pine-dawn").?.dark);
    try std.testing.expect(byName("catppuccin-mocha").?.dark);
    try std.testing.expect(all.len > 100);
}

test "palette keeps the theme's sixteen and xterm's cube" {
    const p = rose_pine.palette();
    try std.testing.expectEqual(rose_pine.ansi[1], p[1]);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, p[231]);
    try std.testing.expectEqual(Rgb{ .r = 238, .g = 238, .b = 238 }, p[255]);
}
