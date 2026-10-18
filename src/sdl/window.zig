//! hull's window, on SDL3: one program, one window, drawn by SDL's renderer
//! (Metal on macOS). A thread reads the program's output and wakes the
//! loop with an event of hull's own; the loop feeds the terminal, draws
//! when something changed, and otherwise waits in SDL for a key, a resize
//! or more output.
//!
//! A key and the text it typed come as two events, the key first; a press
//! waits for its text until the next event or the end of the batch. Text
//! with no key before it is an input method committing.
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const config = @import("../config.zig");
const font = @import("../font.zig");
const render = @import("../render.zig");
const Gpu = @import("gpu.zig").Gpu;
const keys = @import("keys.zig");
const session_mod = @import("../session.zig");
const Session = session_mod.Session;
const now = session_mod.now;
const vt_mod = @import("../vt.zig");
const settings_mod = @import("../settings.zig");
const shared = @import("../window.zig");
const c = vt_mod.c;

pub const Options = shared.Options;

/// The program's output, handed from the reader thread to the loop.
const Inbox = struct {
    channel: c_int = -1,
    channel_armed: std.atomic.Value(bool) = .init(true),
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    buf: [1 << 20]u8 = undefined,
    len: usize = 0,
    ended: bool = false,
    stop: bool = false,
    /// The event that wakes the loop.
    wake: u32 = 0,
};

const Pending = struct {
    key: vt_mod.Key,
    text: [8]u8 = undefined,
};

const Win = struct {
    s: *Session,
    app: config.App,
    pending: ?Pending = null,
    dirty: bool = true,
    key_at: ?u64 = null,
    output_at: ?u64 = null,
    latencies: std.ArrayList(u64) = .empty,
    draws: std.ArrayList(u64) = .empty,
};

var win: *Win = undefined;

