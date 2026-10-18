//! hull's window, on raylib: one program, one window, drawn by the GPU
//! backend. A thread reads the program's output and wakes the loop; the
//! loop feeds the terminal, draws when something changed, and otherwise
//! sleeps in GLFW until a key, a resize or more output.
//!
//! Keys come from GLFW's own callbacks, not raylib's input: raylib keeps a
//! key and the text it typed in separate queues, and the kitty keyboard
//! protocol needs them as one event. GLFW on macOS calls the key callback
//! and then, from the same keyDown, the char callback, so a press waits
//! for its text until the next callback or the end of the event poll.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("rl");
const config = @import("config.zig");
const font = @import("font.zig");
const render = @import("render.zig");
const Gl = @import("gl.zig").Gl;
const keys = @import("keys.zig");
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const now = session_mod.now;
const vt_mod = @import("vt.zig");
const settings_mod = @import("settings.zig");
const c = vt_mod.c;

pub const Options = struct {
    io: std.Io,
    /// Write the window's own frame at this moment as a PNG: "path@seconds".
    snap: ?[]const u8 = null,
    /// Press keys itself and report what it measured on exit.
    bench: bool = false,
    bench_out: ?[]const u8 = null,
};

/// The program's output, handed from the reader thread to the loop.
const Inbox = struct {
    /// The settings channel, watched while the loop has drained it.
    channel: c_int = -1,
    channel_armed: std.atomic.Value(bool) = .init(true),
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    buf: [1 << 20]u8 = undefined,
    len: usize = 0,
    ended: bool = false,
    stop: bool = false,
};

const Pending = struct {
    key: vt_mod.Key,
    text: [8]u8 = undefined,
};

const Win = struct {
    gpa: std.mem.Allocator,
    s: *Session,
    app: config.App,
    inbox: *Inbox,
    pending: ?Pending = null,
    dirty: bool = true,
    focused: bool = true,
    // what the bench measures
    key_at: ?u64 = null,
    output_at: ?u64 = null,
    latencies: std.ArrayList(u64) = .empty,
    to_output: std.ArrayList(u64) = .empty,
    draws: std.ArrayList(u64) = .empty,
    frames: std.ArrayList(u64) = .empty,
};

var win: *Win = undefined;

