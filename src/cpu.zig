//! The renderer's backend on the CPU: what the GPU does, into a pixel
//! buffer, for a frame without a display (a test, a PNG). It blends as the
//! window's backend does, premultiplied over, so the two agree.
const std = @import("std");
const render = @import("render.zig");
const Rect = render.Rect;
const Color = render.Color;

/// Premultiplied pixels, one 0xAARRGGBB word each (BGRA bytes).
pub const Canvas = struct {
    px: []u32 = &.{},
    w: u32 = 0,
    h: u32 = 0,

    fn row(cv: Canvas, y: u32) []u32 {
        return cv.px[y * cv.w ..][0..cv.w];
    }
};

const Img = struct { w: u32, h: u32, px: []u32 };

pub const Cpu = struct {
    gpa: std.mem.Allocator,
    canvas: Canvas = .{},
    atlas: []u8,
    images: std.AutoHashMapUnmanaged(u64, Img) = .empty,
    frames: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) !Cpu {
        const atlas = try gpa.alloc(u8, render.atlas_size * render.atlas_size);
        @memset(atlas, 0);
        return .{ .gpa = gpa, .atlas = atlas };
    }

    pub fn deinit(p: *Cpu) void {
        var it = p.images.valueIterator();
        while (it.next()) |i| p.gpa.free(i.px);
        p.images.deinit(p.gpa);
        p.gpa.free(p.atlas);
        p.gpa.free(p.canvas.px);
    }

    pub fn backend(p: *Cpu) render.Backend {
        return .{ .ptr = p, .vtable = &vtable };
    }

    const vtable: render.Backend.VTable = .{
        .begin = begin,
        .atlas = atlasUpload,
        .image = image,
        .drop = drop,
        .rect = rect,
        .glyph = glyph,
        .quad = quad,
        .present = present,
    };

    fn self(ptr: *anyopaque) *Cpu {
        return @ptrCast(@alignCast(ptr)); // safe: the backend's own pointer, made by `backend`
    }

    fn begin(ptr: *anyopaque, w: u32, h: u32, ground: Color) void {
        const p = self(ptr);
        if (p.canvas.w != w or p.canvas.h != h) {
            p.gpa.free(p.canvas.px);
            p.canvas = .{ .px = p.gpa.alloc(u32, @as(usize, w) * h) catch &.{}, .w = w, .h = h };
            if (p.canvas.px.len == 0) p.canvas = .{};
        }
        @memset(p.canvas.px, premul(ground));
    }

    fn atlasUpload(ptr: *anyopaque, r: Rect, pixels: []const u8) void {
        const p = self(ptr);
        for (0..r.h) |j| {
            const at = (@as(usize, @intCast(r.y)) + j) * render.atlas_size + @as(usize, @intCast(r.x));
            @memcpy(p.atlas[at..][0..r.w], pixels[j * r.w ..][0..r.w]);
        }
    }

    fn image(ptr: *anyopaque, key: u64, w: u32, h: u32, rgba: []const u8) void {
        const p = self(ptr);
        const px = p.gpa.alloc(u32, @as(usize, w) * h) catch return;
        for (px, 0..) |*o, i| o.* = premul(.{ .r = rgba[i * 4], .g = rgba[i * 4 + 1], .b = rgba[i * 4 + 2], .a = rgba[i * 4 + 3] });
        if (p.images.fetchRemove(key)) |old| p.gpa.free(old.value.px);
        p.images.put(p.gpa, key, .{ .w = w, .h = h, .px = px }) catch p.gpa.free(px);
    }

    fn drop(ptr: *anyopaque, key: u64) void {
        const p = self(ptr);
        if (p.images.fetchRemove(key)) |old| p.gpa.free(old.value.px);
    }

    fn clip(cv: Canvas, r: Rect) ?struct { x0: u32, y0: u32, x1: u32, y1: u32 } {
        const x0: i64 = @max(0, r.x);
        const y0: i64 = @max(0, r.y);
        const x1: i64 = @min(@as(i64, cv.w), @as(i64, r.x) + r.w);
        const y1: i64 = @min(@as(i64, cv.h), @as(i64, r.y) + r.h);
        if (x0 >= x1 or y0 >= y1) return null;
        return .{ .x0 = @intCast(x0), .y0 = @intCast(y0), .x1 = @intCast(x1), .y1 = @intCast(y1) };
    }

    fn rect(ptr: *anyopaque, r: Rect, color: Color) void {
        const cv = self(ptr).canvas;
        const k = clip(cv, r) orelse return;
        const src = premul(color);
        var y = k.y0;
        while (y < k.y1) : (y += 1) {
            const dst = cv.row(y)[k.x0..k.x1];
            if (color.a == 255) @memset(dst, src) else for (dst) |*d| {
                d.* = over(d.*, src);
            }
        }
    }

    fn glyph(ptr: *anyopaque, src: Rect, dst: Rect, color: Color) void {
        const p = self(ptr);
        const cv = p.canvas;
        const k = clip(cv, dst) orelse return;
        var y = k.y0;
        while (y < k.y1) : (y += 1) {
            const sy: usize = @intCast(@as(i64, src.y) + (@as(i64, y) - dst.y));
            const drow = cv.row(y);
            var x = k.x0;
            while (x < k.x1) : (x += 1) {
                const sx: usize = @intCast(@as(i64, src.x) + (@as(i64, x) - dst.x));
                const cov = p.atlas[sy * render.atlas_size + sx];
                if (cov == 0) continue;
                // the tint's alpha times the coverage, as the GPU's shader does
                var tinted = color;
                tinted.a = mul(color.a, cov);
                drow[x] = over(drow[x], premul(tinted));
            }
        }
    }

    fn quad(ptr: *anyopaque, key: u64, src: Rect, dst: Rect) void {
        const p = self(ptr);
        const img = p.images.get(key) orelse return;
        const cv = p.canvas;
        const k = clip(cv, dst) orelse return;
        if (src.w == 0 or src.h == 0) return;
        var y = k.y0;
        while (y < k.y1) : (y += 1) {
            const j: u64 = @intCast(@as(i64, y) - dst.y);
            const sy: u64 = @as(u64, @intCast(src.y)) + (if (dst.h == src.h) j else j * src.h / dst.h);
            if (sy >= img.h) continue;
            const srow = img.px[@intCast(sy * img.w)..][0..img.w];
            const drow = cv.row(y);
            var x = k.x0;
            while (x < k.x1) : (x += 1) {
                const i: u64 = @intCast(@as(i64, x) - dst.x);
                const sx: u64 = @as(u64, @intCast(src.x)) + (if (dst.w == src.w) i else i * src.w / dst.w);
                if (sx >= img.w) continue;
                drow[x] = over(drow[x], srow[@intCast(sx)]);
            }
        }
    }

    fn present(ptr: *anyopaque) void {
        self(ptr).frames += 1;
    }
};

