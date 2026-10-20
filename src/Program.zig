//! The program hull runs: conduit's pseudo-terminal and child, and the
//! channel hull's settings travel on. Its output is read on a task of its
//! own into a queue the loop takes from, and so is what it says on the
//! channel; what hull says back goes out on a third, a line whole or not at
//! all. Ending it ends what it started: its tree is conduit's to reach.
//!
//! The channel is conduit's: a socket pair on POSIX, a duplex pipe on
//! Windows, the program's end named in `HULL_SOCKET`.
const std = @import("std");
const builtin = @import("builtin");
const conduit = @import("conduit");
const hp = @import("hull-protocol");

const Program = @This();
const is_windows = builtin.os.tag == .windows;

/// The most of the program's output held for the loop, in bytes; past it the reader waits.
pub const max_output = 1 << 20;
/// The most of the program's channel held for the loop, in bytes.
pub const max_heard = 64 * 1024;
/// The most hull holds for a program that does not read its channel: past it, a line is refused whole, never cut.
pub const max_told = 4 << 20;
/// How long a program has to end once its terminal hangs up, before it is killed.
const grace: conduit.Duration = .literal("500ms");

gpa: std.mem.Allocator,
io: std.Io,
pty: conduit.Pty,
child: conduit.Child,
/// The program's output, as the reader task leaves it, and the room it is kept in.
output: std.Io.Queue(u8),
room: []u8,
/// hull's end of the channel, and what came over it and what waits to go.
channel: ?Channel,
tasks: std.Io.Group = .init,
/// Called from a task when there is output or a line to take: the window's wake.
wake: ?Wake,
term: ?conduit.Term = null,

pub const Wake = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque) void,
};

pub const Size = conduit.Size;

pub const Options = struct {
    argv: []const []const u8,
    environ: *const std.process.Environ.Map,
    cwd: ?[]const u8 = null,
    size: Size,
    /// Whether the program is given hull's channel.
    channel: bool = true,
    wake: ?Wake = null,
};

const Channel = struct {
    file: std.Io.File,
    heard: std.Io.Queue(u8),
    told: std.Io.Queue(u8),
    rooms: [2][]u8,
    /// What `told` holds and the writer has not yet written, so a line is taken only whole.
    waiting: std.atomic.Value(usize) = .init(0),
};

/// Starts the program in place: `p` must stay where it is until `stop`. The environment is the program's as given;
/// conduit adds `HULL_SOCKET` to it where the program has a channel.
pub fn start(p: *Program, gpa: std.mem.Allocator, io: std.Io, opts: Options) !void {
    const room = try gpa.alloc(u8, max_output);
    errdefer gpa.free(room);
    p.* = .{ .gpa = gpa, .io = io, .pty = undefined, .child = undefined, .output = .init(room), .room = room, .channel = null, .wake = opts.wake };
    const ends: ?conduit.Channel = if (opts.channel) try .open() else null;
    // the program's end is the program's once it is spawned, or no one's
    defer if (ends) |e| e.child.close(io);
    errdefer if (ends) |e| e.parent.close(io);

    p.pty = try .open(gpa, io, .{ .rows = opts.size.rows, .cols = opts.size.cols, .x_pixel = opts.size.x_pixel, .y_pixel = opts.size.y_pixel, .console = .{ .passthrough = true } });
    errdefer p.pty.close(io);
    p.child = try conduit.Child.spawn(gpa, io, .{
        .argv = opts.argv,
        .cwd = opts.cwd,
        .environ = opts.environ,
        .stdio = .{ .pty = &p.pty },
        // a session of its own on POSIX, so its terminal is its controlling one and Ctrl-C reaches it
        .detach = !is_windows,
        .descendants = .contain,
        .channel = if (ends) |e| .{ .file = e.child, .variable = hp.env_name } else null,
    });
    errdefer p.child.deinit(io);
    if (!is_windows) p.pty.closeSlave(io);
    if (ends) |e| p.channel = try openChannel(gpa, e.parent);
    errdefer if (p.channel) |*ch| closeChannel(gpa, io, ch);
    try p.tasks.concurrent(io, readOutput, .{p});
    if (p.channel) |*ch| {
        try p.tasks.concurrent(io, readChannel, .{ p, ch });
        try p.tasks.concurrent(io, writeChannel, .{ io, ch });
    }
}