pub fn run(gpa: std.mem.Allocator, app: config.App, bytes: font.Fonts.Bytes, fallback: []const []const u8, argv: []const []const u8, env: *const std.process.Environ.Map, cwd: ?[]const u8, opts: Options) !void {
    const t_main = now();
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    var flags: c_uint = rl.FLAG_WINDOW_HIGHDPI | rl.FLAG_VSYNC_HINT | rl.FLAG_WINDOW_TRANSPARENT;
    if (app.window.resizable) flags |= rl.FLAG_WINDOW_RESIZABLE;
    rl.SetConfigFlags(flags);
    const title = try gpa.dupeSentinel(u8, app.name, 0);
    defer gpa.free(title);
    // A first size in points; the cell decides the real one once the
    // display's scale is known.
    rl.InitWindow(800, 600, title.ptr);
    if (!rl.IsWindowReady()) return error.Window;
    defer rl.CloseWindow();
    rl.SetExitKey(rl.KEY_NULL);
    rl.SetTargetFPS(0);
    const t_window = now();

    const scale = rl.GetWindowScaleDPI().x;
    var s: Session = undefined;
    try s.init(gpa, app, bytes, fallback, scale);
    defer s.deinit();
    const pts_w: c_int = @intFromFloat(@round(@as(f32, @floatFromInt(s.w)) / scale));
    const pts_h: c_int = @intFromFloat(@round(@as(f32, @floatFromInt(s.h)) / scale));
    rl.SetWindowSize(pts_w, pts_h);
    if (app.window.resizable) {
        const mw = app.window.min_cols * s.layout.cell_w + 2 * s.layout.pad_x;
        const mh = app.window.min_rows * s.layout.cell_h + 2 * s.layout.pad_y;
        rl.SetWindowMinSize(@intFromFloat(@as(f32, @floatFromInt(mw)) / scale), @intFromFloat(@as(f32, @floatFromInt(mh)) / scale));
    }
    if (std.c.getenv("HULL_DIAG") != null) std.debug.print("asked {d}x{d} pt; screen {d}x{d}, render {d}x{d}, scale {d}\n", .{ pts_w, pts_h, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.GetRenderWidth(), rl.GetRenderHeight(), scale });
    s.resize(@intCast(rl.GetRenderWidth()), @intCast(rl.GetRenderHeight()));

    var gl = try Gl.init(gpa);
    defer gl.deinit();
    var r = render.Renderer.init(gpa, gl.backend());
    defer r.deinit();

    var st = settings_mod.Settings.init(gpa, app.terminal);
    defer st.deinit();
    st.load(opts.io, env, app.id);
    try st.applyLoaded(&s);
    try s.spawn(argv, env, cwd);
    st.hello(&s);
    if (st.fullscreen) toggleFullscreen();
    const inbox = try gpa.create(Inbox);
    defer gpa.destroy(inbox);
    inbox.* = .{ .channel = s.channel orelse -1 };
    var w: Win = .{ .gpa = gpa, .s = &s, .app = app, .inbox = inbox };
    defer {
        w.latencies.deinit(gpa);
        w.to_output.deinit(gpa);
        w.draws.deinit(gpa);
        w.frames.deinit(gpa);
    }
    win = &w;
    const reader = try std.Thread.spawn(.{}, readLoop, .{ &s, inbox });
    defer {
        _ = std.c.pthread_mutex_lock(&inbox.mutex);
        inbox.stop = true;
        _ = std.c.pthread_cond_signal(&inbox.cond);
        _ = std.c.pthread_mutex_unlock(&inbox.mutex);
        s.pty.close();
        s.spawned = false;
        reader.join();
    }

    const glfw = rl.glfwGetCurrentContext();
    _ = rl.glfwSetKeyCallback(glfw, onKey);
    _ = rl.glfwSetCharCallback(glfw, onChar);
    _ = rl.glfwSetWindowFocusCallback(glfw, onFocus);

    var bench: Bench = .{ .start = now() };
    var sync_since: ?u64 = null;
    var last_mem: u64 = 0;
    var snap_at: ?f64 = null;
    var snap_path: []const u8 = "";
    if (opts.snap) |spec| if (std.mem.lastIndexOfScalar(u8, spec, '@')) |i| {
        snap_path = spec[0..i];
        snap_at = std.fmt.parseFloat(f64, spec[i + 1 ..]) catch null;
    };
    var closing = false;
    while (true) {
        if (rl.WindowShouldClose()) {
            if (app.window.close_key) |name| if (!closing and !s.ended) {
                // The program decides: it hears the key and ends itself.
                if (@import("headless.zig").named(name)) |k| s.key(k);
                rl.glfwSetWindowShouldClose(glfw, 0);
                closing = true;
            } else break else break;
        }
        flushPending();
        if (opts.bench) bench.step(&w);
        if (std.c.getenv("HULL_DIAG") != null) {
            const t = now();
            if (t - last_mem > 2 * std.time.ns_per_s) {
                last_mem = t;
                if (usage(getpid())) |ru| std.debug.print("t={d:.1}s footprint {d:.1} MB resident {d:.1} MB uploads {d} ({d} MB)\n", .{ @as(f64, @floatFromInt(t - t_main)) / 1e9, @as(f64, @floatFromInt(ru.phys_footprint)) / 1048576, @as(f64, @floatFromInt(ru.resident_size)) / 1048576, @import("gl.zig").uploaded, @import("gl.zig").uploaded_bytes >> 20 });
            }
        }

        // The program's output, into the terminal.
        _ = std.c.pthread_mutex_lock(&inbox.mutex);
        const n = inbox.len;
        if (n > 0) {
            s.output_bytes += n;
            s.vt.feed(inbox.buf[0..n]);
            inbox.len = 0;
            _ = std.c.pthread_cond_signal(&inbox.cond);
        }
        const ended = inbox.ended;
        _ = std.c.pthread_mutex_unlock(&inbox.mutex);
        if (n > 0) {
            w.dirty = true;
            if (w.key_at != null and w.output_at == null) w.output_at = now();
        }
        if (ended and app.window.quit_with_program) break;

        const rw: u32 = @intCast(rl.GetRenderWidth());
        const rh: u32 = @intCast(rl.GetRenderHeight());
        if (rw != s.w or rh != s.h) {
            s.resize(rw, rh);
            w.dirty = true;
        }
        // The settings channel, and the window's own full screen.
        switch (st.service(opts.io, &s)) {
            .none => {},
            .redraw => w.dirty = true,
            .fullscreen => if (st.fullscreen != isFullscreen()) {
                if (std.c.getenv("HULL_DIAG") != null) std.debug.print("{d} toggle\n", .{now() / std.time.ns_per_ms});
                toggleFullscreen();
            },
        }
        inbox.channel_armed.store(true, .release);
        const fs = isFullscreen();
        if (fs != st.is_fullscreen and std.c.getenv("HULL_DIAG") != null) std.debug.print("{d} full screen {}\n", .{ now() / std.time.ns_per_ms, fs });
        if (fs != st.is_fullscreen) {
            st.windowFullscreen(&s, fs);
            w.dirty = true;
        }
        if (s.vt.title_changed) {
            s.vt.title_changed = false;
            if (app.window.program_title) {
                const t = gpa.dupeSentinel(u8, s.vt.title(), 0) catch null;
                if (t) |z| {
                    defer gpa.free(z);
                    rl.SetWindowTitle(z.ptr);
                }
            }
        }

        // A synchronized update is held back, up to a second.
        const synced = s.vt.synchronized();
        if (synced) {
            if (sync_since == null) sync_since = now();
        } else sync_since = null;
        const hold = synced and now() - sync_since.? < std.time.ns_per_s;

        if (snap_at) |at| if (@as(f64, @floatFromInt(now() - t_main)) / 1e9 >= at) {
            snap_at = null;
            gl.want_snap = true;
            w.dirty = true;
        };
        if (w.dirty and !hold) {
            w.dirty = false;
            const t0 = now();
            _ = s.draw(&r);
            const t1 = now();
            w.draws.append(gpa, t1 - t0) catch {};
            if (gl.snap.items.len > 0) {
                saveSnap(gpa, snap_path, gl.snap.items, s.w, s.h);
                gl.snap.clearRetainingCapacity();
            }
            w.frames.append(gpa, t1) catch {};
            if (w.output_at != null) {
                w.latencies.append(gpa, t1 - w.key_at.?) catch {};
                w.to_output.append(gpa, w.output_at.? - w.key_at.?) catch {};
                w.key_at = null;
                w.output_at = null;
            }
        } else {
            const wait: f64 = if (hold) 0.01 else if (opts.bench) 0.01 else 0.5;
            rl.glfwWaitEventsTimeout(wait);
        }
    }

    if (std.c.getenv("HULL_DIAG") != null) std.debug.print("images: renderer {d}, gl {d}, frames {d}, uploaded {d} ({d} MB)\n", .{ r.images.count(), gl.images.count(), r.frame, @import("gl.zig").uploaded, @import("gl.zig").uploaded_bytes >> 20 });
    if (opts.bench) try report(gpa, &w, &s, t_main, t_window, opts.bench_out);
}

