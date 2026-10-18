//! hull: a terminal program of the family in a window of its own.
//!
//!     hull [--app DIR] [options] [-- program args...]
//!
//!     --app DIR          the app's hull.zon (in an .app: Contents/Resources)
//!     --opacity N        background opacity while windowed, 80..100
//!     --theme NAME       a theme hull knows (rose-pine by default)
//!     --headless OUT     no window: write the frame at --at as a PNG
//!     --at SECONDS       when the headless frame is taken (default 3)
//!     --also S,S,...     further headless frames, OUT-1.png, OUT-2.png...
//!     --keys T:K,...     headless keys at seconds: enter, right, a, ...
//!     --scale N          headless device pixels per point (default 2)
//!     --size COLSxROWS   the grid (the app's otherwise)
//!     --fullscreen       headless: as if full screen (opaque; opacity unavailable)
//!     --bench            window: press keys itself and report latency,
//!                        frame time, memory and startup on exit
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const font = @import("font.zig");
const Session = @import("session.zig").Session;
const headless = @import("headless.zig");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();

    var app_dir: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var at: f64 = 3;
    var also: []const f64 = &.{};
    var keys: []const headless.Press = &.{};
    var scale: f32 = 2;
    var size: ?[2]u16 = null;
    var theme_name: ?[]const u8 = null;
    var bench = false;
    var opacity: ?i64 = null;
    var fullscreen = false;
    var describe = false;
    var program: std.ArrayList([]const u8) = .empty;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--")) {
            while (args.next()) |p| try program.append(arena, try arena.dupe(u8, p));
            break;
        } else if (std.mem.eql(u8, a, "--app")) {
            app_dir = try arena.dupe(u8, args.next() orelse return usage());
        } else if (std.mem.eql(u8, a, "--headless")) {
            out = try arena.dupe(u8, args.next() orelse return usage());
        } else if (std.mem.eql(u8, a, "--at")) {
            at = try std.fmt.parseFloat(f64, args.next() orelse return usage());
        } else if (std.mem.eql(u8, a, "--also")) {
            var list: std.ArrayList(f64) = .empty;
            var it = std.mem.tokenizeScalar(u8, args.next() orelse return usage(), ',');
            while (it.next()) |t| try list.append(arena, try std.fmt.parseFloat(f64, t));
            also = list.items;
        } else if (std.mem.eql(u8, a, "--keys")) {
            keys = try headless.parsePresses(arena, args.next() orelse return usage());
        } else if (std.mem.eql(u8, a, "--scale")) {
            scale = try std.fmt.parseFloat(f32, args.next() orelse return usage());
        } else if (std.mem.eql(u8, a, "--size")) {
            const v = args.next() orelse return usage();
            const x = std.mem.indexOfScalar(u8, v, 'x') orelse return usage();
            size = .{ try std.fmt.parseInt(u16, v[0..x], 10), try std.fmt.parseInt(u16, v[x + 1 ..], 10) };
        } else if (std.mem.eql(u8, a, "--theme")) {
            theme_name = try arena.dupe(u8, args.next() orelse return usage());
        } else if (std.mem.eql(u8, a, "--opacity")) {
            opacity = try std.fmt.parseInt(i64, args.next() orelse return usage(), 10);
        } else if (std.mem.eql(u8, a, "--fullscreen")) {
            fullscreen = true;
        } else if (std.mem.eql(u8, a, "--bench")) {
            bench = true;
        } else if (std.mem.eql(u8, a, "--describe")) {
            describe = true;
        } else return usage();
    }

    // The app: --app, else the bundle's own, else hull's defaults.
    const exe_dir = try std.process.executableDirPathAlloc(io, arena);
    const bundled = try std.fs.path.join(arena, &.{ exe_dir, "..", "Resources" });
    const dir = app_dir orelse if (exists(io, try std.fs.path.join(arena, &.{ bundled, "hull.zon" }))) bundled else null;
    var app: config.App = .{};
    if (dir) |d| {
        const path = try std.fs.path.join(arena, &.{ d, "hull.zon" });
        const src = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0);
        app = try config.parse(gpa, arena, src);
    }
    if (theme_name) |t| app.terminal.theme = t;
    if (opacity) |o| app.terminal.background_opacity = config.clampOpacity(o);
    if (size) |sz| {
        app.window.cols = sz[0];
        app.window.rows = sz[1];
    }
    if (program.items.len > 0) app.program = program.items;
    if (describe) {
        // For tools/bundle.sh: who the app is, as shell assignments.
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        const o = &w.interface;
        try o.print("NAME='{s}'\nID='{s}'\nVERSION='{s}'\n", .{ app.name, app.id, app.version });
        if (app.program.len > 0) try o.print("PROGRAM='{s}'\n", .{std.fs.path.basename(app.program[0])});
        if (dir) |d| {
            if (app.program_source) |p| try o.print("PROGRAM_SOURCE='{s}'\n", .{try std.fs.path.resolve(arena, &.{ d, p })});
            if (app.icon) |p| try o.print("ICON='{s}'\n", .{try std.fs.path.resolve(arena, &.{ d, p })});
        }
        try o.flush();
        return;
    }
    if (app.program.len == 0) {
        std.log.err("no program: give one after --, or an app whose hull.zon names it", .{});
        return error.NoProgram;
    }
    // A bare program name is the bundle's (Contents/Resources/program),
    // or beside hull, or in the app's directory.
    var argv = try arena.dupe([]const u8, app.program);
    if (!std.fs.path.isAbsolute(argv[0]) and std.mem.indexOfScalar(u8, argv[0], '/') == null) {
        const places = [_][]const u8{
            try std.fs.path.join(arena, &.{ bundled, "program", argv[0] }),
            try std.fs.path.join(arena, &.{ exe_dir, argv[0] }),
            if (dir) |d| try std.fs.path.join(arena, &.{ d, argv[0] }) else "",
            // unpackaged, from the app's directory: where packaging takes it from
            if (dir != null and app.program_source != null) try std.fs.path.resolve(arena, &.{ dir.?, app.program_source.? }) else "",
        };
        for (places) |p| if (p.len > 0 and exists(io, p)) {
            argv[0] = try std.fs.path.resolve(arena, &.{ try std.process.currentPathAlloc(io, arena), p });
            break;
        };
    } else if (!std.fs.path.isAbsolute(argv[0])) {
        argv[0] = try std.fs.path.resolve(arena, &.{ try std.process.currentPathAlloc(io, arena), argv[0] });
    }
    const bytes = try fontBytes(io, arena, dir, app.terminal);
    var fallback: std.ArrayList([]const u8) = .empty;
    for (app.terminal.font_fallback) |name| {
        const path = if (std.fs.path.isAbsolute(name)) name else if (dir) |d| try std.fs.path.join(arena, &.{ d, name }) else continue;
        const b = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch continue;
        try fallback.append(arena, b);
    }

    if (out) |o| {
        var s: Session = undefined;
        try s.init(gpa, app, bytes, fallback.items, scale);
        defer s.deinit();
        try s.spawn(argv, init.environ_map, null);
        try headless.run(gpa, io, &s, .{ .out = o, .at = at, .also = also, .presses = keys, .fullscreen = fullscreen });
        return;
    }
    try @import("window.zig").run(gpa, app, bytes, fallback.items, argv, init.environ_map, init.environ_map.get("HOME"), .{
        .bench = bench,
        .bench_out = init.environ_map.get("HULL_BENCH_OUT"),
        .snap = init.environ_map.get("HULL_SNAP"),
        .io = io,
    });
}

fn fontBytes(io: std.Io, arena: std.mem.Allocator, dir: ?[]const u8, t: config.Terminal) !font.Fonts.Bytes {
    var b = font.Fonts.default_bytes;
    const names = [4]?[]const u8{ t.font, t.font_bold, t.font_italic, t.font_bold_italic };
    const d = dir orelse return b;
    if (names[0] != null) b = .{ "", "", "", "" };
    for (names, 0..) |n, i| if (n) |name| {
        const path = try std.fs.path.join(arena, &.{ d, name });
        b[i] = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20));
    };
    for (&b) |*x| if (x.len == 0) {
        x.* = b[0];
    };
    return b;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn usage() error{Usage} {
    std.log.err("usage: hull [--app DIR] [--headless OUT.png --at S --keys T:K,...] [-- program args...]", .{});
    return error.Usage;
}

test {
    _ = @import("theme.zig");
    _ = @import("config.zig");
    _ = @import("vt.zig");
    _ = @import("font.zig");
    _ = @import("render.zig");
    _ = @import("cpu.zig");
    _ = @import("keys.zig");
    _ = @import("pngdec.zig");
    _ = @import("settings.zig");
}
