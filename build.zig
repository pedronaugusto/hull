const std = @import("std");

/// hull: a terminal program in a native window of its own, shipped as an
/// app. What a program's build takes from it:
///
/// - `addApp(b, hull, .{ .program, .config, .icon })`: the program as an app,
///   its runner built for the program's target and the bundle made for it.
/// - the `hull-protocol` module: what a program inside hull imports to see
///   hull's settings, std and strand alone.
///
/// The runner (`hull`, a window or headless) and the bundler are built here;
/// the tests and the gate are `dev`'s. A program that only speaks
/// hull-protocol asks for hull with `.runner = false`, and fetches nothing of
/// the window's: its terminal, its window and its type are lazy dependencies.
pub fn build(b: *std.Build) error{LazyDependencyNeeded}!void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.lang.Optimize, "optimize", "debug · safe (default) · fast · small") orelse .safe;
    const with_runner = b.option(bool, "runner", "Build the runner and the bundler (default on); off, hull is its protocol alone") orelse true;

    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    const protocol = b.addModule("hull-protocol", .{
        .root_source_file = b.path("protocol/hull_protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "strand", .module = strand }},
    });
    if (!with_runner) return;
    const themes = try themesTable(b);
    const runner = b.addExecutable(.{ .name = "hull", .root_module = try runnerModule(b, target, optimize, protocol, strand, themes) });
    b.installArtifact(runner);
    const run = b.addRunArtifact(runner);
    run.addPassthruArgs();
    b.step("run", "Run hull: `zig build run -- [--app DIR] [--headless out.png] -- program args`").dependOn(&run.step);

    // the bundler runs where the app is built
    const host = b.graph.host;
    const bundler = b.addExecutable(.{ .name = "hull-bundle", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/bundle.zig"),
        .target = host,
        .optimize = .safe,
        .imports = &.{.{ .name = "config", .module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = host,
            .optimize = .safe,
            .imports = &.{.{ .name = "ghostty_themes", .module = b.createModule(.{ .root_source_file = themes, .target = host, .optimize = .safe }) }},
        }) }},
    }) });
    b.installArtifact(bundler);
}

/// An app: the program hull runs, and who it is.
pub const App = struct {
    /// The program inside, the app's own executable, unchanged.
    program: *std.Build.Step.Compile,
    /// The app's `hull.zon`: its name, identifier and version, its window and its terminal.
    config: std.Build.LazyPath,
    /// A square PNG, 1024 pixels a side, for every size a platform asks.
    icon: ?std.Build.LazyPath = null,
};

/// The app as built: the step that installs it into the prefix's `app/`, and where the bundle is.
pub const Packaged = struct {
    step: *std.Build.Step,
    dir: std.Build.LazyPath,
};

/// `app` packaged by `hull`, a dependency asked for the program's target: on macOS a bundle named for the app,
/// hull's runner inside it under the app's name, the program and its `hull.zon` beside. The app's build makes a
/// step of it: `b.step("app", "…").dependOn(packaged.step)`.
pub fn addApp(b: *std.Build, hull: *std.Build.Dependency, app: App) Packaged {
    const bundle = b.addRunArtifact(hull.artifact("hull-bundle"));
    bundle.addArtifactArg2(hull.artifact("hull"), .{});
    bundle.addArtifactArg2(app.program, .{});
    bundle.addFileArg2(app.config, .{});
    if (app.icon) |icon| bundle.addFileArg2(icon, .{}) else bundle.addArg("-");
    const dir = bundle.addOutputDirectoryArg2("app", .{});
    const install = b.addInstallDirectory(.{ .source_dir = dir, .install_dir = .prefix, .install_subdir = "app" });
    return .{ .step = &install.step, .dir = dir };
}

