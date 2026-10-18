const std = @import("std");

/// hull: a terminal program of the family in a window of its own.
///
///     zig build                      hull, the runner (window or headless)
///     zig build app -Dapp=apps/wake  the .app for an app's hull.zon
///     zig build test                 the units
///
/// libghostty-vt and raylib come from libs/, a build of their own with the Zig
/// their pins need (0.16.0, fetched by tools/zig16.sh), as C static
/// libraries: hull reaches both through their C APIs alone.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "debug · safe (default) · fast · small") orelse .safe;

    // libghostty-vt, ReleaseFast whatever hull is built as: Debug terminal
    // code is very slow, and its checks are ghostty's to run. HULL_VT_ZIG
    // names the Zig 0.16.0 by hand.
    const vt_build = b.addSystemCommand(&.{"sh"});
    vt_build.addFileArg(b.path("tools/libs.sh"));
    const vt_out = vt_build.addOutputDirectoryArg("libs");
    vt_build.addFileInput(b.path("libs/build.zig"));
    vt_build.addFileInput(b.path("libs/build.zig.zon"));

    const vt_h = b.addTranslateC(.{
        .root_source_file = vt_out.path(b, "include/ghostty/vt.h"),
        .target = target,
        .optimize = optimize,
    });
    vt_h.addIncludePath(vt_out.path(b, "include"));
    vt_h.defineCMacro("GHOSTTY_STATIC", null);

    const rl_h = b.addTranslateC(.{
        .root_source_file = b.path("src/c/rl.h"),
        .target = target,
        .optimize = optimize,
    });
    rl_h.addIncludePath(vt_out.path(b, "include"));

    const zt = b.dependency("ztypeset", .{ .target = target, .optimize = optimize });

    // What a program inside hull imports to see hull's settings: std and
    // strand, nothing of the terminal or the window.
    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    const protocol = b.addModule("hull-protocol", .{
        .root_source_file = b.path("protocol/hull_protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "strand", .module = strand }},
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // libghostty-vt's SIMD paths are C++ (simdutf, highway)
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "vt", .module = vt_h.createModule() },
            .{ .name = "rl", .module = rl_h.createModule() },
            .{ .name = "hull-protocol", .module = protocol },
            .{ .name = "strand", .module = strand },
            .{ .name = "ztypeset", .module = zt.module("ztypeset") },
        },
    });
    mod.addObjectFile(vt_out.path(b, "lib/libghostty-vt-static.a"));
    mod.addObjectFile(vt_out.path(b, "lib/libraylib.a"));
    if (target.result.os.tag == .macos) {
        for ([_][]const u8{ "OpenGL", "Cocoa", "IOKit", "CoreVideo", "CoreFoundation", "CoreGraphics" }) |f| mod.linkFramework(f, .{});
    }
    mod.addAnonymousImport("fonts", .{ .root_source_file = b.path("fonts/fonts.zig") });
    const exe = b.addExecutable(.{ .name = "hull", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run hull: `zig build run -- [--headless out.png] -- program args`").dependOn(&run.step);

    // An app: its hull.zon, its program and its icon, as a bundle.
    const app_dir = b.option([]const u8, "app", "The app directory with hull.zon to package (default apps/wake)") orelse "apps/wake";
    const bundle = b.addSystemCommand(&.{"sh"});
    bundle.addFileArg(b.path("tools/bundle.sh"));
    bundle.addArtifactArg(exe);
    bundle.addDirectoryArg(b.path(app_dir));
    const bundled = bundle.addOutputDirectoryArg("app");
    bundle.has_side_effects = true;
    const install_app = b.addInstallDirectory(.{ .source_dir = bundled, .install_dir = .prefix, .install_subdir = "app" });
    b.step("app", "Package an app's .app into zig-out/app").dependOn(&install_app.step);

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run the units");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = protocol })).step);
}
