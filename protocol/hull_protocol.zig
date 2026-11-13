//! hull-protocol: how a program inside hull sees hull's settings, and
//! changes them. std and strand alone: no terminal, no window.
//!
//! hull hands the program its end of a conduit `Channel` (a socket on POSIX,
//! a duplex pipe on Windows) and names it in the environment: `HULL_SOCKET`,
//! which a program opens with `conduit.tty.Channel.inherited`. Its presence
//! is how a program learns it runs in hull; in a plain terminal it is absent and nothing here applies.
//! Over it go newline-framed JSON lines, one `Message` each, tagged by
//! `kind`:
//!
//!     hull → program  {"kind":"hello","protocol":1,"hull":"0.0.0","app":"…","settings":[…]}
//!     program → hull  {"kind":"set","name":"background_opacity","value":90}
//!     hull → program  {"kind":"changed","setting":{…}}           any change, whoever made it
//!     hull → program  {"kind":"refused","name":"…","reason":"…"}
//!     program → hull  {"kind":"get"}                              hello again
//!
//! A setting carries everything a settings page needs to draw it: its kind,
//! range or values, default, current value, hull's own words for it, and
//! whether it is available now (and why not, in hull's words). Availability
//! changes at run time (full screen makes background opacity unavailable);
//! hull says so with `changed`. A program may reword a setting by its name.
const std = @import("std");
const strand = @import("strand");

pub const protocol_version = 1;

/// The environment variable that names the channel, as conduit names a channel's end: its descriptor or handle.
pub const env_name = "HULL_SOCKET";

/// Any JSON value: a number, a string or a boolean here.
pub const Value = strand.json.Value;

pub const Kind = enum { choice, integer, number, toggle };

/// One of a choice's values: its name, and hull's words for it.
pub const Choice = struct { name: []const u8, label: []const u8 };

pub const Setting = struct {
    name: []const u8,
    kind: Kind,
    /// hull's words for it; a program may use its own, by `name`.
    label: []const u8,
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    /// A choice's values, or a toggle's two in hull's words, off first.
    values: ?[]const Choice = null,
    /// A long choice's short list: how many of `values`, from the first, the app offers first. A page steps
    /// through these, and finds any of the rest by searching.
    featured: ?u32 = null,
    default: Value,
    value: Value,
    /// Whether it can be changed now. A value set while unavailable is
    /// kept and applies when it is available again.
    available: bool = true,
    /// Why not, in hull's words, when unavailable.
    reason: ?[]const u8 = null,
};

pub const Hello = struct {
    protocol: u32 = protocol_version,
    hull: []const u8,
    app: []const u8,
    settings: []const Setting,
};

pub const Set = struct { name: []const u8, value: Value };
pub const Changed = struct { setting: Setting };
pub const Refused = struct { name: []const u8, reason: []const u8 };

pub const Message = union(enum) {
    hello: Hello,
    set: Set,
    changed: Changed,
    refused: Refused,
    get,

    pub const strand = .{ .tag = "kind" };
};

/// One message as one line, newline included.
pub fn write(w: *std.Io.Writer, m: Message) !void {
    try strand.json.write(w, m, .{ .nulls = .omit });
    try w.writeByte('\n');
}

/// One line (without its newline) as a message, its strings on `arena`.
pub fn read(arena: std.mem.Allocator, line: []const u8) !Message {
    return strand.json.parseLeaky(Message, arena, line, .{ .ignore_unknown_fields = true });
}

/// A number value, written as JSON writes it.
pub fn number(buf: []u8, v: f64) Value {
    const s = std.mem.print(buf, "{d}", .{v}) catch "0";
    return .{ .number = s };
}

/// A value as a number, if it is one.
pub fn asNumber(v: Value) ?f64 {
    return switch (v) {
        .number => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// The longest line either side sends: a hello with every setting, Ghostty's six hundred themes among them, is
/// some forty kilobytes.
pub const max_line = 256 << 10;

/// Lines from the channel, however they arrive, each at most `max_line`: the other side's bytes are never
/// believed, so a line that does not end in time is refused rather than held.
pub const Lines = struct {
    buf: std.ArrayList(u8) = .empty,

    pub const Error = error{ OutOfMemory, LineTooLong };

    pub fn deinit(l: *Lines, gpa: std.mem.Allocator) void {
        l.buf.deinit(gpa);
    }

    /// `bytes` after what came before. On `LineTooLong`, what was held is dropped: the channel is out of step.
    pub fn feed(l: *Lines, gpa: std.mem.Allocator, bytes: []const u8) Error!void {
        try l.buf.appendSlice(gpa, bytes);
        const start = if (std.mem.findScalarLast(u8, l.buf.items, '\n')) |nl| nl + 1 else 0;
        if (l.buf.items.len - start > max_line) {
            l.buf.clearRetainingCapacity();
            return error.LineTooLong;
        }
    }

    /// The next whole line, valid until the next call; null when none.
    pub fn next(l: *Lines, scratch: *std.ArrayList(u8), gpa: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        const nl = std.mem.findScalar(u8, l.buf.items, '\n') orelse return null;
        scratch.clearRetainingCapacity();
        try scratch.appendSlice(gpa, l.buf.items[0..nl]);
        const rest = l.buf.items.len - nl - 1;
        @memmove(l.buf.items[0..rest], l.buf.items[nl + 1 ..]);
        l.buf.shrinkRetainingCapacity(rest);
        return scratch.items;
    }
};

test "a hello and a set, there and back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var nb: [32]u8 = undefined;
    const settings = [_]Setting{.{
        .name = "background_opacity",
        .kind = .integer,
        .label = "Background opacity",
        .min = 80,
        .max = 100,
        .step = 1,
        .default = number(&nb, 100),
        .value = number(&nb, 100),
        .available = false,
        .reason = "Full screen is always opaque",
    }};
    try write(&out.writer, .{ .hello = .{ .hull = "0.0.0", .app = "dev.example", .settings = &settings } });
    try write(&out.writer, .{ .set = .{ .name = "background_opacity", .value = .{ .number = "90" } } });
    try write(&out.writer, .get);
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    const hello = try read(a, it.next().?);
    try std.testing.expectEqualStrings("Background opacity", hello.hello.settings[0].label);
    try std.testing.expect(!hello.hello.settings[0].available);
    const set = try read(a, it.next().?);
    try std.testing.expectEqual(@as(?f64, 90), asNumber(set.set.value));
    try std.testing.expect((try read(a, it.next().?)) == .get);
}

test "lines arrive in pieces, and one too long is refused" {
    const gpa = std.testing.allocator;
    var lines: Lines = .{};
    defer lines.deinit(gpa);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    try lines.feed(gpa, "{\"kind\":");
    try std.testing.expectEqual(@as(?[]const u8, null), try lines.next(&scratch, gpa));
    try lines.feed(gpa, "\"get\"}\n{");
    try std.testing.expectEqualStrings("{\"kind\":\"get\"}", (try lines.next(&scratch, gpa)).?);
    const long = try gpa.alloc(u8, max_line + 2);
    defer gpa.free(long);
    @memset(long, 'x');
    try std.testing.expectError(error.LineTooLong, lines.feed(gpa, long));
    try std.testing.expectEqual(@as(?[]const u8, null), try lines.next(&scratch, gpa));
}

test {
    _ = @import("hull_protocol_test.zig");
}