/// hull's development: the runner's units, the protocol's, and an example app packaged through `addApp` and
/// checked, under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const hull = b.dependency("hull", .{ .target = target, .optimize = optimize });
    const p = hull.builder;
    const test_step = b.step("test", "Run the tests");
    const strand = p.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    const protocol = hull.module("hull-protocol");
    const themes = themesTable(p) catch return;
    const units = b.addTest(.{ .name = "hull-tests", .filters = filters, .root_module = runnerModule(p, target, optimize, protocol, strand, themes) catch return });
    const table_tests = b.addTest(.{ .name = "hull-themes-tests", .filters = filters, .root_module = b.createModule(.{ .root_source_file = p.path("tools/themes.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(table_tests).step);
    test_step.dependOn(&b.addRunArtifact(units).step);
    const protocol_tests = b.addTest(.{ .name = "hull-protocol-tests", .filters = filters, .root_module = protocol });
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);

    // an app as a program's build makes one: a program of its own, packaged, and its bundle checked
    const example = b.addExecutable(.{ .name = "hello", .root_module = b.createModule(.{
        .root_source_file = p.path("examples/hello/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const packaged = addApp(b, hull, .{ .program = example, .config = p.path("examples/hello/hull.zon") });
    const check = b.addRunArtifact(hull.artifact("hull-bundle"));
    check.addArg("--check");
    check.addDirectoryArg2(packaged.dir, .{});
    check.addArg("Hello");
    test_step.dependOn(&check.step);
    tools.preflight.addCi(b, p, .{ .tests = test_step });
}

// Ghostty's themes as hull's table, written by `tools/themes.zig` where hull is built from the folder Ghostty pins.
fn themesTable(b: *std.Build) error{LazyDependencyNeeded}!std.Build.LazyPath {
    const folder = try b.dependencyLazy("ghostty_themes", .{});
    const tool = b.addExecutable(.{ .name = "hull-themes", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/themes.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    }) });
    const run = b.addRunArtifact(tool);
    run.addDirectoryArg2(folder.path(""), .{});
    return run.addOutputFileArg2("themes.zig", .{});
}

// The runner: libghostty-vt from Ghostty's Zig 0.17 tree, SDL3 for the window, ztypeset for the type, conduit for
// the program, each a lazy dependency that asking for it here fetches.
fn runnerModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, protocol: *std.Build.Module, strand: *std.Build.Module, themes: std.Build.LazyPath) error{LazyDependencyNeeded}!*std.Build.Module {
    // ReleaseFast whatever hull is built as: Debug terminal code is very slow, and its checks are Ghostty's to
    // run. No SIMD: its paths are C++ (simdutf, highway) the static archive does not carry at this commit.
    const ghostty = try b.dependencyLazy("ghostty", .{ .target = target, .optimize = .fast, .simd = false });
    const sdl = try b.dependencyLazy("sdl", .{ .target = target, .optimize = optimize });
    const zt = try b.dependencyLazy("ztypeset", .{ .target = target, .optimize = optimize });
    const aegis = try b.dependencyLazy("aegis", .{ .target = target, .optimize = optimize });
    const conduit = try b.dependencyLazy("conduit", .{ .target = target, .optimize = optimize });
    const vt_h = b.addTranslateC(.{ .root_source_file = ghostty.path("include/ghostty/vt.h"), .target = target, .optimize = optimize });
    vt_h.addIncludePath(ghostty.path("include"));
    vt_h.defineCMacro("GHOSTTY_STATIC", null);
    const sdl_h = b.addTranslateC(.{ .root_source_file = b.path("src/c/sdl.h"), .target = target, .optimize = optimize });
    sdl_h.addIncludePath(sdl.path("include"));
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "vt", .module = vt_h.createModule() },
            .{ .name = "sdl", .module = sdl_h.createModule() },
            .{ .name = "hull-protocol", .module = protocol },
            .{ .name = "strand", .module = strand },
            .{ .name = "ztypeset", .module = zt.module("ztypeset") },
            .{ .name = "aegis", .module = aegis.module("aegis") },
            .{ .name = "conduit", .module = conduit.module("conduit") },
        },
    });
    mod.linkLibrary(ghostty.artifact("ghostty-vt-static"));
    mod.linkLibrary(sdl.artifact("SDL3"));
    mod.addAnonymousImport("fonts", .{ .root_source_file = b.path("fonts/fonts.zig") });
    mod.addAnonymousImport("ghostty_themes", .{ .root_source_file = themes });
    return mod;
}