fn saveSnap(gpa: std.mem.Allocator, path: []const u8, px: []u32, w: u32, h: u32) void {
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

extern "c" fn objc_msgSend() void;
extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;

/// Whether the window is full screen: macOS's own (its green button, or
/// hull's toggle), or raylib's elsewhere.
fn isFullscreen() bool {
    if (builtin.os.tag == .macos) {
        const ns = rl.GetWindowHandle() orelse return false;
        const msg: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_ulong = @ptrCast(&objc_msgSend);
        return msg(ns, sel_registerName("styleMask")) & (1 << 14) != 0; // NSWindowStyleMaskFullScreen
    }
    return rl.IsWindowFullscreen() or rl.IsWindowState(rl.FLAG_BORDERLESS_WINDOWED_MODE);
}

/// Into or out of full screen: on macOS its own, in a Space of its own, as
/// the green button does; raylib's borderless window elsewhere.
fn toggleFullscreen() void {
    if (builtin.os.tag == .macos) {
        const ns = rl.GetWindowHandle() orelse return;
        const msg: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc_msgSend);
        msg(ns, sel_registerName("toggleFullScreen:"), null);
        return;
    }
    rl.ToggleBorderlessWindowed();
}

/// Reads the program's output on its own thread; the loop takes it.
fn readLoop(s: *Session, inbox: *Inbox) void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const watch = inbox.channel >= 0 and inbox.channel_armed.load(.acquire);
        var pfd = [_]std.c.pollfd{
            .{ .fd = s.pty.fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = if (watch) inbox.channel else -1, .events = std.c.POLL.IN, .revents = 0 },
        };
        _ = std.c.poll(&pfd, 2, 100);
        if (pfd[1].revents != 0) {
            // the loop reads it; wake it once until it has
            inbox.channel_armed.store(false, .release);
            rl.glfwPostEmptyEvent();
        }
        _ = std.c.pthread_mutex_lock(&inbox.mutex);
        if (inbox.stop) {
            _ = std.c.pthread_mutex_unlock(&inbox.mutex);
            return;
        }
        _ = std.c.pthread_mutex_unlock(&inbox.mutex);
        if (pfd[0].revents == 0) continue;
        const r = s.pty.read(&buf);
        _ = std.c.pthread_mutex_lock(&inbox.mutex);
        var rest = buf[0..r.n];
        while (rest.len > 0 and !inbox.stop) {
            const room = inbox.buf.len - inbox.len;
            if (room == 0) {
                _ = std.c.pthread_cond_wait(&inbox.cond, &inbox.mutex);
                continue;
            }
            const k = @min(room, rest.len);
            @memcpy(inbox.buf[inbox.len..][0..k], rest[0..k]);
            inbox.len += k;
            rest = rest[k..];
        }
        if (r.state == .ended) inbox.ended = true;
        const done = inbox.ended or inbox.stop;
        _ = std.c.pthread_mutex_unlock(&inbox.mutex);
        rl.glfwPostEmptyEvent();
        if (done) return;
    }
}

