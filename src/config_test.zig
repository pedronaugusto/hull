//! hull.zon's promises: any bytes read to an app or to what they were
//! refused for, never a crash, each refusal at a place in the input, a
//! theme no one has at the place it is written; and whatever byte is
//! written, the background opacity read is within 80 to 100, the value
//! written where it is already.
const std = @import("std");
const shakedown = @import("shakedown");
const config = @import("config.zig");

const testing = std.testing;

test "any opacity written as a byte reads clamped to 80..100" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const gen = shakedown.gen;
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const opacity = gen.intRange(case.source, u8, 0, 255);
            const name = gen.oneOf(case.source, []const u8, &.{ "rose-pine", "rose-pine-dawn", "dracula" });
            const source = try a.printSentinel(".{{ .name = \"Example\", .terminal = .{{ .background_opacity = {d}, .theme = \"{s}\" }} }}", .{ opacity, name }, 0);
            const app = (try config.parse(testing.allocator, a, source)).app;
            try testing.expectEqual(std.math.clamp(opacity, 80, 100), app.terminal.background_opacity);
            try testing.expectEqualStrings(name, app.terminal.theme);
        }
    }.one, .{ .cases = 1000, .seed = 0x2011 });
}

test "any bytes read to an app or to refusals, each at a place in the input" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const gen = shakedown.gen;
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const names = [_][]const u8{ "rose-pine", "dracula", "Rose Pine", "no-such-theme", "rose\\x2dpine", "" };
            const theme = gen.oneOf(case.source, []const u8, &names);
            const featured = gen.oneOf(case.source, []const u8, &names);
            var bytes: std.ArrayList(u8) = .empty;
            switch (gen.intRange(case.source, u8, 0, 2)) {
                // bytes of any kind
                0 => for (0..gen.intRange(case.source, usize, 0, 200)) |_| try bytes.append(a, gen.intRange(case.source, u8, 1, 255)),
                // a hull.zon over lines, its themes any of a few, some no one has
                1 => try bytes.print(a, ".{{\n  .name = \"Example\",\n  .terminal = .{{\n    .theme = \"{s}\",\n    .featured_themes = .{{ \"{s}\" }},\n  }},\n}}\n", .{ theme, featured }),
                // that hull.zon with bytes changed, cut or added
                else => {
                    try bytes.print(a, ".{{ .name = \"Example\", .window = .{{ .cols = 100 }}, .terminal = .{{ .theme = \"{s}\" }} }}", .{theme});
                    for (0..gen.intRange(case.source, usize, 1, 4)) |_| {
                        const at = gen.intRange(case.source, usize, 0, bytes.items.len - 1);
                        switch (gen.intRange(case.source, u8, 0, 2)) {
                            0 => bytes.items[at] = gen.intRange(case.source, u8, 1, 255),
                            1 => _ = bytes.orderedRemove(at),
                            else => try bytes.insert(a, at, gen.intRange(case.source, u8, 1, 255)),
                        }
                        if (bytes.items.len == 0) break;
                    }
                },
            }
            const source = try a.dupeSentinel(u8, bytes.items, 0);
            switch (try config.parse(testing.allocator, a, source)) {
                .app => |app| try testing.expect(app.terminal.background_opacity >= 80 and app.terminal.background_opacity <= 100),
                .refused => |refusals| {
                    try testing.expect(refusals.len > 0);
                    for (refusals) |r| {
                        const line = lineOf(source, r.line) orelse return error.TestRefusalPastTheLines;
                        try testing.expect(r.column >= 1 and r.column <= line.len + 1);
                        // a theme no one has is refused where its name is written
                        if (std.mem.startsWith(u8, r.message, "no theme is named")) {
                            try testing.expect(std.mem.startsWith(u8, line[r.column - 1 ..], "\""));
                        }
                    }
                },
            }
        }

        // Line `n` of `source`, from 1, without its line feed.
        fn lineOf(source: []const u8, n: usize) ?[]const u8 {
            if (n == 0) return null;
            var lines = std.mem.splitScalar(u8, source, '\n');
            for (1..n) |_| _ = lines.next() orelse return null;
            return lines.next();
        }
    }.one, .{ .cases = 3000, .seed = 0x2012 });
}
