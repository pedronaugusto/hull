//! hull.zon's promise about opacity: whatever byte is written, the
//! background opacity read is within 80 to 100, the value written where it
//! is already. (Refusals log what is wrong for the person reading, so they
//! are left to the parse's fuzz target, which asks only that nothing
//! crashes.)
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
            const app = try config.parse(testing.allocator, a, source);
            try testing.expectEqual(std.math.clamp(opacity, 80, 100), app.terminal.background_opacity);
            try testing.expectEqualStrings(name, app.terminal.theme);
        }
    }.one, .{ .cases = 1000, .seed = 0x2011 });
}