pub fn run(gpa: std.mem.Allocator, app: config.App, bytes: font.Fonts.Bytes, fallback: []const []const u8, argv: []const []const u8, env: *const std.process.Environ.Map, cwd: ?[]const u8, opts: Options) !void {
    const t_main = now();
    const name = try gpa.dupeSentinel(u8, app.name, 0);
    defer gpa.free(name);
    const version = try gpa.dupeSentinel(u8, app.version, 0);
    defer gpa.free(version);
    const id = try gpa.dupeSentinel(u8, app.id, 0);
    defer gpa.free(id);
    // the app's own name in the menu and the Dock, never hull's
    _ = sdl.SDL_SetAppMetadata(name.ptr, version.ptr, id.ptr);
    _ = sdl.SDL_SetHint(sdl.SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES, "1");
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) return error.Sdl;
    defer sdl.SDL_Quit();

    var flags: sdl.SDL_WindowFlags = sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY | sdl.SDL_WINDOW_TRANSPARENT | sdl.SDL_WINDOW_HIDDEN;
    if (app.window.resizable) flags |= sdl.SDL_WINDOW_RESIZABLE;
    const window = sdl.SDL_CreateWindow(name.ptr, 800, 600, flags) orelse return error.Window;
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.Renderer;
    defer sdl.SDL_DestroyRenderer(renderer);
    _ = sdl.SDL_SetRenderVSync(renderer, 1);
    const t_window = now();

    // the cell decides the window's size, once the display's density is known
    const scale = sdl.SDL_GetWindowPixelDensity(window);
    var s: Session = undefined;
    try s.init(gpa, app, bytes, fallback, scale);
    defer s.deinit();
    _ = sdl.SDL_SetWindowSize(window, @intFromFloat(@round(@as(f32, @floatFromInt(s.w)) / scale)), @intFromFloat(@round(@as(f32, @floatFromInt(s.h)) / scale)));
    if (app.window.resizable) {
        const mw = app.window.min_cols * s.layout.cell_w + 2 * s.layout.pad_x;
        const mh = app.window.min_rows * s.layout.cell_h + 2 * s.layout.pad_y;
        _ = sdl.SDL_SetWindowMinimumSize(window, @intFromFloat(@as(f32, @floatFromInt(mw)) / scale), @intFromFloat(@as(f32, @floatFromInt(mh)) / scale));
    }
    _ = sdl.SDL_ShowWindow(window);
    var pw: c_int = 0;
    var ph: c_int = 0;
    _ = sdl.SDL_GetWindowSizeInPixels(window, &pw, &ph);
    s.resize(@intCast(pw), @intCast(ph));

    var gpu = try Gpu.init(gpa, renderer);
    defer gpu.deinit();
    var r = render.Renderer.init(gpa, gpu.backend());
    defer r.deinit();

    var st = settings_mod.Settings.init(gpa, app.terminal);
    defer st.deinit();
    st.load(opts.io, env, app.id);
    try st.applyLoaded(&s);
    try s.spawn(argv, env, cwd);
    st.hello(&s);
    if (st.fullscreen) _ = sdl.SDL_SetWindowFullscreen(window, true);
    _ = sdl.SDL_StartTextInput(window);

    const inbox = try gpa.create(Inbox);
    defer gpa.destroy(inbox);
    inbox.* = .{ .channel = s.channel orelse -1, .wake = sdl.SDL_RegisterEvents(1) };
    var w: Win = .{ .s = &s, .app = app };
    defer {
        w.latencies.deinit(gpa);
        w.draws.deinit(gpa);
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

    var snap_at: ?f64 = null;
    var snap_path: []const u8 = "";
    if (opts.snap) |spec| if (std.mem.lastIndexOfScalar(u8, spec, '@')) |i| {
        snap_path = spec[0..i];
        snap_at = std.fmt.parseFloat(f64, spec[i + 1 ..]) catch null;
    };
    var last_mem: u64 = 0;
    var closing = false;
    var sync_since: ?u64 = null;
    loop: while (true) {
        // every event waiting, a key held for its text until the next
        var ev: sdl.SDL_Event = undefined;
        var waited = false;
        while (if (waited or !w.dirty) sdl.SDL_WaitEventTimeout(&ev, if (waited) 0 else 500) else sdl.SDL_PollEvent(&ev)) {
            waited = true;
            switch (ev.type) {
                sdl.SDL_EVENT_QUIT, sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    if (app.window.close_key) |k| if (!closing and !s.ended) {
                        // the program decides: it hears the key and ends itself
                        if (@import("../headless.zig").named(k)) |press| s.key(press);
                        closing = true;
                        continue;
                    };
                    break :loop;
                },
                sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => onKey(&ev.key),
                sdl.SDL_EVENT_TEXT_INPUT => onText(std.mem.span(ev.text.text)),
                sdl.SDL_EVENT_WINDOW_FOCUS_GAINED => s.focus(true),
                sdl.SDL_EVENT_WINDOW_FOCUS_LOST => s.focus(false),
                sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, sdl.SDL_EVENT_WINDOW_EXPOSED => w.dirty = true,
                else => {},
            }
        }
        flushPending();

        if (std.c.getenv("HULL_DIAG") != null) {
            const t = now();
            if (t - last_mem > 2 * std.time.ns_per_s) {
                last_mem = t;
                if (shared.usage(shared.getpid())) |ru| std.debug.print("t={d:.1}s footprint {d:.1} MB resident {d:.1} MB uploads {d} ({d} MB)\n", .{ @as(f64, @floatFromInt(t - t_main)) / 1e9, @as(f64, @floatFromInt(ru.phys_footprint)) / 1048576, @as(f64, @floatFromInt(ru.resident_size)) / 1048576, @import("gpu.zig").uploaded, @import("gpu.zig").uploaded_bytes >> 20 });
            }
        }

        // the program's output, into the terminal
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

        _ = sdl.SDL_GetWindowSizeInPixels(window, &pw, &ph);
        if (@as(u32, @intCast(pw)) != s.w or @as(u32, @intCast(ph)) != s.h) {
            s.resize(@intCast(pw), @intCast(ph));
            w.dirty = true;
        }
        // the settings channel, and the window's own full screen
        const full = sdl.SDL_GetWindowFlags(window) & sdl.SDL_WINDOW_FULLSCREEN != 0;
        switch (st.service(opts.io, &s)) {
            .none => {},
            .redraw => w.dirty = true,
            .fullscreen => if (st.fullscreen != full) {
                _ = sdl.SDL_SetWindowFullscreen(window, st.fullscreen);
            },
        }
        inbox.channel_armed.store(true, .release);
        if (full != st.is_fullscreen) {
            st.windowFullscreen(&s, full);
            w.dirty = true;
        }
        if (s.vt.title_changed) {
            s.vt.title_changed = false;
            if (app.window.program_title) {
                if (gpa.dupeSentinel(u8, s.vt.title(), 0)) |z| {
                    defer gpa.free(z);
                    _ = sdl.SDL_SetWindowTitle(window, z.ptr);
                } else |_| {}
            }
        }

        // a synchronized update is held back, up to a second
        const synced = s.vt.synchronized();
        if (synced) {
            if (sync_since == null) sync_since = now();
        } else sync_since = null;
        const hold = synced and now() - sync_since.? < std.time.ns_per_s;

        if (snap_at) |at| if (@as(f64, @floatFromInt(now() - t_main)) / 1e9 >= at) {
            snap_at = null;
            gpu.want_snap = true;
            w.dirty = true;
        };
        if (w.dirty and !hold) {
            w.dirty = false;
            const t0 = now();
            _ = s.draw(&r);
            const t1 = now();
            w.draws.append(gpa, t1 - t0) catch {};
            if (gpu.snap.items.len > 0) {
                shared.saveSnap(gpa, snap_path, gpu.snap.items, gpu.w, gpu.h);
                gpu.snap.clearRetainingCapacity();
            }
            if (w.output_at != null) {
                w.latencies.append(gpa, t1 - w.key_at.?) catch {};
                w.key_at = null;
                w.output_at = null;
            }
        } else if (hold) sdl.SDL_Delay(5);
    }
    if (std.c.getenv("HULL_DIAG") != null) report(gpa, &w, &s, t_main, t_window);
}

