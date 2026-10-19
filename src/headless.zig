//! hull without a window: the program on its terminal, keys pressed at given
//! moments, and the frame at a given moment written as a PNG by the same
//! renderer the window uses. For tests, and for looking without a screen.
const std = @import("std");
const Session = @import("session.zig").Session;
const now = @import("session.zig").now;
const vt_mod = @import("vt.zig");
const c = vt_mod.c;
const render = @import("render.zig");
const Cpu = @import("cpu.zig").Cpu;
const Canvas = @import("cpu.zig").Canvas;
const png = @import("png.zig");
const Settings = @import("settings.zig").Settings;

pub const Press = struct { at: f64, key: vt_mod.Key };

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
        const t = secs(io, start);
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
                const dt = @as(f64, @floatFromInt(now(io) - t0)) / 1e6;
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
            const wait_ms: i64 = @intFromFloat(std.math.clamp((until - secs(io, start)) * 1000, 0, 5)); // safe: clamped to 5
            io.sleep(.fromMilliseconds(wait_ms), .awake) catch {}; // glint-ignore: Z026 -- canceled: the loop ends with hull
        }
        switch (st.service(io, s)) {
            .fullscreen => st.windowFullscreen(s, st.fullscreen),
            else => {},
        }
    }
}

fn secs(io: std.Io, start: u64) f64 {
    return @as(f64, @floatFromInt(now(io) - start)) / 1e9;
}

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
pub fn parsePresses(gpa: std.mem.Allocator, spec: []const u8) ![]Press {
    var out: std.ArrayList(Press) = .empty;
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
pub fn named(spec: []const u8) ?vt_mod.Key {
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

fn plain(name: []const u8) ?vt_mod.Key {
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
