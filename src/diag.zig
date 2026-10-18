//! What a window reports about itself when asked: its own frame as a PNG,
//! the memory it holds, and the spread of what it measured.
const std = @import("std");
const builtin = @import("builtin");

pub fn saveSnap(gpa: std.mem.Allocator, path: []const u8, px: []u32, w: u32, h: u32) void {
    const png = @import("png.zig");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    png.write(gpa, .{ .px = px, .w = w, .h = h }, &out.writer) catch return;
    const z = gpa.dupeSentinel(u8, path, 0) catch return;
    defer gpa.free(z);
    const f = std.c.fopen(z.ptr, "w") orelse return;
    _ = std.c.fwrite(out.written().ptr, 1, out.written().len, f);
    _ = std.c.fclose(f);
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
pub const Timebase = extern struct { numer: u32, denom: u32 };
pub extern "c" fn mach_timebase_info(info: *Timebase) c_int;

pub fn usage(pid: c_int) ?RusageInfoV2 {
    if (builtin.os.tag != .macos) return null;
    var ri: RusageInfoV2 = undefined;
    if (proc_pid_rusage(pid, 2, &ri) != 0) return null;
    return ri;
}

pub fn stat(o: *std.Io.Writer, name: []const u8, xs: []u64) !void {
    if (xs.len == 0) return o.print("{s}: none\n", .{name});
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (xs) |x| sum += x;
    const f = struct {
        fn ms(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e6;
        }
    }.ms;
    try o.print("{s}: n={d} mean {d:.2} ms, p50 {d:.2}, p95 {d:.2}, max {d:.2}\n", .{ name, xs.len, f(sum / xs.len), f(xs[xs.len / 2]), f(xs[@min(xs.len - 1, xs.len * 95 / 100)]), f(xs[xs.len - 1]) });
}
