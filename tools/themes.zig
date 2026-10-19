//! Ghostty's themes as a Zig table, made where hull is built:
//!
//!     hull-themes <themes-dir> <out.zig>
//!
//! The folder is the one Ghostty ships, from iTerm2-Color-Schemes: a file a
//! theme, named as people know it, of Ghostty's own `key = value` lines. Each
//! becomes an entry: its name as hull's settings and hull.zon say it
//! (`Rose Pine Dawn` is `rose-pine-dawn`, a `+` is `-plus`), the file's name
//! as its label, and its background, foreground, cursor and sixteen colours.
//! Rosé Pine comes first, hull's own, then the rest by name.
const std = @import("std");

const Io = std.Io;
const Dir = Io.Dir;

const first = [_][]const u8{ "Rose Pine", "Rose Pine Moon", "Rose Pine Dawn" };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.log.err("usage: hull-themes <themes-dir> <out.zig>", .{});
        return error.Usage;
    }
    var dir = try Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| if (e.kind == .file and !std.mem.endsWith(u8, e.name, ".md")) try names.append(arena, try arena.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, before);
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(
        \\//! Written by hull-themes from Ghostty's themes; not edited by hand.
        \\pub const Entry = struct { name: []const u8, label: []const u8, background: u24, foreground: u24, cursor: u24, ansi: [16]u24 };
        \\pub const all = [_]Entry{
        \\
    );
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (names.items) |label| {
        const name = try slug(arena, label);
        if ((try seen.getOrPut(arena, name)).found_existing) return refuse(label, "names a theme another file names");
        const bytes = try dir.readFileAlloc(io, label, arena, .limited(64 << 10));
        var why: []const u8 = "";
        const t = parse(bytes, &why) catch return refuse(label, why);
        try w.print("    .{{ .name = \"{s}\", .label = \"{f}\", .background = 0x{x:0>6}, .foreground = 0x{x:0>6}, .cursor = 0x{x:0>6}, .ansi = .{{", .{ name, std.zig.fmtString(label), t.background, t.foreground, t.cursor });
        for (t.ansi, 0..) |c, i| try w.print("{s}0x{x:0>6}", .{ if (i == 0) " " else ", ", c });
        try w.writeAll(" } },\n");
    }
    try w.writeAll("};\n");
    try Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

// Rosé Pine first, in its order; the rest by name, case aside.
fn before(_: void, a: []const u8, b: []const u8) bool {
    const ra = rank(a);
    const rb = rank(b);
    if (ra != rb) return ra < rb;
    return std.ascii.lessThanIgnoreCase(a, b);
}

fn rank(label: []const u8) usize {
    for (first, 0..) |f, i| if (std.mem.eql(u8, f, label)) return i;
    return first.len;
}

// `Rose Pine Dawn` as `rose-pine-dawn`: lower case, `+` as `plus`, every other run of what is not a letter or a
// digit one `-`.
fn slug(a: std.mem.Allocator, label: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var gap = false;
    for (label) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (gap and out.items.len > 0) try out.append(a, '-');
            gap = false;
            try out.append(a, std.ascii.toLower(c));
        } else if (c == '+') {
            if (out.items.len > 0) try out.append(a, '-');
            try out.appendSlice(a, "plus");
            gap = false;
        } else gap = true;
    }
    if (out.items.len == 0) return error.UnnamedTheme;
    return out.items;
}

const Parsed = struct { background: u24, foreground: u24, cursor: u24, ansi: [16]u24 };

// A theme file's colours: every one of the sixteen, the background and the foreground; the cursor the foreground's
// where it names none.
fn parse(bytes: []const u8, why: *[]const u8) error{BadTheme}!Parsed {
    var bg: ?u24 = null;
    var fg: ?u24 = null;
    var cursor: ?u24 = null;
    var ansi: [16]?u24 = @splat(null);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (std.mem.eql(u8, key, "palette")) {
            const at = std.mem.findScalar(u8, value, '=') orelse return fail(why, "has a palette line without its index");
            const i = std.fmt.parseInt(u8, value[0..at], 10) catch return fail(why, "has a palette index that is not a number");
            if (i < 16) ansi[i] = try colour(why, value[at + 1 ..]);
        } else if (std.mem.eql(u8, key, "background")) {
            bg = try colour(why, value);
        } else if (std.mem.eql(u8, key, "foreground")) {
            fg = try colour(why, value);
        } else if (std.mem.eql(u8, key, "cursor-color")) {
            cursor = try colour(why, value);
        }
    }
    var p: Parsed = .{ .background = bg orelse return fail(why, "has no background"), .foreground = fg orelse return fail(why, "has no foreground"), .cursor = undefined, .ansi = undefined };
    p.cursor = cursor orelse p.foreground;
    for (&p.ansi, ansi) |*o, c| o.* = c orelse return fail(why, "lacks one of the sixteen colours");
    return p;
}

fn colour(why: *[]const u8, v: []const u8) error{BadTheme}!u24 {
    if (v.len != 7 or v[0] != '#') return fail(why, "has a colour that is not #rrggbb");
    return std.fmt.parseInt(u24, v[1..], 16) catch fail(why, "has a colour that is not #rrggbb");
}

fn fail(why: *[]const u8, what: []const u8) error{BadTheme} {
    why.* = what;
    return error.BadTheme;
}

fn refuse(label: []const u8, what: []const u8) error{BadTheme} {
    std.log.err("theme '{s}' {s}", .{ label, what });
    return error.BadTheme;
}

test "a theme's name is its label, as hull says it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("rose-pine-dawn", try slug(a, "Rose Pine Dawn"));
    try std.testing.expectEqualStrings("dracula-plus", try slug(a, "Dracula+"));
    try std.testing.expectEqualStrings("iterm2-solarized-dark", try slug(a, "iTerm2 Solarized Dark"));
    try std.testing.expect(before({}, "Rose Pine Dawn", "Aardvark Blue"));
    try std.testing.expect(before({}, "aardvark", "Zenburn"));
}

test "a theme file read, and one that lacks a colour refused" {
    var file: [16 * 24 + 64]u8 = undefined;
    var w: Io.Writer = .fixed(&file);
    for (0..16) |i| try w.print("palette = {d}=#0000{x:0>2}\n", .{ i, i });
    try w.writeAll("background = #faf4ed\nforeground = #575279\n");
    var why: []const u8 = "";
    const t = try parse(w.buffered(), &why);
    try std.testing.expectEqual(@as(u24, 0xfaf4ed), t.background);
    try std.testing.expectEqual(t.foreground, t.cursor);
    try std.testing.expectEqual(@as(u24, 0x00000f), t.ansi[15]);
    try std.testing.expectError(error.BadTheme, parse("background = #000000\nforeground = #ffffff\n", &why));
    try std.testing.expectEqualStrings("lacks one of the sixteen colours", why);
}
