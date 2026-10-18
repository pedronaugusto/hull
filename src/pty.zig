//! The program's pseudo-terminal and process: spawned on a pty of the
//! window's size, read without blocking, resized, and ended.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const Winsize = extern struct { rows: u16, cols: u16, x_pixel: u16, y_pixel: u16 };

extern "c" fn forkpty(master: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn __error() *c_int;
extern "c" fn __errno_location() *c_int;

const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .macos => 0x80087467,
    else => 0x5414,
};

fn errno() c_int {
    return if (builtin.os.tag == .macos) __error().* else __errno_location().*;
}

const EAGAIN: c_int = if (builtin.os.tag == .macos) 35 else 11;
const EINTR: c_int = 4;
const EIO: c_int = 5;

pub const Pty = struct {
    fd: c_int,
    pid: c.pid_t,
    exited: bool = false,
    status: ?u8 = null,

    /// Runs `argv` with `env` (each "KEY=value") in `cwd` on a new pty.
    /// Everything the child needs is made before the fork: between fork
    /// and exec it only calls what is async-signal-safe.
    pub fn spawn(arena: std.mem.Allocator, argv: []const []const u8, env: []const []const u8, cwd: ?[]const u8, ws: Winsize) !Pty {
        if (argv.len == 0) return error.NoProgram;
        const cargv = try arena.alloc(?[*:0]const u8, argv.len + 1);
        for (argv, 0..) |a, i| cargv[i] = try arena.dupeSentinel(u8, a, 0);
        cargv[argv.len] = null;
        const cenv = try arena.alloc(?[*:0]const u8, env.len + 1);
        for (env, 0..) |e, i| cenv[i] = try arena.dupeSentinel(u8, e, 0);
        cenv[env.len] = null;
        const ccwd: ?[*:0]const u8 = if (cwd) |d| try arena.dupeSentinel(u8, d, 0) else null;
        const path = cargv[0].?;

        var fd: c_int = -1;
        const pid = forkpty(&fd, null, null, &ws);
        if (pid < 0) return error.ForkPty;
        if (pid == 0) {
            if (ccwd) |d| _ = chdir(d);
            _ = c.execve(path, @ptrCast(cargv.ptr), @ptrCast(cenv.ptr));
            c._exit(127);
        }
        const flags = c.fcntl(fd, c.F.GETFL);
        _ = c.fcntl(fd, c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
        return .{ .fd = fd, .pid = pid };
    }

    pub const Read = enum { more, drained, ended };

    /// Reads what is there into `buf`: the bytes, and whether the program's
    /// side has closed.
    pub fn read(p: *Pty, buf: []u8) struct { n: usize, state: Read } {
        while (true) {
            const n = c.read(p.fd, buf.ptr, buf.len);
            if (n > 0) return .{ .n = @intCast(n), .state = if (@as(usize, @intCast(n)) == buf.len) .more else .drained };
            if (n == 0) return .{ .n = 0, .state = .ended };
            const e = errno();
            if (e == EINTR) continue;
            if (e == EAGAIN) return .{ .n = 0, .state = .drained };
            // EIO: the slave closed, as Linux says it
            return .{ .n = 0, .state = .ended };
        }
    }

    /// Writes all of `bytes`, waiting out a full buffer: a key is never
    /// dropped.
    pub fn write(p: *Pty, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = c.write(p.fd, rest.ptr, rest.len);
            if (n > 0) {
                rest = rest[@intCast(n)..];
                continue;
            }
            const e = errno();
            if (e == EINTR) continue;
            if (e == EAGAIN) {
                var pfd = [_]c.pollfd{.{ .fd = p.fd, .events = c.POLL.OUT, .revents = 0 }};
                _ = c.poll(&pfd, 1, 100);
                continue;
            }
            return;
        }
    }

    pub fn resize(p: *Pty, ws: Winsize) void {
        _ = ioctl(p.fd, TIOCSWINSZ, &ws);
    }

    /// Whether the program has ended, reaping it if so.
    pub fn reap(p: *Pty) bool {
        if (p.exited) return true;
        var status: c_int = 0;
        const r = c.waitpid(p.pid, &status, 1); // WNOHANG
        if (r == p.pid) {
            p.exited = true;
            const s: u32 = @bitCast(status);
            p.status = if (s & 0x7f == 0) @truncate(s >> 8) else @truncate(128 + (s & 0x7f));
        }
        return p.exited;
    }

    /// Ends the program: hang up, a moment, then kill; always reaped.
    pub fn close(p: *Pty) void {
        _ = c.close(p.fd);
        if (p.reap()) return;
        _ = c.kill(p.pid, .HUP);
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            if (p.reap()) return;
            var pfd = [_]c.pollfd{};
            _ = c.poll(&pfd, 0, 10);
        }
        _ = c.kill(p.pid, .KILL);
        _ = c.waitpid(p.pid, null, 0);
        p.exited = true;
    }
};