fn send(k: vt_mod.Key) void {
    if (std.c.getenv("HULL_DIAG") != null) std.debug.print("key {t} {d} mods={d} text={s} cp={d}\n", .{ k.action, k.key, k.mods, k.text, k.unshifted });
    if (k.action != .release and win.key_at == null) win.key_at = now();
    win.s.key(k);
}

fn flushPending() void {
    if (win.pending) |p| {
        win.pending = null;
        var k = p.key;
        if (k.text.len > 0) k.text = p.text[0..k.text.len];
        send(k);
    }
}

fn onKey(_: ?*rl.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    flushPending();
    var unshifted: u32 = keys.usUnshifted(key);
    if (rl.glfwGetKeyName(key, scancode)) |name| {
        const sl = std.mem.span(name);
        if (std.unicode.utf8Decode(sl[0..(std.unicode.utf8ByteSequenceLength(sl[0]) catch 1)])) |cp| unshifted = cp else |_| {}
    }
    const k: vt_mod.Key = .{
        .action = switch (action) {
            0 => .release,
            2 => .repeat,
            else => .press,
        },
        .key = keys.key(key),
        .mods = keys.mods(mods),
        .unshifted = unshifted,
    };
    if (k.action == .release) send(k) else win.pending = .{ .key = k };
}

fn onChar(_: ?*rl.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    const cp: u21 = std.math.cast(u21, codepoint) orelse return;
    if (cp < 0x20 or cp == 0x7f or (cp >= 0xF700 and cp <= 0xF8FF)) return;
    if (win.pending) |*p| {
        // Option as Alt: the key goes as itself with Alt, not as the
        // character macOS composed for Option.
        if (p.key.mods & c.GHOSTTY_MODS_ALT != 0 and win.app.terminal.option_as_alt) return;
        const n = std.unicode.utf8Encode(cp, &p.text) catch return;
        p.key.text = p.text[0..n];
        if (p.key.mods & c.GHOSTTY_MODS_SHIFT != 0) p.key.consumed |= c.GHOSTTY_MODS_SHIFT;
        if (p.key.mods & c.GHOSTTY_MODS_ALT != 0) p.key.consumed |= c.GHOSTTY_MODS_ALT;
        flushPending();
    } else {
        // Text with no key: an input method committing.
        var buf: [8]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        win.s.send(buf[0..n]);
    }
}

fn onFocus(_: ?*rl.GLFWwindow, focused: c_int) callconv(.c) void {
    win.focused = focused != 0;
    win.s.focus(win.focused);
}

