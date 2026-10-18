//! A canvas as a PNG: RGBA with its alpha, so a translucent background
//! is translucent in the file, or over a matte to see it as a desktop would.
const std = @import("std");
const Canvas = @import("cpu.zig").Canvas;

pub const Matte = union(enum) {
    /// Keep the alpha.
    none,
    /// Over a checkerboard of `size` pixels, as image editors show alpha.
    checker: u32,
};

pub fn write(gpa: std.mem.Allocator, cv: Canvas, matte: Matte, out: *std.Io.Writer) !void {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try raw.ensureTotalCapacity(gpa, (cv.w * 4 + 1) * cv.h);
    var y: u32 = 0;
    while (y < cv.h) : (y += 1) {
        raw.appendAssumeCapacity(0);
        for (cv.px[y * cv.w ..][0..cv.w], 0..) |p, x| {
            var a: u32 = p >> 24;
            var r: u32 = (p >> 16) & 0xff;
            var g: u32 = (p >> 8) & 0xff;
            var b: u32 = p & 0xff;
            switch (matte) {
                .none => if (a != 0 and a != 255) {
                    r = @min(255, (r * 255 + a / 2) / a);
                    g = @min(255, (g * 255 + a / 2) / a);
                    b = @min(255, (b * 255 + a / 2) / a);
                },
                .checker => |s| {
                    const light = ((x / s) + (y / s)) % 2 == 0;
                    const m: u32 = if (light) 0xd8 else 0x9a;
                    const inv = 255 - a;
                    r += (m * inv + 127) / 255;
                    g += (m * inv + 127) / 255;
                    b += (m * inv + 127) / 255;
                    a = 255;
                },
            }
            raw.appendSliceAssumeCapacity(&.{ @intCast(@min(r, 255)), @intCast(@min(g, 255)), @intCast(@min(b, 255)), @intCast(a) });
        }
    }

    var z: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 20);
    defer z.deinit();
    {
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        var comp = try std.compress.flate.Compress.init(&z.writer, window, .zlib, .level_6);
        try comp.writer.writeAll(raw.items);
        try comp.finish();
    }

    try out.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], cv.w, .big);
    std.mem.writeInt(u32, ihdr[4..8], cv.h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(out, "IHDR", &ihdr);
    try chunk(out, "IDAT", z.written());
    try chunk(out, "IEND", "");
}

fn chunk(out: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.writeAll(&len);
    try out.writeAll(kind);
    try out.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.writeAll(&sum);
}
