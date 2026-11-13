//! What a window reports about itself when asked: its own frame as a PNG,
//! the memory it holds, and the spread of what it measured.
const std = @import("std");
const builtin = @import("builtin");
const Span = @import("session.zig").Span;

pub fn saveSnap(gpa: std.mem.Allocator, io: std.Io, path: []const u8, px: []u32, w: u32, h: u32) !void {
    const png = @import("png.zig");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try png.write(gpa, .{ .px = px, .w = w, .h = h }, &out.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
    std.log.info("{s}: the window's frame, {d}x{d} px", .{ path, w, h });
}

pub const RusageInfoV2 = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    start_abstime: u64,
    exit_abstime: u64,
    rest: [32]u64,
};
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageInfoV2) c_int;
pub extern "c" fn getpid() c_int;

pub fn usage(pid: c_int) ?RusageInfoV2 {
    if (builtin.os.tag != .macos) return null;
    var ri: RusageInfoV2 = undefined;
    if (proc_pid_rusage(pid, 2, &ri) != 0) return null;
    return ri;
}

/// The spread of `xs`, sorted here, as one line in milliseconds.
pub fn stat(o: *std.Io.Writer, name: []const u8, xs: []Span) !void {
    if (xs.len == 0) return o.print("{s}: none\n", .{name});
    std.mem.sort(Span, xs, {}, shorter);
    var sum: Span = .fromRaw(0);
    for (xs) |x| sum = sum.saturatingAdd(x);
    const mean = try sum.divTrunc(@intCast(xs.len)); // safe: a count of samples fits an i96
    try o.print("{s}: n={d} mean {d:.2} ms, p50 {d:.2}, p95 {d:.2}, max {d:.2}\n", .{ name, xs.len, ms(mean), ms(xs[xs.len / 2]), ms(xs[@min(xs.len - 1, xs.len * 95 / 100)]), ms(xs[xs.len - 1]) });
}

fn shorter(_: void, a: Span, b: Span) bool {
    return a.compare(b) == .lt;
}

fn ms(span: Span) f64 {
    return span.toSeconds(f64) * 1000;
}
