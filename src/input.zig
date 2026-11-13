//! The files hull reads: an app's hull.zon and the faces it names, and the
//! player's saved settings. Each is read whole, under a limit, by aegis's
//! readFile, which returns a cancel wherever it lands. What comes back is
//! parsed by its reader (config, the font library, the settings' JSON),
//! never taken as it comes.
const std = @import("std");
const aegis = @import("aegis");

/// Why a read failed: the open, the length, the read, memory, or a file past its limit.
pub const Error = aegis.own.ReadFileError;
/// The most of a file read.
pub const Limit = aegis.units.Bytes(u64);

/// The most of an app's hull.zon read.
pub const app_limit: Limit = .literal("1MiB");
/// The most of a font file read.
pub const font_limit: Limit = .literal("64MiB");
/// The most of the saved settings read.
pub const settings_limit: Limit = .literal("64KiB");

/// The bytes at `path`, at most `limit` of them, on `gpa`, owned by the caller.
pub fn read(io: std.Io, path: []const u8, gpa: std.mem.Allocator, limit: Limit) Error![]u8 {
    return aegis.own.readFile(io, std.Io.Dir.cwd(), path, gpa, limit);
}

/// `read`, followed by a 0: source a parser reads to its end.
pub fn readSource(io: std.Io, path: []const u8, gpa: std.mem.Allocator, limit: Limit) Error![:0]u8 {
    return aegis.own.readFileSentinel(io, std.Io.Dir.cwd(), path, gpa, limit, 0);
}
