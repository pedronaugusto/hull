//! hull-protocol's promises: a message written reads back as the same
//! message, and lines arrive whole however the bytes are cut, none longer
//! than `max_line` held.
const std = @import("std");
const shakedown = @import("shakedown");
const protocol = @import("hull_protocol.zig");

const testing = std.testing;
const gen = shakedown.gen;

fn message(s: *shakedown.Source, a: std.mem.Allocator) !protocol.Message {
    const names = [_][]const u8{ "theme", "background_opacity", "font_size", "padding", "fullscreen", "x\"y", "é" };
    const values = [_]protocol.Value{ .{ .number = "90" }, .{ .number = "0.5" }, .{ .number = "-3" }, .{ .string = "rose-pine" }, .{ .boolean = true }, .{ .boolean = false } };
    return switch (gen.intRange(s, u8, 0, 4)) {
        0 => blk: {
            const settings = try a.alloc(protocol.Setting, gen.intRange(s, usize, 0, 3));
            for (settings) |*st| st.* = .{
                .name = gen.oneOf(s, []const u8, &names),
                .kind = gen.enumValue(s, protocol.Kind),
                .label = gen.oneOf(s, []const u8, &names),
                .min = if (gen.boolean(s)) 80 else null,
                .max = if (gen.boolean(s)) 100.5 else null,
                .values = if (gen.boolean(s)) &.{ .{ .name = "a", .label = "A" }, .{ .name = "b", .label = "B" } } else null,
                .featured = if (gen.boolean(s)) 1 else null,
                .default = gen.oneOf(s, protocol.Value, &values),
                .value = gen.oneOf(s, protocol.Value, &values),
                .available = gen.boolean(s),
                .reason = if (gen.boolean(s)) "Full screen is always opaque" else null,
            };
            break :blk .{ .hello = .{ .hull = "0.0.0", .app = "dev.example", .settings = settings } };
        },
        1 => .{ .set = .{ .name = gen.oneOf(s, []const u8, &names), .value = gen.oneOf(s, protocol.Value, &values) } },
        2 => .{ .refused = .{ .name = gen.oneOf(s, []const u8, &names), .reason = "Not now" } },
        3 => .{ .changed = .{ .setting = .{ .name = "theme", .kind = .choice, .label = "Theme", .default = values[3], .value = gen.oneOf(s, protocol.Value, &values) } } },
        else => .get,
    };
}

test "any message written reads back as itself" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const m = try message(case.source, a);
            var first: std.Io.Writer.Allocating = .init(a);
            try protocol.write(&first.writer, m);
            const line = first.written();
            try testing.expect(std.mem.endsWith(u8, line, "\n"));
            try testing.expectEqual(1, std.mem.countScalar(u8, line, '\n'));
            const back = try protocol.read(a, line[0 .. line.len - 1]);
            try testing.expectEqual(std.meta.activeTag(m), std.meta.activeTag(back));
            var second: std.Io.Writer.Allocating = .init(a);
            try protocol.write(&second.writer, back);
            try testing.expectEqualStrings(line, second.written());
        }
    }.one, .{ .cases = 2000, .seed = 0x4011 });
}

test "lines arrive whole however the bytes are cut, and one past max_line is refused" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            var lines: std.ArrayList([]const u8) = .empty;
            var stream: std.ArrayList(u8) = .empty;
            for (0..gen.intRange(s, usize, 0, 6)) |_| {
                const line = try a.alloc(u8, gen.intRange(s, usize, 0, 40));
                for (line) |*c| c.* = gen.oneOf(s, u8, "ab{}\" ");
                try lines.append(a, line);
                try stream.appendSlice(a, line);
                try stream.append(a, '\n');
            }
            var l: protocol.Lines = .{};
            defer l.deinit(testing.allocator);
            var scratch: std.ArrayList(u8) = .empty;
            defer scratch.deinit(testing.allocator);
            var got: std.ArrayList([]const u8) = .empty;
            var at: usize = 0;
            while (at < stream.items.len) {
                const n = @min(gen.intRange(s, usize, 1, 17), stream.items.len - at);
                try l.feed(testing.allocator, stream.items[at..][0..n]);
                at += n;
                while (try l.next(&scratch, testing.allocator)) |line| try got.append(a, try a.dupe(u8, line));
            }
            try testing.expectEqual(lines.items.len, got.items.len);
            for (lines.items, got.items) |want, have| try testing.expectEqualStrings(want, have);
            // A line that does not end within max_line is refused.
            const long = try a.alloc(u8, protocol.max_line + 1);
            @memset(long, 'x');
            try testing.expectError(error.LineTooLong, l.feed(testing.allocator, long));
        }
    }.one, .{ .cases = 2000, .seed = 0x4012 });
}
