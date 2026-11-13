//! The renderer's backend on SDL3's renderer: Metal on macOS, Direct3D on
//! Windows, Vulkan or OpenGL on Linux, whichever SDL picks for the window.
//! The atlas is one RGBA texture of white with the coverage as alpha, each
//! picture a texture of its own, everything drawn in device pixels.
//!
//! The target is premultiplied, as a transparent window is composited: the
//! ground is cleared premultiplied, and every draw blends straight source
//! over premultiplied destination (colour SRC_ALPHA, ONE_MINUS_SRC_ALPHA;
//! alpha ONE, ONE_MINUS_SRC_ALPHA), so text and pictures stay whole over a
//! translucent background. A picture of the same size takes new pixels in
//! place: the texture is kept, never made again for each phase.
const std = @import("std");
const c = @import("sdl");
const render = @import("render.zig");
const Rect = render.Rect;
const Color = render.Color;

pub var uploaded: u64 = 0;
pub var uploaded_bytes: u64 = 0;

const Image = struct { tex: *c.SDL_Texture, w: u32, h: u32 };

pub const Gpu = struct {
    gpa: std.mem.Allocator,
    r: *c.SDL_Renderer,
    atlas: *c.SDL_Texture,
    blend: c.SDL_BlendMode,
    images: std.AutoHashMapUnmanaged(u64, Image) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    w: u32 = 0,
    h: u32 = 0,
    /// Read the next frame back before it is presented: the window's own
    /// pixels, alpha and all, as premultiplied 0xAARRGGBB words.
    want_snap: bool = false,
    snap: std.ArrayList(u32) = .empty,

    pub fn init(gpa: std.mem.Allocator, r: *c.SDL_Renderer) !Gpu {
        const blend = c.SDL_ComposeCustomBlendMode(
            c.SDL_BLENDFACTOR_SRC_ALPHA,
            c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            c.SDL_BLENDOPERATION_ADD,
            c.SDL_BLENDFACTOR_ONE,
            c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            c.SDL_BLENDOPERATION_ADD,
        );
        const atlas = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, render.atlas_size, render.atlas_size) orelse return error.Texture;
        errdefer c.SDL_DestroyTexture(atlas);
        _ = c.SDL_SetTextureScaleMode(atlas, c.SDL_SCALEMODE_NEAREST);
        if (!c.SDL_SetTextureBlendMode(atlas, blend)) return error.BlendMode;
        // the atlas begins white and empty
        const n = render.atlas_size * render.atlas_size;
        const blank = try gpa.alloc(u8, n * 4);
        defer gpa.free(blank);
        for (0..n) |i| blank[i * 4 ..][0..4].* = .{ 255, 255, 255, 0 };
        _ = c.SDL_UpdateTexture(atlas, null, blank.ptr, render.atlas_size * 4);
        _ = c.SDL_SetRenderDrawBlendMode(r, blend);
        return .{ .gpa = gpa, .r = r, .atlas = atlas, .blend = blend };
    }

    pub fn deinit(g: *Gpu) void {
        var it = g.images.valueIterator();
        while (it.next()) |i| c.SDL_DestroyTexture(i.tex);
        g.images.deinit(g.gpa);
        c.SDL_DestroyTexture(g.atlas);
        g.scratch.deinit(g.gpa);
        g.snap.deinit(g.gpa);
    }

    pub fn backend(g: *Gpu) render.Backend {
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

    fn self(ptr: *anyopaque) *Gpu {
        return @ptrCast(@alignCast(ptr)); // safe: the backend's own pointer, made by `backend`
    }

    fn begin(ptr: *anyopaque, w: u32, h: u32, ground: Color) void {
        const g = self(ptr);
        g.w = w;
        g.h = h;
        const a = ground.a;
        _ = c.SDL_SetRenderDrawBlendMode(g.r, c.SDL_BLENDMODE_NONE);
        _ = c.SDL_SetRenderDrawColor(g.r, mul(ground.r, a), mul(ground.g, a), mul(ground.b, a), a);
        _ = c.SDL_RenderClear(g.r);
        _ = c.SDL_SetRenderDrawBlendMode(g.r, g.blend);
    }

    fn atlasUpload(ptr: *anyopaque, r: Rect, pixels: []const u8) void {
        const g = self(ptr);
        const n = @as(usize, r.w) * r.h;
        g.scratch.resize(g.gpa, n * 4) catch |err| {
            std.log.warn("glyphs not uploaded: {t}", .{err});
            return;
        };
        for (0..n) |i| g.scratch.items[i * 4 ..][0..4].* = .{ 255, 255, 255, pixels[i] };
        // SDL keeps the draws queued before an update ahead of it
        _ = c.SDL_UpdateTexture(g.atlas, &sdlRect(r), g.scratch.items.ptr, @intCast(r.w * 4));
    }

    fn image(ptr: *anyopaque, key: u64, w: u32, h: u32, rgba: []const u8) void {
        const g = self(ptr);
        uploaded += 1;
        uploaded_bytes += rgba.len;
        if (g.images.getPtr(key)) |held| if (held.w == w and held.h == h) {
            _ = c.SDL_UpdateTexture(held.tex, null, rgba.ptr, @intCast(w * 4));
            return;
        };
        const tex = c.SDL_CreateTexture(g.r, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(w), @intCast(h)) orelse return;
        _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_NEAREST);
        _ = c.SDL_SetTextureBlendMode(tex, g.blend);
        _ = c.SDL_UpdateTexture(tex, null, rgba.ptr, @intCast(w * 4));
        if (g.images.fetchRemove(key)) |old| c.SDL_DestroyTexture(old.value.tex);
        g.images.put(g.gpa, key, .{ .tex = tex, .w = w, .h = h }) catch c.SDL_DestroyTexture(tex);
    }

    fn drop(ptr: *anyopaque, key: u64) void {
        const g = self(ptr);
        if (g.images.fetchRemove(key)) |old| c.SDL_DestroyTexture(old.value.tex);
    }

    fn rect(ptr: *anyopaque, r: Rect, color: Color) void {
        const g = self(ptr);
        _ = c.SDL_SetRenderDrawColor(g.r, color.r, color.g, color.b, color.a);
        _ = c.SDL_RenderFillRect(g.r, &frect(r));
    }

    fn glyph(ptr: *anyopaque, src: Rect, dst: Rect, color: Color) void {
        const g = self(ptr);
        _ = c.SDL_SetTextureColorMod(g.atlas, color.r, color.g, color.b);
        _ = c.SDL_SetTextureAlphaMod(g.atlas, color.a);
        _ = c.SDL_RenderTexture(g.r, g.atlas, &frect(src), &frect(dst));
    }

    fn quad(ptr: *anyopaque, key: u64, src: Rect, dst: Rect) void {
        const g = self(ptr);
        const held = g.images.get(key) orelse return;
        _ = c.SDL_RenderTexture(g.r, held.tex, &frect(src), &frect(dst));
    }

    fn present(ptr: *anyopaque) void {
        const g = self(ptr);
        if (g.want_snap) {
            g.want_snap = false;
            g.read();
        }
        _ = c.SDL_RenderPresent(g.r);
    }

    // The frame as drawn, before it is presented, into `snap`.
    fn read(g: *Gpu) void {
        const surface = c.SDL_RenderReadPixels(g.r, null) orelse return;
        defer c.SDL_DestroySurface(surface);
        const rgba = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_RGBA32) orelse return;
        defer c.SDL_DestroySurface(rgba);
        const w: u32 = @intCast(rgba.*.w);
        const h: u32 = @intCast(rgba.*.h);
        g.snap.resize(g.gpa, @as(usize, w) * h) catch |err| {
            std.log.warn("the frame not kept: {t}", .{err});
            return;
        };
        const pitch: usize = @intCast(rgba.*.pitch);
        const bytes: [*]const u8 = @ptrCast(rgba.*.pixels.?); // safe: the surface's pixels, RGBA32 as converted
        for (0..h) |y| for (0..w) |x| {
            const p = bytes[y * pitch + x * 4 ..][0..4];
            g.snap.items[y * w + x] = (@as(u32, p[3]) << 24) | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
        };
        g.w = w;
        g.h = h;
    }
};

fn sdlRect(r: Rect) c.SDL_Rect {
    return .{ .x = r.x, .y = r.y, .w = @intCast(r.w), .h = @intCast(r.h) };
}

fn frect(r: Rect) c.SDL_FRect {
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
}

inline fn mul(a: u8, b: u8) u8 {
    const t: u32 = @as(u32, a) * b + 128;
    return @intCast((t + (t >> 8)) >> 8);
}
