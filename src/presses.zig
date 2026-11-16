//! A keys script for a headless run: "2.0:enter,2.5:right,3:a", each key
//! pressed at its second and released just after. It needs libghostty's
//! key types and nothing else of it, so the fuzz job reads it without
//! building libghostty.
const std = @import("std");
const c = @import("vt");
const Key = @import("key.zig").Key;

/// A key at a moment of the run, in seconds from its start.
pub const Press = struct { at: f64, key: Key };

/// "2.0:enter,2.5:right,3:a": keys at seconds.
pub fn parsePresses(gpa: std.mem.Allocator, spec: []const u8) ![]Press {
    var out: std.ArrayList(Press) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |item| {
        const colon = std.mem.findScalar(u8, item, ':') orelse return error.BadKeys;
        const at = try std.fmt.parseFloat(f64, item[0..colon]);
        const k = named(item[colon + 1 ..]) orelse return error.BadKeys;
        try out.append(gpa, .{ .at = at, .key = k });
        var up = k;
        up.action = .release;
        up.text = "";
        try out.append(gpa, .{ .at = at + 0.03, .key = up });
    }
    return out.toOwnedSlice(gpa);
}

/// A key by name, as a US keyboard makes it, after any of `ctrl+`, `alt+`,
/// `shift+`, `super+`.
pub fn named(spec: []const u8) ?Key {
    var name = spec;
    var mods: c.GhosttyMods = 0;
    const prefixes = [_]struct { []const u8, c.GhosttyMods }{
        .{ "ctrl+", c.GHOSTTY_MODS_CTRL }, .{ "alt+", c.GHOSTTY_MODS_ALT }, .{ "shift+", c.GHOSTTY_MODS_SHIFT }, .{ "super+", c.GHOSTTY_MODS_SUPER },
    };
    outer: while (true) {
        for (prefixes) |p| if (std.mem.startsWith(u8, name, p[0])) {
            name = name[p[0].len..];
            mods |= p[1];
            continue :outer;
        };
        break;
    }
    var k = plain(name) orelse return null;
    k.mods = mods;
    // ctrl and alt make no text of their own; shift makes the capital
    if (mods & (c.GHOSTTY_MODS_CTRL | c.GHOSTTY_MODS_SUPER) != 0) k.text = "" else if (mods & c.GHOSTTY_MODS_SHIFT != 0 and k.text.len == 1 and k.text[0] >= 'a' and k.text[0] <= 'z') {
        k.text = capitals[k.text[0] - 'a' ..][0..1];
        k.consumed = c.GHOSTTY_MODS_SHIFT;
    }
    return k;
}

const capitals = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

fn plain(name: []const u8) ?Key {
    const table = [_]struct { []const u8, c.GhosttyKey, []const u8, u32 }{
        .{ "enter", c.GHOSTTY_KEY_ENTER, "\r", '\r' },
        .{ "escape", c.GHOSTTY_KEY_ESCAPE, "", 0 },
        .{ "tab", c.GHOSTTY_KEY_TAB, "\t", '\t' },
        .{ "space", c.GHOSTTY_KEY_SPACE, " ", ' ' },
        .{ "backspace", c.GHOSTTY_KEY_BACKSPACE, "", 0 },
        .{ "up", c.GHOSTTY_KEY_ARROW_UP, "", 0 },
        .{ "down", c.GHOSTTY_KEY_ARROW_DOWN, "", 0 },
        .{ "left", c.GHOSTTY_KEY_ARROW_LEFT, "", 0 },
        .{ "right", c.GHOSTTY_KEY_ARROW_RIGHT, "", 0 },
    };
    for (table) |e| if (std.mem.eql(u8, name, e[0])) return .{ .action = .press, .key = e[1], .text = e[2], .unshifted = e[3] };
    if (name.len == 1 and name[0] >= 'a' and name[0] <= 'z')
        return .{ .action = .press, .key = @intCast(c.GHOSTTY_KEY_A + @as(c_int, name[0] - 'a')), .text = name, .unshifted = name[0] };
    return null;
}

test "a keys spec refused after a key it read gives back what it read" {
    try std.testing.expectError(error.BadKeys, parsePresses(std.testing.allocator, "1:enter,x"));
    try std.testing.expectError(error.InvalidCharacter, parsePresses(std.testing.allocator, "1:enter,y:enter"));
}

test "any keys spec parses or is refused, never crashes" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [512]u8 = undefined;
            const seed = "1.5:enter,3:ctrl+c,4:right";
            @memcpy(input[0..seed.len], seed);
            const n = smith.sliceWithHash(input[seed.len..], 0);
            const presses = parsePresses(std.testing.allocator, input[0 .. seed.len + n]) catch return;
            std.testing.allocator.free(presses);
        }
    }.one, .{});
}
