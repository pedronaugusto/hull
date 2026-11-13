//! The smallest program hull packages: a line, then it waits for the window to close.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try out.interface.writeAll("\x1b[2J\x1b[Hhello from inside hull\r\n");
    try out.interface.flush();
    var in_buf: [64]u8 = undefined;
    var in = std.Io.File.stdin().reader(init.io, &in_buf);
    // the window closing ends the input; a terminal that hangs up may fail the read instead, which ends it too
    _ = try in.interface.discardRemaining();
}