fn report(gpa: std.mem.Allocator, w: *Win, s: *Session, t_main: u64, t_window: u64) void {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const o = &buf.writer;
    o.print("hull (SDL3, {s}): {d}x{d} cells, window in {d:.1} ms\n", .{ if (sdl.SDL_GetCurrentVideoDriver()) |d| std.mem.span(d) else "?", s.vt.cols, s.vt.rows, @as(f64, @floatFromInt(t_window - t_main)) / 1e6 }) catch return;
    shared.stat(o, "key to frame", w.latencies.items) catch return;
    shared.stat(o, "draw + present", w.draws.items) catch return;
    if (shared.usage(shared.getpid())) |ru| o.print("memory: {d:.1} MB footprint, {d:.1} MB resident\n", .{ @as(f64, @floatFromInt(ru.phys_footprint)) / 1048576, @as(f64, @floatFromInt(ru.resident_size)) / 1048576 }) catch return;
    std.debug.print("{s}", .{buf.written()});
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
            wake(inbox);
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
        wake(inbox);
        if (done) return;
    }
}

// SDL's event queue takes events from any thread.
fn wake(inbox: *Inbox) void {
    var ev: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
    ev.type = inbox.wake;
    _ = sdl.SDL_PushEvent(&ev);
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

fn onKey(e: *const sdl.SDL_KeyboardEvent) void {
    flushPending();
    // the key's own character on the layout, with no modifiers
    const plain = sdl.SDL_GetKeyFromScancode(e.scancode, sdl.SDL_KMOD_NONE, false);
    const unshifted: u32 = if (plain > 0 and plain < 0x110000 and plain & sdl.SDLK_SCANCODE_MASK == 0) plain else 0;
    const k: vt_mod.Key = .{
        .action = if (!e.down) .release else if (e.repeat) .repeat else .press,
        .key = keys.key(e.scancode),
        .mods = keys.mods(e.mod),
        .unshifted = unshifted,
    };
    if (k.action == .release) return send(k);
    win.pending = .{ .key = k };
    // Option as Alt: the key's own character, as if Option were not held
    // (Ghostty's macos-option-as-alt), so legacy encoding can send ESC x
    if (k.mods & c.GHOSTTY_MODS_ALT != 0 and win.app.terminal.option_as_alt and unshifted >= 0x20 and unshifted < 0x7f) {
        const p = &win.pending.?;
        var ch: u8 = @intCast(unshifted);
        if (k.mods & c.GHOSTTY_MODS_SHIFT != 0 and ch >= 'a' and ch <= 'z') {
            ch -= 32;
            p.key.consumed |= c.GHOSTTY_MODS_SHIFT;
        }
        p.text[0] = ch;
        p.key.text = p.text[0..1];
    }
}

fn onText(text: []const u8) void {
    if (text.len == 0) return;
    if (win.pending) |*p| {
        // Option as Alt: the key goes as itself with Alt, not as what macOS composed for Option
        if (p.key.mods & c.GHOSTTY_MODS_ALT != 0 and win.app.terminal.option_as_alt) return flushPending();
        if (text.len <= p.text.len) {
            @memcpy(p.text[0..text.len], text);
            p.key.text = p.text[0..text.len];
            if (p.key.mods & c.GHOSTTY_MODS_SHIFT != 0) p.key.consumed |= c.GHOSTTY_MODS_SHIFT;
            if (p.key.mods & c.GHOSTTY_MODS_ALT != 0) p.key.consumed |= c.GHOSTTY_MODS_ALT;
        }
        flushPending();
    } else {
        // text with no key: an input method committing
        win.s.send(text);
    }
}
