const std = @import("std");

/// hull's C libraries, each built by the Zig its pin needs (0.16.0) and
/// installed into the prefix as a static library with its headers:
/// libghostty-vt (its C API) and raylib (GLFW and OpenGL underneath).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // No SIMD: its paths are C++ (simdutf, highway) that the static
    // archive does not carry at this commit; tycho's bay builds it so too.
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = optimize, .simd = false });
    b.installArtifact(ghostty.artifact("ghostty-vt-static"));
    // Only what a terminal's window needs: the core, textures and shapes.
    const raylib = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .platform = .glfw,
        .raudio = false,
        .rmodels = false,
        .rtext = false,
        .raygui = false,
        .linkage = .static,
    });
    b.installArtifact(raylib.artifact("raylib"));
}
