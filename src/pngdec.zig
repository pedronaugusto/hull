//! PNG to RGBA, for kitty pictures sent as `f=100`: libghostty-vt built as a
//! C library has no PNG decoder of its own and asks its embedder for one.
//! Non-interlaced and Adam7, every colour type, bit depths 1 to 16
//! (16 taken to its high byte), the palette's transparency.
const std = @import("std");

pub const Image = struct { w: u32, h: u32, rgba: []u8 };

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.NotPng;
    var w: u32 = 0;
    var h: u32 = 0;
    var depth: u8 = 0;
    var color: u8 = 0;
    var interlace: u8 = 0;
    var plte: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var trns_gray: ?u16 = null;
    var trns_rgb: ?[3]u16 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var at: usize = 8;
    while (at + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
        const kind = bytes[at + 4 ..][0..4];
        if (at + 12 + len > bytes.len) return error.Truncated;
        const data = bytes[at + 8 ..][0..len];
        at += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.BadHeader;
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
            depth = data[8];
            color = data[9];
            interlace = data[12];
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            for (0..@min(256, len / 3)) |i| plte[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            switch (color) {
                3 => for (0..@min(256, len)) |i| {
                    plte[i][3] = data[i];
                },
                0 => if (len >= 2) {
                    trns_gray = std.mem.readInt(u16, data[0..2], .big);
                },
                2 => if (len >= 6) {
                    trns_rgb = .{ std.mem.readInt(u16, data[0..2], .big), std.mem.readInt(u16, data[2..4], .big), std.mem.readInt(u16, data[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (w == 0 or h == 0 or w > 1 << 15 or h > 1 << 15) return error.BadSize;
    const channels: u32 = switch (color) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.BadColor,
    };
    const bpp_bits = channels * depth;
    const bpp = @max(1, bpp_bits / 8);

    var in: std.Io.Reader = .fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var z: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    const raw = try z.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(raw);

    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    errdefer gpa.free(out);
    const none: Pass = .{ .x = 0, .y = 0, .dx = 0, .dy = 0 };
    const single = [7]Pass{ .{ .x = 0, .y = 0, .dx = 1, .dy = 1 }, none, none, none, none, none, none };
    const passes = if (interlace == 1) adam7 else single;
    var pos: usize = 0;
    var prev: std.ArrayList(u8) = .empty;
    defer prev.deinit(gpa);
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(gpa);
    for (passes) |p| {
        if (p.dx == 0) break;
        const pw = (w + p.dx - 1 - p.x) / p.dx;
        const ph = (h + p.dy - 1 - p.y) / p.dy;
        if (p.x >= w or p.y >= h or pw == 0 or ph == 0) continue;
        const stride = (pw * bpp_bits + 7) / 8;
        try prev.resize(gpa, stride);
        @memset(prev.items, 0);
        try cur.resize(gpa, stride);
        var y: u32 = 0;
        while (y < ph) : (y += 1) {
            if (pos + 1 + stride > raw.len) return error.Truncated;
            const filter = raw[pos];
            @memcpy(cur.items, raw[pos + 1 ..][0..stride]);
            pos += 1 + stride;
            unfilter(filter, cur.items, prev.items, bpp);
            var x: u32 = 0;
            while (x < pw) : (x += 1) {
                const px = pixel(cur.items, x, color, depth, &plte, trns_gray, trns_rgb);
                const ox = p.x + x * p.dx;
                const oy = p.y + y * p.dy;
                @memcpy(out[(@as(usize, oy) * w + ox) * 4 ..][0..4], &px);
            }
            std.mem.swap(std.ArrayList(u8), &prev, &cur);
        }
    }
    return .{ .w = w, .h = h, .rgba = out };
}

const Pass = struct { x: u32, y: u32, dx: u32, dy: u32 };
const adam7 = [7]Pass{
    .{ .x = 0, .y = 0, .dx = 8, .dy = 8 }, .{ .x = 4, .y = 0, .dx = 8, .dy = 8 },
    .{ .x = 0, .y = 4, .dx = 4, .dy = 8 }, .{ .x = 2, .y = 0, .dx = 4, .dy = 4 },
    .{ .x = 0, .y = 2, .dx = 2, .dy = 4 }, .{ .x = 1, .y = 0, .dx = 2, .dy = 2 },
    .{ .x = 0, .y = 1, .dx = 1, .dy = 2 },
};

fn unfilter(filter: u8, cur: []u8, prev: []const u8, bpp: u32) void {
    for (cur, 0..) |*c, i| {
        const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
        const b = prev[i];
        const cc: u8 = if (i >= bpp) prev[i - bpp] else 0;
        c.* = switch (filter) {
            1 => c.* +% a,
            2 => c.* +% b,
            3 => c.* +% @as(u8, @intCast((@as(u16, a) + b) / 2)),
            4 => c.* +% paeth(a, b, cc),
            else => c.*,
        };
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn sample(row: []const u8, i: u32, depth: u8) u16 {
    return switch (depth) {
        16 => std.mem.readInt(u16, row[i * 2 ..][0..2], .big),
        8 => row[i],
        else => blk: {
            const bit = i * depth;
            const byte = row[bit / 8];
            const shift: u3 = @intCast(8 - depth - (bit % 8));
            const mask: u8 = (@as(u8, 1) << @intCast(depth)) - 1;
            break :blk (byte >> shift) & mask;
        },
    };
}

fn to8(v: u16, depth: u8) u8 {
    return switch (depth) {
        16 => @intCast(v >> 8),
        8 => @intCast(v),
        else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(depth)) - 1)),
    };
}

fn pixel(row: []const u8, x: u32, color: u8, depth: u8, plte: *const [256][4]u8, tg: ?u16, trgb: ?[3]u16) [4]u8 {
    switch (color) {
        3 => return plte[sample(row, x, depth) & 0xff],
        0 => {
            const g = sample(row, x, depth);
            return .{ to8(g, depth), to8(g, depth), to8(g, depth), if (tg != null and tg.? == g) 0 else 255 };
        },
        4 => {
            const g = sample(row, x * 2, depth);
            return .{ to8(g, depth), to8(g, depth), to8(g, depth), to8(sample(row, x * 2 + 1, depth), depth) };
        },
        2 => {
            const r = sample(row, x * 3, depth);
            const g = sample(row, x * 3 + 1, depth);
            const b = sample(row, x * 3 + 2, depth);
            const t = if (trgb) |t| t[0] == r and t[1] == g and t[2] == b else false;
            return .{ to8(r, depth), to8(g, depth), to8(b, depth), if (t) 0 else 255 };
        },
        else => return .{
            to8(sample(row, x * 4, depth), depth),     to8(sample(row, x * 4 + 1, depth), depth),
            to8(sample(row, x * 4 + 2, depth), depth), to8(sample(row, x * 4 + 3, depth), depth),
        },
    }
}

test "a PNG hull wrote reads back" {
    const gpa = std.testing.allocator;
    const px = [_]u32{ 0xff112233, 0x80000000, 0x00000000, 0xffffffff };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try @import("png.zig").write(gpa, .{ .px = @constCast(&px), .w = 2, .h = 2 }, &out.writer);
    const img = try decode(gpa, out.written());
    defer gpa.free(img.rgba);
    try std.testing.expectEqual(@as(u32, 2), img.w);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0xff }, img.rgba[0..4]);
    try std.testing.expectEqual(@as(u8, 0x80), img.rgba[7]);
}
