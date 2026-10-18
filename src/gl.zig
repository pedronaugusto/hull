//! The renderer's backend on the GPU, through raylib (OpenGL 3.3 on
//! GLFW): the atlas as one gray-alpha texture, each picture a texture,
//! everything a textured or solid quad in raylib's batch, in device pixels.
//!
//! The framebuffer is premultiplied, as macOS composites a transparent
//! window: the ground is cleared premultiplied, and every quad is blended
//! straight-source over premultiplied-destination (colour SRC_ALPHA,
//! ONE_MINUS_SRC_ALPHA; alpha ONE, ONE_MINUS_SRC_ALPHA), which keeps text
//! and pictures whole over a translucent background.
const std = @import("std");
const rl = @import("rl");
const render = @import("render.zig");
const Rect = render.Rect;
const Color = render.Color;

extern "c" fn glReadPixels(x: c_int, y: c_int, w: c_int, h: c_int, format: c_uint, kind: c_uint, data: *anyopaque) void;
pub var uploaded: u64 = 0;
pub var uploaded_bytes: u64 = 0;

pub const Gl = struct {
    gpa: std.mem.Allocator,
    atlas: rl.Texture2D,
    images: std.AutoHashMapUnmanaged(u64, rl.Texture2D) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    w: u32 = 0,
    h: u32 = 0,
    /// Read the next frame back before it is presented: the window's
    /// own pixels, alpha and all, as premultiplied 0xAARRGGBB words.
    want_snap: bool = false,
    snap: std.ArrayList(u32) = .empty,

    /// After the window exists: the context is current.
    pub fn init(gpa: std.mem.Allocator) !Gl {
        const n = render.atlas_size * render.atlas_size * 2;
        const blank = try gpa.alloc(u8, n);
        defer gpa.free(blank);
        for (0..n / 2) |i| {
            blank[i * 2] = 255;
            blank[i * 2 + 1] = 0;
        }
        const img: rl.Image = .{ .data = blank.ptr, .width = render.atlas_size, .height = render.atlas_size, .mipmaps = 1, .format = rl.PIXELFORMAT_UNCOMPRESSED_GRAY_ALPHA };
        const tex = rl.LoadTextureFromImage(img);
        if (tex.id == 0) return error.Texture;
        rl.SetTextureFilter(tex, rl.TEXTURE_FILTER_POINT);
        return .{ .gpa = gpa, .atlas = tex };
    }

    pub fn deinit(g: *Gl) void {
        var it = g.images.valueIterator();
        while (it.next()) |t| rl.UnloadTexture(t.*);
        g.images.deinit(g.gpa);
        rl.UnloadTexture(g.atlas);
        g.scratch.deinit(g.gpa);
        g.snap.deinit(g.gpa);
    }

    pub fn backend(g: *Gl) render.Backend {
        return .{ .ptr = g, .vtable = &vtable };
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

    fn self(ptr: *anyopaque) *Gl {
        return @ptrCast(@alignCast(ptr));
    }

    fn begin(ptr: *anyopaque, w: u32, h: u32, ground: Color) void {
        const g = self(ptr);
        g.w = w;
        g.h = h;
        rl.BeginDrawing();
        // Device pixels, top-left origin, whatever raylib's HiDPI scaling
        // would have made of points.
        rl.rlDrawRenderBatchActive();
        rl.rlViewport(0, 0, @intCast(w), @intCast(h));
        rl.rlMatrixMode(rl.RL_PROJECTION);
        rl.rlLoadIdentity();
        rl.rlOrtho(0, @floatFromInt(w), @floatFromInt(h), 0, 0, 1);
        rl.rlMatrixMode(rl.RL_MODELVIEW);
        rl.rlLoadIdentity();
        const a = ground.a;
        rl.ClearBackground(.{ .r = mul(ground.r, a), .g = mul(ground.g, a), .b = mul(ground.b, a), .a = a });
        rl.rlSetBlendFactorsSeparate(rl.RL_SRC_ALPHA, rl.RL_ONE_MINUS_SRC_ALPHA, rl.RL_ONE, rl.RL_ONE_MINUS_SRC_ALPHA, rl.RL_FUNC_ADD, rl.RL_FUNC_ADD);
        rl.BeginBlendMode(rl.BLEND_CUSTOM_SEPARATE);
    }

    fn atlasUpload(ptr: *anyopaque, r: Rect, pixels: []const u8) void {
        const g = self(ptr);
        const n = @as(usize, r.w) * r.h;
        g.scratch.resize(g.gpa, n * 2) catch return;
        for (0..n) |i| {
            g.scratch.items[i * 2] = 255;
            g.scratch.items[i * 2 + 1] = pixels[i];
        }
        // An upload mid-frame must land after the quads already batched
        // that sample the old atlas, and before the new ones.
        rl.rlDrawRenderBatchActive();
        rl.UpdateTextureRec(g.atlas, rec(r), g.scratch.items.ptr);
    }

    fn image(ptr: *anyopaque, key: u64, w: u32, h: u32, rgba: []const u8) void {
        const g = self(ptr);
        rl.rlDrawRenderBatchActive();
        // Always a new texture: updating one in place (glTexSubImage2D) under
        // WAKE's shimmer grew the macOS OpenGL driver's memory without bound
        // in the spike, where new textures level off.
        const img: rl.Image = .{ .data = @constCast(rgba.ptr), .width = @intCast(w), .height = @intCast(h), .mipmaps = 1, .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8 };
        const tex = rl.LoadTextureFromImage(img);
        if (tex.id == 0) return;
        uploaded += 1;
        uploaded_bytes += rgba.len;
        rl.SetTextureFilter(tex, rl.TEXTURE_FILTER_POINT);
        rl.SetTextureWrap(tex, rl.TEXTURE_WRAP_CLAMP);
        if (g.images.fetchRemove(key)) |old| g.release(old.value);
        g.images.put(g.gpa, key, tex) catch rl.UnloadTexture(tex);
    }

    fn release(_: *Gl, t: rl.Texture2D) void {
        rl.UnloadTexture(t);
    }

    fn drop(ptr: *anyopaque, key: u64) void {
        const g = self(ptr);
        rl.rlDrawRenderBatchActive();
        if (g.images.fetchRemove(key)) |old| g.release(old.value);
    }

    fn rect(_: *anyopaque, r: Rect, color: Color) void {
        rl.DrawRectangle(r.x, r.y, @intCast(r.w), @intCast(r.h), col(color));
    }

    fn glyph(ptr: *anyopaque, src: Rect, dst: Rect, color: Color) void {
        rl.DrawTexturePro(self(ptr).atlas, rec(src), rec(dst), .{ .x = 0, .y = 0 }, 0, col(color));
    }

    fn quad(ptr: *anyopaque, key: u64, src: Rect, dst: Rect) void {
        const tex = self(ptr).images.get(key) orelse return;
        rl.DrawTexturePro(tex, rec(src), rec(dst), .{ .x = 0, .y = 0 }, 0, rl.WHITE);
    }

    fn present(ptr: *anyopaque) void {
        const g = self(ptr);
        if (g.want_snap) {
            g.want_snap = false;
            rl.rlDrawRenderBatchActive();
            const n = @as(usize, g.w) * g.h;
            if (g.scratch.resize(g.gpa, n * 4)) |_| {
                glReadPixels(0, 0, @intCast(g.w), @intCast(g.h), 0x1908, 0x1401, g.scratch.items.ptr); // GL_RGBA, GL_UNSIGNED_BYTE
                g.snap.resize(g.gpa, n) catch {};
                if (g.snap.items.len == n) for (0..g.h) |y| for (0..g.w) |x| {
                    // OpenGL's rows run bottom up
                    const p = g.scratch.items[((g.h - 1 - y) * g.w + x) * 4 ..][0..4];
                    g.snap.items[y * g.w + x] = (@as(u32, p[3]) << 24) | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
                };
            } else |_| {}
        }
        rl.EndBlendMode();
        rl.EndDrawing();
    }
};

fn rec(r: Rect) rl.Rectangle {
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .width = @floatFromInt(r.w), .height = @floatFromInt(r.h) };
}

fn col(c: Color) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

inline fn mul(a: u8, b: u8) u8 {
    const t: u32 = @as(u32, a) * b + 128;
    return @intCast((t + (t >> 8)) >> 8);
}
