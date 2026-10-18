//! Themes hull knows by name: the terminal's default colours, which the
//! program reads back with OSC 4, 10 and 11 and may replace with the same.
const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn hex(comptime s: []const u8) Rgb {
        @setEvalBranchQuota(10000);
        const v = std.fmt.parseInt(u24, s[1..], 16) catch unreachable; // unreachable: the themes' colours are written in this file as #rrggbb
        return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
    }
};

pub const Theme = struct {
    name: []const u8,
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

fn h(comptime s: []const u8) Rgb {
    return Rgb.hex(s);
}

/// Rosé Pine, hull's default: rosepinetheme.com's terminal palette.
pub const rose_pine: Theme = .{
    .name = "rose-pine",
    .background = h("#191724"),
    .foreground = h("#e0def4"),
    .cursor = h("#e0def4"),
    .ansi = .{
        h("#26233a"), h("#eb6f92"), h("#31748f"), h("#f6c177"), h("#9ccfd8"), h("#c4a7e7"), h("#ebbcba"), h("#e0def4"),
        h("#6e6a86"), h("#eb6f92"), h("#31748f"), h("#f6c177"), h("#9ccfd8"), h("#c4a7e7"), h("#ebbcba"), h("#e0def4"),
    },
    .dark = true,
};

/// Rosé Pine Moon.
pub const rose_pine_moon: Theme = .{
    .name = "rose-pine-moon",
    .background = h("#232136"),
    .foreground = h("#e0def4"),
    .cursor = h("#e0def4"),
    .ansi = .{
        h("#393552"), h("#eb6f92"), h("#3e8fb0"), h("#f6c177"), h("#9ccfd8"), h("#c4a7e7"), h("#ea9a97"), h("#e0def4"),
        h("#6e6a86"), h("#eb6f92"), h("#3e8fb0"), h("#f6c177"), h("#9ccfd8"), h("#c4a7e7"), h("#ea9a97"), h("#e0def4"),
    },
    .dark = true,
};

/// Rosé Pine Dawn, the light one.
pub const rose_pine_dawn: Theme = .{
    .name = "rose-pine-dawn",
    .background = h("#faf4ed"),
    .foreground = h("#575279"),
    .cursor = h("#575279"),
    .ansi = .{
        h("#f2e9e1"), h("#b4637a"), h("#286983"), h("#ea9d34"), h("#56949f"), h("#907aa9"), h("#d7827e"), h("#575279"),
        h("#9893a5"), h("#b4637a"), h("#286983"), h("#ea9d34"), h("#56949f"), h("#907aa9"), h("#d7827e"), h("#575279"),
    },
    .dark = false,
};

pub const all = [_]*const Theme{ &rose_pine, &rose_pine_moon, &rose_pine_dawn };

pub fn byName(name: []const u8) ?*const Theme {
    for (all) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

test "palette keeps the theme's sixteen and xterm's cube" {
    const p = rose_pine.palette();
    try std.testing.expectEqual(rose_pine.ansi[1], p[1]);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, p[231]);
    try std.testing.expectEqual(Rgb{ .r = 238, .g = 238, .b = 238 }, p[255]);
}