inline fn mul(a: u8, b: u8) u8 {
    const t: u32 = @as(u32, a) * b + 128;
    return @intCast((t + (t >> 8)) >> 8);
}

pub fn premul(x: Color) u32 {
    return (@as(u32, x.a) << 24) | (@as(u32, mul(x.r, x.a)) << 16) | (@as(u32, mul(x.g, x.a)) << 8) | mul(x.b, x.a);
}

/// `src` over `dst`, both premultiplied.
inline fn over(dst: u32, src: u32) u32 {
    const sa: u8 = @truncate(src >> 24);
    if (sa == 255) return src;
    if (sa == 0) return dst;
    const inv: u8 = 255 - sa;
    var out: u32 = 0;
    inline for (0..4) |i| {
        const sh = i * 8;
        const s: u8 = @truncate(src >> sh);
        const d: u8 = @truncate(dst >> sh);
        out |= @as(u32, s +| mul(d, inv)) << sh;
    }
    return out;
}

test "opaque over translucent is opaque; nothing over is unchanged" {
    const ground = premul(.{ .r = 0x19, .g = 0x17, .b = 0x24, .a = 204 });
    try std.testing.expectEqual(@as(u32, 0xffe0def4), over(ground, premul(.{ .r = 0xe0, .g = 0xde, .b = 0xf4 })));
    try std.testing.expectEqual(ground, over(ground, 0));
    const a: u8 = @truncate(over(ground, premul(.{ .r = 255, .g = 255, .b = 255, .a = 128 })) >> 24);
    try std.testing.expect(a >= 228 and a <= 230);
}
