//! hull without a window: the program on its terminal, keys pressed at given
//! moments, and the frame at a given moment written as a PNG by the same
//! renderer the window uses. For tests, and for looking without a screen.
const std = @import("std");
const aegis = @import("aegis");
const Session = @import("session.zig").Session;
const now = @import("session.zig").now;
const seconds = @import("session.zig").seconds;
const presses = @import("presses.zig");
const render = @import("render.zig");
const Cpu = @import("cpu.zig").Cpu;
const Canvas = @import("cpu.zig").Canvas;
const png = @import("png.zig");
const Settings = @import("settings.zig").Settings;

pub const Press = presses.Press;

pub const Options = struct {
    out: []const u8,
    /// Seconds after the start the frame is taken at.
    at: f64 = 3,
    presses: []const Press = &.{},
    /// Frames taken at these further moments, `out` with `-<n>` before
    /// its extension; for shimmer and timing.
    also: []const f64 = &.{},
    /// As if the window were full screen: opaque, opacity unavailable.
    fullscreen: bool = false,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, s: *Session, opts: Options) !void {
    var st = Settings.init(gpa, s.app.terminal);
    defer st.deinit();
    if (opts.fullscreen) {
        st.is_fullscreen = true;
        s.vt.opacity = st.drawnOpacity();
    }
    st.hello(s);
    var cpu = try Cpu.init(gpa);
    defer cpu.deinit();
    var r = render.Renderer.init(gpa, cpu.backend());
    defer r.deinit();
    const start = now(io);
    var next: usize = 0;
    var shots: std.ArrayList(f64) = .empty;
    defer shots.deinit(gpa);
    try shots.append(gpa, opts.at);
    try shots.appendSlice(gpa, opts.also);
    std.mem.sort(f64, shots.items, {}, std.sort.asc(f64));
    var shot: usize = 0;
    var sync_wait: ?f64 = null;
    while (shot < shots.items.len) {
        const t = seconds(start, now(io));
        while (next < opts.presses.len and opts.presses[next].at <= t) : (next += 1) s.key(opts.presses[next].key);
        if (t >= shots.items[shot]) {
            // A frame the program is in the middle of is waited for, as a
            // terminal holds a synchronized update back, up to a second.
            if (s.vt.synchronized() and (sync_wait == null or t - sync_wait.? < 1)) {
                if (sync_wait == null) sync_wait = t;
            } else {
                sync_wait = null;
                const t0 = now(io);
                const drawn = s.draw(&r);
                const dt = seconds(t0, now(io)) * 1000;
                const path = if (shot == 0 and shots.items.len == 1) opts.out else try numbered(gpa, opts.out, shot);
                defer if (path.ptr != opts.out.ptr) gpa.free(path);
                try save(gpa, io, cpu.canvas, path);
                std.log.info("{s}: {d}x{d} px, {d}x{d} cells, {d} pictures, drawn in {d:.2} ms, at {d:.2} s", .{ path, s.w, s.h, s.vt.cols, s.vt.rows, drawn.images, dt, t });
                shot += 1;
                continue;
            }
        }
        if (s.ended) {
            std.log.err("the program ended before the frame", .{});
            return error.ProgramEnded;
        }
        // Wait for output, the next key or the next frame.
        var until = shots.items[shot];
        if (next < opts.presses.len) until = @min(until, opts.presses[next].at);
        const before = s.output_bytes;
        _ = s.pump();
        if (s.output_bytes == before) {
            // nothing came: a short wait, never past the next moment
            const wait: Milliseconds = .fromRaw(@intFromFloat(std.math.clamp((until - seconds(start, now(io))) * 1000, 0, 5))); // safe: clamped to 5
            try io.sleep(wait.toIoDuration(), .awake);
        }
        switch (st.service(io, s)) {
            .fullscreen => st.windowFullscreen(s, st.fullscreen),
            else => {},
        }
    }
}

/// A wait, to the millisecond.
const Milliseconds = aegis.units.Duration(.millisecond, i64);

fn numbered(gpa: std.mem.Allocator, out: []const u8, n: usize) ![]const u8 {
    const ext = std.fs.path.extension(out);
    return gpa.print("{s}-{d}{s}", .{ out[0 .. out.len - ext.len], n, ext });
}

fn save(gpa: std.mem.Allocator, io: std.Io, cv: Canvas, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try png.write(gpa, cv, &w.interface);
    try w.interface.flush();
}

/// "2.0:enter,2.5:right,3:a": keys at seconds.
pub const parsePresses = presses.parsePresses;

/// A key by name, as a US keyboard makes it, after any of `ctrl+`, `alt+`,
/// `shift+`, `super+`.
pub const named = presses.named;