/// Ends the program and what it started, the tasks reading it, and the pair: the terminal hangs up first, as a
/// window closing does, and what has not ended by the grace is killed.
pub fn stop(p: *Program) void {
    const io = p.io;
    // nothing more is taken: a reader that would wait to leave output reads on and drops it, so a child whose
    // terminal holds output can still end
    p.output.close(io);
    if (p.term == null) p.term = end(p);
    p.tasks.cancel(io);
    if (p.channel) |*ch| closeChannel(p.gpa, io, ch);
    p.child.deinit(io);
    p.pty.close(io);
    p.gpa.free(p.room);
    p.* = undefined;
}

fn end(p: *Program) ?conduit.Term {
    const io = p.io;
    if (p.child.tryWait(io) catch null) |t| return t;
    if (!is_windows) {
        p.child.kill(io, .hangup) catch {}; // glint-ignore: Z026 -- a child already gone: the wait below says so
        if (p.child.waitTimeout(io, conduit.Deadline.within(grace.toIoDuration())) catch null) |t| return t;
    }
    return p.child.killWait(io, grace) catch null;
}

/// What the program has written since the last take, into `buf`: how much, or null once it has ended and all it
/// wrote has been taken. Never waits.
pub fn take(p: *Program, buf: []u8) ?usize {
    const n = p.output.get(p.io, buf, 0) catch |err| switch (err) {
        error.Closed => return null,
        error.Canceled => return 0,
    };
    return n;
}

/// How the program ended, once it has: its exit status as a shell would say it.
pub fn status(p: *Program) ?u8 {
    if (p.term == null) p.term = p.child.tryWait(p.io) catch null;
    const t = p.term orelse return null;
    return @truncate(conduit.shellStatus(t)); // a shell's $? is its low byte
}

/// Writes all of `bytes` to the program's terminal, waiting out a full one: a key is never dropped.
pub fn write(p: *Program, bytes: []const u8) void {
    p.pty.writeFile().writeStreamingAll(p.io, bytes) catch {}; // glint-ignore: Z026 -- the program gone: the read task says it ended
}

pub fn resize(p: *Program, size: Size) void {
    p.pty.resize(p.io, size) catch {}; // glint-ignore: Z026 -- a pair already closed: the size goes with it
}

/// What the program has said on the channel since the last take; 0 when it has said nothing or has no channel.
pub fn hear(p: *Program, buf: []u8) usize {
    const ch = &(p.channel orelse return 0);
    return ch.heard.get(p.io, buf, 0) catch 0;
}

/// Whether the program has a channel to talk on.
pub fn talks(p: *const Program) bool {
    return p.channel != null;
}

/// One line for the program, whole: false, and nothing sent, when the program has no channel or has left more than
/// `max_told` unread.
pub fn tell(p: *Program, line: []const u8) bool {
    const ch = &(p.channel orelse return false);
    if (ch.waiting.load(.acquire) + line.len > max_told) return false;
    _ = ch.waiting.fetchAdd(line.len, .acq_rel);
    // never waits: what waits is counted, and the queue holds max_told
    _ = ch.told.putUncancelable(p.io, line, line.len) catch return false;
    return true;
}

fn readOutput(p: *Program) std.Io.Cancelable!void {
    var buf: [64 * 1024]u8 = undefined;
    const file = p.pty.readFile();
    while (true) {
        const n = file.readStreaming(p.io, &.{&buf}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // the end, as Darwin says it, or as Linux does: the master hung up
            else => break,
        };
        if (n == 0) continue;
        p.output.putAll(p.io, buf[0..n]) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => continue, // hull is stopping: read on, so the program can end
        };
        if (p.wake) |w| w.call(w.context);
    }
    p.output.close(p.io);
    if (p.wake) |w| w.call(w.context);
}