/// The bench's own keys: begin, the scene, then left and right in turn,
/// pressed through the same path a key from GLFW takes.
const Bench = struct {
    start: u64,
    next: usize = 0,

    const script = blk: {
        var s: [44]struct { f64, c_int } = undefined;
        s[0] = .{ 1.5, 257 }; // enter: begin
        s[1] = .{ 3.5, 257 }; // enter: the scene
        for (2..44) |i| s[i] = .{ 6.0 + @as(f64, @floatFromInt(i - 2)) * 0.25, if (i % 2 == 0) 262 else 263 };
        break :blk s;
    };

    fn step(b: *Bench, w: *Win) void {
        const t = @as(f64, @floatFromInt(now() - b.start)) / 1e9;
        if (b.next >= script.len) {
            if (t > script[script.len - 1][0] + 3) rl.glfwSetWindowShouldClose(rl.glfwGetCurrentContext(), 1);
            return;
        }
        if (t < script[b.next][0]) return;
        if (w.key_at != null) return; // the last one has not been drawn yet
        const k = script[b.next][1];
        onKey(null, k, 0, 1, 0);
        if (k == 257) onChar(null, '\r');
        flushPending();
        onKey(null, k, 0, 0, 0);
        b.next += 1;
    }
};

const RusageInfoV2 = extern struct {
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
extern "c" fn getpid() c_int;
const Timebase = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(info: *Timebase) c_int;

fn usage(pid: c_int) ?RusageInfoV2 {
    if (builtin.os.tag != .macos) return null;
    var ri: RusageInfoV2 = undefined;
    if (proc_pid_rusage(pid, 2, &ri) != 0) return null;
    return ri;
}

fn report(gpa: std.mem.Allocator, w: *Win, s: *Session, t_main: u64, t_window: u64, out_path: ?[]const u8) !void {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const o = &buf.writer;
    const ms = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e6;
        }
    }.f;
    var tb: Timebase = .{ .numer = 1, .denom = 1 };
    _ = mach_timebase_info(&tb);
    const self_ru = usage(getpid());
    const exec_ns: ?u64 = if (self_ru) |ru| ru.start_abstime * tb.numer / tb.denom else null;
    try o.print("hull bench: {s}, {d}x{d} cells, {d}x{d} px, scale {d}\n", .{ s.app.name, s.vt.cols, s.vt.rows, s.w, s.h, s.scale });
    if (exec_ns) |e| try o.print("startup: exec to main {d:.1} ms, to window {d:.1} ms", .{ ms(t_main - e), ms(t_window - e) }) else try o.print("startup:", .{});
    const base = exec_ns orelse t_main;
    if (s.first_frame_ns) |t| try o.print(", to the program's first frame {d:.1} ms", .{ms(t - base)});
    if (s.first_image_ns) |t| try o.print(", to its first picture {d:.1} ms", .{ms(t - base)});
    try o.print("\n", .{});
    try stat(o, "key to frame (synthetic key, through GLFW's callback path, to the swap)", w.latencies.items);
    try stat(o, "key to the program's output", w.to_output.items);
    try stat(o, "draw + present (CPU)", w.draws.items);
    if (w.frames.items.len > 1) {
        var gaps: std.ArrayList(u64) = .empty;
        defer gaps.deinit(gpa);
        for (w.frames.items[1..], w.frames.items[0 .. w.frames.items.len - 1]) |a, b| try gaps.append(gpa, a - b);
        try stat(o, "between frames", gaps.items);
        const span = w.frames.items[w.frames.items.len - 1] - w.frames.items[0];
        try o.print("frames: {d} in {d:.1} s ({d:.1}/s)\n", .{ w.frames.items.len, ms(span) / 1000, @as(f64, @floatFromInt(w.frames.items.len)) / (ms(span) / 1000) });
    }
    if (self_ru) |ru| try o.print("memory: hull {d:.1} MB footprint, {d:.1} MB resident; cpu {d:.2} s user {d:.2} s sys\n", .{
        @as(f64, @floatFromInt(ru.phys_footprint)) / 1048576, @as(f64, @floatFromInt(ru.resident_size)) / 1048576,
        @as(f64, @floatFromInt(ru.user_time * tb.numer / tb.denom)) / 1e9,          @as(f64, @floatFromInt(ru.system_time * tb.numer / tb.denom)) / 1e9,
    });
    if (usage(s.pty.pid)) |ru| try o.print("memory: the program {d:.1} MB footprint\n", .{@as(f64, @floatFromInt(ru.phys_footprint)) / 1048576});
    std.debug.print("{s}", .{buf.written()});
    if (out_path) |p| {
        const f = std.c.fopen(@ptrCast((try gpa.dupeSentinel(u8, p, 0)).ptr), "w") orelse return;
        _ = std.c.fwrite(buf.written().ptr, 1, buf.written().len, f);
        _ = std.c.fclose(f);
    }
}

fn stat(o: *std.Io.Writer, name: []const u8, xs: []u64) !void {
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
