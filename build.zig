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
    // Asked for where SDL3 does not build: refused as the build is configured, naming why.
    if (!windowed(target.result)) std.debug.panic("hull's runner draws through SDL3, which builds for {s}; {t} {t} has hull-protocol alone (`.runner = false`)", .{ windowed_targets, target.result.cpu.arch, target.result.os.tag });
    const themes = themesTable(b, try b.dependencyLazy("ghostty_themes", .{}));
    const deps: RunnerDeps = .{
        .ghostty = try b.dependencyLazy("ghostty", ghosttyArgs(target)),
        .sdl = try b.dependencyLazy("sdl", .{ .target = target, .optimize = optimize }),
        .ztypeset = try b.dependencyLazy("ztypeset", .{ .target = target, .optimize = optimize }),
        .aegis = try b.dependencyLazy("aegis", .{ .target = target, .optimize = optimize }),
        .conduit = try b.dependencyLazy("conduit", .{ .target = target, .optimize = optimize }),
    };
    const runner = b.addExecutable(.{ .name = "hull", .root_module = runnerModule(b, target, optimize, protocol, strand, themes, deps) });
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
/// step of it: `b.step("app", "…").dependOn(packaged.step)`. `error.LazyDependencyNeeded` while hull's own
/// dependencies are still to be fetched: hull has no runner yet, and the build returns the error so that it is
/// fetched and configured again.
pub fn addApp(b: *std.Build, hull: *std.Build.Dependency, app: App) error{LazyDependencyNeeded}!Packaged {
    if (hull.builder.graph.needed_lazy_dependencies.count() != 0) return error.LazyDependencyNeeded;
    return package(b, hull, app);
}

// `addApp` once hull's runner and bundler are declared.
fn package(b: *std.Build, hull: *std.Build.Dependency, app: App) Packaged {
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
    // The runner and its tests where SDL3 builds (`windowed`); elsewhere hull is hull-protocol, and its tests are the protocol's and the themes table's.
    const runner = windowed(target.result);
    const hull = b.dependency("hull", .{ .target = target, .optimize = optimize, .runner = runner });
    const p = hull.builder;
    const test_step = b.step("test", "Run the tests");
    const strand = p.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    const protocol = hull.module("hull-protocol");
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown");
    const table_tests = b.addTest(.{ .name = "hull-themes-tests", .filters = filters, .root_module = b.createModule(.{ .root_source_file = p.path("tools/themes.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(table_tests).step);
    const protocol_tests = b.addTest(.{ .name = "hull-protocol-tests", .filters = filters, .root_module = protocol });
    protocol_tests.root_module.addImport("shakedown", shakedown);
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);
    if (runner) runnerTests(b, hull, target, optimize, filters, strand, shakedown, test_step);
    tools.preflight.addCi(b, p, .{ .tests = test_step });
}

/// The targets SDL3 builds for, as `windowed` reads them: its Linux build takes per-target headers (D-Bus's, GLib's) for these alone.
const windowed_targets = "x86_64 and aarch64 Linux, macOS and Windows";

/// Whether hull's runner builds for `t`: where SDL3 does.
fn windowed(t: std.Target) bool {
    return switch (t.os.tag) {
        .macos, .windows => true,
        .linux => t.cpu.arch == .x86_64 or t.cpu.arch == .aarch64,
        else => false,
    };
}

/// The runner's units, the properties of hull.zon, and an example app packaged through `addApp` and checked.
fn runnerTests(b: *std.Build, hull: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, filters: []const []const u8, strand: *std.Build.Module, shakedown: *std.Build.Module, test_step: *std.Build.Step) void {
    const p = hull.builder;
    const protocol = hull.module("hull-protocol");
    // `dependency` fetches a lazy one itself: it ends this pass and runs the build again once it has it
    const themes = themesTable(p, p.dependency("ghostty_themes", .{}));
    const deps: RunnerDeps = .{
        .ghostty = p.dependency("ghostty", ghosttyArgs(target)),
        .sdl = p.dependency("sdl", .{ .target = target, .optimize = optimize }),
        .ztypeset = p.dependency("ztypeset", .{ .target = target, .optimize = optimize }),
        .aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }),
        .conduit = p.dependency("conduit", .{ .target = target, .optimize = optimize }),
    };
    const units = b.addTest(.{ .name = "hull-tests", .filters = filters, .root_module = runnerModule(p, target, optimize, protocol, strand, themes, deps) });
    // The properties of hull.zon: shakedown, in the development graph alone.
    units.root_module.addImport("shakedown", shakedown);
    test_step.dependOn(&b.addRunArtifact(units).step);

    // an app as a program's build makes one: a program of its own, packaged, and its bundle checked
    const example = b.addExecutable(.{ .name = "hello", .root_module = b.createModule(.{
        .root_source_file = p.path("examples/hello/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    // `dependency` fetched each of hull's dependencies above, so its runner and bundler are declared.
    const packaged = package(b, hull, .{ .program = example, .config = p.path("examples/hello/hull.zon") });
    const check = b.addRunArtifact(hull.artifact("hull-bundle"));
    check.addArg("--check");
    check.addDirectoryArg2(packaged.dir, .{});
    check.addArg("Hello");
    test_step.dependOn(&check.step);
}

// Ghostty's themes as hull's table, written by `tools/themes.zig` where hull is built from the folder Ghostty pins.
fn themesTable(b: *std.Build, folder: *std.Build.Dependency) std.Build.LazyPath {
    const tool = b.addExecutable(.{ .name = "hull-themes", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/themes.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    }) });
    const run = b.addRunArtifact(tool);
    run.addDirectoryArg2(folder.path(""), .{});
    return run.addOutputFileArg2("themes.zig", .{});
}

// The runner's dependencies, each lazy: libghostty-vt from Ghostty's Zig 0.17 tree, SDL3 for the window, ztypeset
// for the type, conduit for the program.
const RunnerDeps = struct {
    ghostty: *std.Build.Dependency,
    sdl: *std.Build.Dependency,
    ztypeset: *std.Build.Dependency,
    aegis: *std.Build.Dependency,
    conduit: *std.Build.Dependency,
};

// ReleaseFast whatever hull is built as: Debug terminal code is very slow, and its checks are Ghostty's to run. No
// SIMD: its paths are C++ (simdutf, highway) the static archive does not carry at this commit.
fn ghosttyArgs(target: std.Build.ResolvedTarget) struct { target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, simd: bool } {
    return .{ .target = target, .optimize = .fast, .simd = false };
}

// The runner's module, on its dependencies.
fn runnerModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, protocol: *std.Build.Module, strand: *std.Build.Module, themes: std.Build.LazyPath, deps: RunnerDeps) *std.Build.Module {
    const ghostty = deps.ghostty;
    const sdl = deps.sdl;
    const zt = deps.ztypeset;
    const aegis = deps.aegis;
    const conduit = deps.conduit;
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