fn readChannel(p: *Program, ch: *Channel) std.Io.Cancelable!void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = ch.file.readStreaming(p.io, &.{&buf}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return, // the program closed it: there is nothing more to hear
        };
        if (n == 0) continue;
        ch.heard.putAll(p.io, buf[0..n]) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return,
        };
        if (p.wake) |w| w.call(w.context);
    }
}

fn writeChannel(io: std.Io, ch: *Channel) std.Io.Cancelable!void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = ch.told.get(io, &buf, 1) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return,
        };
        ch.file.writeStreamingAll(io, buf[0..n]) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return, // the program closed it: what waits is never read
        };
        _ = ch.waiting.fetchSub(n, .acq_rel);
    }
}

fn openChannel(gpa: std.mem.Allocator, file: std.Io.File) !Channel {
    const heard = try gpa.alloc(u8, max_heard);
    errdefer gpa.free(heard);
    const told = try gpa.alloc(u8, max_told);
    return .{ .file = file, .heard = .init(heard), .told = .init(told), .rooms = .{ heard, told } };
}

fn closeChannel(gpa: std.mem.Allocator, io: std.Io, ch: *Channel) void {
    ch.file.close(io);
    for (ch.rooms) |r| gpa.free(r);
}

// Takes what the program writes until `want` has all been seen or a second has passed.
fn awaitOutput(p: *Program, want: []const u8, seen: *std.ArrayList(u8)) !void {
    var buf: [256]u8 = undefined;
    for (0..200) |_| {
        const n = p.take(&buf) orelse 0;
        try seen.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.find(u8, seen.items, want) != null) return;
        if (n == 0) try p.io.sleep(.fromMilliseconds(5), .awake);
    }
    // what it wrote instead, said by the failure
    try std.testing.expectEqualStrings(want, seen.items);
    return error.TestExpectedOutput;
}

test "the program on a terminal of its own, its channel both ways, and how it ended" {
    if (is_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var p: Program = undefined;
    // it says it has a terminal, says a word on the channel, and writes back to its terminal what it hears there
    const script = "test -t 0 && printf tty; printf said >&$HULL_SOCKET; head -c 5 <&$HULL_SOCKET; printf done; exit 3";
    try p.start(std.testing.allocator, io, .{ .argv = &.{ "/bin/sh", "-c", script }, .environ = &env, .size = .{ .rows = 24, .cols = 80 } });
    defer p.stop();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(std.testing.allocator);
    try awaitOutput(&p, "tty", &seen);
    var heard: [16]u8 = undefined;
    var n: usize = 0;
    for (0..200) |_| {
        n += p.hear(heard[n..]);
        if (n >= 4) break;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqualStrings("said", heard[0..n]);
    try std.testing.expect(p.tell("back\n"));
    try awaitOutput(&p, "back", &seen);
    try awaitOutput(&p, "done", &seen);
    for (0..200) |_| {
        if (p.status() != null) break;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqual(@as(?u8, 3), p.status());
}

test "a line is told whole or not at all" {
    if (is_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var p: Program = undefined;
    // it never reads its channel
    try p.start(std.testing.allocator, io, .{ .argv = &.{ "/bin/sleep", "5" }, .environ = &env, .size = .{ .rows = 24, .cols = 80 } });
    defer p.stop();
    const line = try std.testing.allocator.alloc(u8, max_told / 4);
    defer std.testing.allocator.free(line);
    @memset(line, 'x');
    var told: usize = 0;
    while (p.tell(line)) told += 1;
    // the socket's own buffer takes some before the bound is met; the bound itself is never passed
    try std.testing.expect(told >= 4);
    try std.testing.expect(!p.tell(line));
}
