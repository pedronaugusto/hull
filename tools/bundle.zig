//! An app's bundle, made where the app is built:
//!
//!     hull-bundle <hull> <program> <hull.zon> <icon.png|-> <out-dir>
//!     hull-bundle --check <out-dir> <name>
//!
//! The bundle is the app's, never hull's: its name, identifier and version
//! come from the app's hull.zon. hull's runner is its executable, renamed to
//! the app's name so the process, the Dock and the menus say it; the program
//! rides in Resources/program and hull.zon in Resources. On macOS that is
//! `<name>.app`, sealed with an ad-hoc signature; elsewhere the same layout
//! in a folder of the app's name, until each platform's installer is made.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

const Io = std.Io;
const Dir = Io.Dir;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 4 and std.mem.eql(u8, args[1], "--check")) return check(io, arena, args[2], args[3]);
    if (args.len != 6) return usage();
    const zon = try Dir.cwd().readFileAllocOptions(io, args[3], arena, .limited(1 << 20), .of(u8), 0);
    const app = try config.parse(arena, arena, zon);
    try bundle(io, arena, app, .{ .runner = args[1], .program = args[2], .config = args[3], .icon = if (std.mem.eql(u8, args[4], "-")) null else args[4], .out = args[5] });
}

fn usage() error{Usage} {
    std.log.err("usage: hull-bundle <hull> <program> <hull.zon> <icon.png|-> <out-dir>  |  --check <out-dir> <name>", .{});
    return error.Usage;
}

const Paths = struct { runner: []const u8, program: []const u8, config: []const u8, icon: ?[]const u8, out: []const u8 };

fn bundle(io: Io, arena: std.mem.Allocator, app: config.App, p: Paths) !void {
    const mac = builtin.os.tag == .macos;
    const root = if (mac) try arena.print("{s}/{s}.app/Contents", .{ p.out, app.name }) else try arena.print("{s}/{s}", .{ p.out, app.name });
    const exe_dir = if (mac) try arena.print("{s}/MacOS", .{root}) else root;
    const res = if (mac) try arena.print("{s}/Resources", .{root}) else root;
    const cwd = Dir.cwd();
    try cwd.createDirPath(io, exe_dir);
    try cwd.createDirPath(io, try arena.print("{s}/program", .{res}));
    try cwd.copyFile(p.runner, cwd, try arena.print("{s}/{s}", .{ exe_dir, app.name }), io, .{});
    try cwd.copyFile(p.program, cwd, try arena.print("{s}/program/{s}", .{ res, std.fs.path.basename(p.program) }), io, .{});
    try cwd.copyFile(p.config, cwd, try arena.print("{s}/hull.zon", .{res}), io, .{});
    if (!mac) return;
    const icon = if (p.icon) |path| try icns(io, arena, path, try arena.print("{s}/AppIcon.icns", .{res})) else false;
    try cwd.writeFile(io, .{ .sub_path = try arena.print("{s}/Info.plist", .{root}), .data = try plist(arena, app, icon) });
    // ad-hoc, so Apple silicon runs what was copied and the bundle is sealed; a release signs it properly
    sign(io, arena, try arena.print("{s}/program/{s}", .{ res, std.fs.path.basename(p.program) }));
    sign(io, arena, try arena.print("{s}/{s}.app", .{ p.out, app.name }));
}

fn plist(arena: std.mem.Allocator, app: config.App, icon: bool) ![]const u8 {
    return arena.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleName</key><string>{[name]f}</string>
        \\  <key>CFBundleDisplayName</key><string>{[name]f}</string>
        \\  <key>CFBundleExecutable</key><string>{[name]f}</string>
        \\  <key>CFBundleIdentifier</key><string>{[id]f}</string>
        \\  <key>CFBundleVersion</key><string>{[version]f}</string>
        \\  <key>CFBundleShortVersionString</key><string>{[version]f}</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        \\{[icon]s}  <key>LSMinimumSystemVersion</key><string>13.0</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
        \\</dict>
        \\</plist>
        \\
    , .{
        .name = Xml{ .s = app.name },
        .id = Xml{ .s = app.id },
        .version = Xml{ .s = app.version },
        .icon = if (icon) "  <key>CFBundleIconFile</key><string>AppIcon</string>\n" else "",
    });
}

/// Text as XML says it: `&`, `<` and `>` escaped.
const Xml = struct {
    s: []const u8,

    pub fn format(x: Xml, w: *Io.Writer) Io.Writer.Error!void {
        for (x.s) |ch| switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            else => try w.writeByte(ch),
        };
    }
};

// An .icns holding the PNG as it is, under the type of its size: macOS scales it for every place it shows.
fn icns(io: Io, arena: std.mem.Allocator, png_path: []const u8, out: []const u8) !bool {
    const png = try Dir.cwd().readFileAlloc(io, png_path, arena, .limited(16 << 20));
    if (png.len < 24 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return error.IconNotPng;
    const w = std.mem.readInt(u32, png[16..20], .big);
    const h = std.mem.readInt(u32, png[20..24], .big);
    if (w != h) return error.IconNotSquare;
    const kind: *const [4]u8 = switch (w) {
        16 => "icp4",
        32 => "icp5",
        64 => "icp6",
        128 => "ic07",
        256 => "ic08",
        512 => "ic09",
        1024 => "ic10",
        else => return error.IconSize,
    };
    var data: std.ArrayList(u8) = .empty;
    const total: u32 = @intCast(8 + 8 + png.len); // safe: held below 16 MiB
    try data.appendSlice(arena, "icns");
    try data.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, total)));
    try data.appendSlice(arena, kind);
    try data.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, @as(u32, @intCast(8 + png.len))))); // safe: as above
    try data.appendSlice(arena, png);
    try Dir.cwd().writeFile(io, .{ .sub_path = out, .data = data.items });
    return true;
}

// An ad-hoc signature; a machine without codesign leaves the bundle unsigned.
fn sign(io: Io, arena: std.mem.Allocator, path: []const u8) void {
    const r = std.process.run(arena, io, .{ .argv = &.{ "codesign", "--force", "--sign", "-", path } }) catch return;
    _ = r;
}

// The bundle in `out` is `name`'s: its executable, its program, its hull.zon and, on macOS, its Info.plist.
fn check(io: Io, arena: std.mem.Allocator, out: []const u8, name: []const u8) !void {
    const mac = builtin.os.tag == .macos;
    const root = if (mac) try arena.print("{s}/{s}.app/Contents", .{ out, name }) else try arena.print("{s}/{s}", .{ out, name });
    const exe = if (mac) try arena.print("{s}/MacOS/{s}", .{ root, name }) else try arena.print("{s}/{s}", .{ root, name });
    const res = if (mac) try arena.print("{s}/Resources", .{root}) else root;
    const cwd = Dir.cwd();
    try cwd.access(io, exe, .{});
    try cwd.access(io, try arena.print("{s}/hull.zon", .{res}), .{});
    var programs = try cwd.openDir(io, try arena.print("{s}/program", .{res}), .{ .iterate = true });
    defer programs.close(io);
    var it = programs.iterate();
    if (try it.next(io) == null) return error.NoProgram;
    if (!mac) return;
    const info = try cwd.readFileAlloc(io, try arena.print("{s}/Info.plist", .{root}), arena, .limited(1 << 16));
    const named = try arena.print("<key>CFBundleName</key><string>{s}</string>", .{name});
    if (std.mem.find(u8, info, named) == null) return error.NotNamed;
}
