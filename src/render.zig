//! hull's renderer: the terminal's state as a list of draws against a
//! narrow backend (an 8-bit glyph atlas, RGBA images, rectangles, quads
//! and present), so the window's GPU backend and the headless CPU one draw
//! the same frame from the same calls.
//!
//! Order, as kitty's layers say: the background (at hull's opacity), the
//! pictures below cell backgrounds, the cells' own backgrounds, the
//! pictures below text, the text and its lines, the cursor, the pictures
//! above text. A picture is drawn pixel for pixel when its placement is
//! its own size, as a program that sizes them to whole cells has them, and by nearest
//! neighbour otherwise: never a filter that blurs a dither.
const std = @import("std");
const vt_mod = @import("vt.zig");
const c = vt_mod.c;
const Vt = vt_mod.Vt;
const font = @import("font.zig");

/// Straight (not premultiplied) RGBA.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    fn of(x: c.GhosttyColorRgb) Color {
        return .{ .r = x.r, .g = x.g, .b = x.b };
    }
};

/// Device pixels, top-left origin.
pub const Rect = struct { x: i32, y: i32, w: u32, h: u32 };

/// What a backend draws with. Every coordinate is a device pixel; a
/// backend blends premultiplied-over into a premultiplied target, so a
/// translucent background stays translucent under opaque text.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// A frame of `w`×`h` device pixels, cleared to `ground`.
        begin: *const fn (*anyopaque, w: u32, h: u32, ground: Color) void,
        /// Coverage pixels into the atlas at `r` (row-major, `r.w` wide).
        atlas: *const fn (*anyopaque, r: Rect, pixels: []const u8) void,
        /// RGBA pixels, straight alpha, as the image `key`: new, or new
        /// pixels for it (the same size reuses what holds the old ones).
        image: *const fn (*anyopaque, key: u64, w: u32, h: u32, rgba: []const u8) void,
        /// The image `key` is no longer needed.
        drop: *const fn (*anyopaque, key: u64) void,
        rect: *const fn (*anyopaque, r: Rect, color: Color) void,
        /// The atlas's coverage at `src`, tinted `color`, at `dst` (same size).
        glyph: *const fn (*anyopaque, src: Rect, dst: Rect, color: Color) void,
        /// The image's `src` at `dst`, nearest neighbour when they differ.
        quad: *const fn (*anyopaque, key: u64, src: Rect, dst: Rect) void,
        present: *const fn (*anyopaque) void,
    };
};

pub const atlas_size = 2048;

/// Where the grid sits, device pixels.
pub const Layout = struct {
    pad_x: u32,
    pad_y: u32,
    cell_w: u32,
    cell_h: u32,
    /// The device's pixels per point, for lines that scale with it.
    scale: f32 = 1,
};

pub const Stats = struct {
    images: u32 = 0,
    image_pixels: u64 = 0,
    uploads: u32 = 0,
    upload_bytes: u64 = 0,
    rects: u32 = 0,
    glyphs: u32 = 0,
};

/// What one frame's passes share: the terminal, the faces, where the grid sits, and its colours and cursor.
const Pass = struct {
    v: *Vt,
    f: *font.Fonts,
    lay: Layout,
    colors: c.GhosttyRenderStateColors,
    cursor: c.GhosttyRenderStateCursor,
    /// The cursor is a block, drawn as the cell's own colours swapped.
    block: bool,
    cursor_color: Color,
};

const Slot = struct { x: u16, y: u16, w: u16, h: u16, left: i16, top: i16, missing: bool = false };
const Image = struct { seen: u64, generation: u64 };

/// The frame's walker and what it keeps between frames: the atlas's
/// packing and glyphs, and which images the backend holds.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    backend: Backend,
    glyphs: std.AutoHashMapUnmanaged(u64, Slot) = .empty,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    images: std.AutoHashMapUnmanaged(u64, Image) = .empty,
    frame: u64 = 0,
    /// The faces the atlas holds glyphs of (`Session.font_epoch`).
    epoch: u32 = 0,
    rgba: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, backend: Backend) Renderer {
        return .{ .gpa = gpa, .backend = backend };
    }

    pub fn deinit(r: *Renderer) void {
        r.glyphs.deinit(r.gpa);
        r.images.deinit(r.gpa);
        r.rgba.deinit(r.gpa);
    }

    /// Draws the terminal's state, then presents.
    /// The faces changed: every glyph is rasterised again.
    pub fn resetGlyphs(r: *Renderer) void {
        r.glyphs.clearRetainingCapacity();
        r.shelf_x = 0;
        r.shelf_y = 0;
        r.shelf_h = 0;
    }

    pub fn draw(r: *Renderer, v: *Vt, f: *font.Fonts, w: u32, h: u32, lay: Layout) Stats {
        r.frame += 1;
        var stats: Stats = .{};
        const b = r.backend;
        _ = c.ghostty_render_state_update(v.render, v.term);
        var colors = std.mem.zeroes(c.GhosttyRenderStateColors);
        colors.size = @sizeOf(c.GhosttyRenderStateColors);
        _ = c.ghostty_render_state_get(v.render, c.GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);

        // The window's background: the only thing opacity touches.
        const bg = colors.background;
        var ground = Color.of(bg);
        ground.a = @intCast((@as(u32, v.opacity) * 255 + 50) / 100);
        b.vtable.begin(b.ptr, w, h, ground);

        var kitty: c.GhosttyKittyGraphics = null;
        const has_kitty = c.ghostty_terminal_get(v.term, c.GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, @ptrCast(&kitty)) == c.GHOSTTY_SUCCESS and kitty != null; // safe: libghostty's out-parameter or option, of the type its header names
        if (has_kitty) r.pictures(v, kitty, lay, c.GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG, &stats);

        var cursor = std.mem.zeroes(c.GhosttyRenderStateCursor);
        cursor.size = @sizeOf(c.GhosttyRenderStateCursor);
        _ = c.ghostty_render_state_get(v.render, c.GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
        const cursor_on = cursor.visible and cursor.viewport_has_value;
        const block = cursor_on and cursor.visual_style == c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
        const cursor_color = Color.of(if (colors.cursor_has_value) colors.cursor else colors.foreground);

        const pass: Pass = .{ .v = v, .f = f, .lay = lay, .colors = colors, .cursor = cursor, .block = block, .cursor_color = cursor_color };
        r.backgrounds(pass, &stats);

        if (has_kitty) r.pictures(v, kitty, lay, c.GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT, &stats);

        r.text(pass, &stats);

        if (cursor_on and !block) r.cursorShape(pass, &stats);

        if (has_kitty) r.pictures(v, kitty, lay, c.GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT, &stats);

        var clean_state: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = c.ghostty_render_state_set(v.render, c.GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean_state);

        r.forget();
        b.vtable.present(b.ptr);
        return stats;
    }

    // Cell backgrounds, a run of one colour as one rectangle. A cell the program set to the background colour
    // itself is the background, and as translucent.
    fn backgrounds(r: *Renderer, p: Pass, stats: *Stats) void {
        const v = p.v;
        const lay = p.lay;
        const colors = p.colors;
        const bg = colors.background;
        const cursor = p.cursor;
        var it = v.rows_it;
        _ = c.ghostty_render_state_get(v.render, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&it)); // safe: libghostty's out-parameter or option, of the type its header names
        var row: u16 = 0;
        while (c.ghostty_render_state_row_iterator_next(it)) : (row += 1) {
            var cells = v.cells;
            if (c.ghostty_render_state_row_get(it, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&cells)) != c.GHOSTTY_SUCCESS) continue; // safe: libghostty's out-parameter or option, of the type its header names
            const y: i32 = @intCast(lay.pad_y + @as(u32, row) * lay.cell_h);
            var run_start: u16 = 0;
            var run_color: ?Color = null;
            var col: u16 = 0;
            while (c.ghostty_render_state_row_cells_next(cells)) : (col += 1) {
                const style = cellStyle(cells);
                var cbg: c.GhosttyColorRgb = bg;
                var has_bg = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &cbg) == c.GHOSTTY_SUCCESS;
                if (style.inverse) {
                    cbg = colors.foreground;
                    _ = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &cbg);
                    has_bg = true;
                }
                var this: ?Color = if (has_bg and !(cbg.r == bg.r and cbg.g == bg.g and cbg.b == bg.b)) Color.of(cbg) else null;
                if (p.block and cursor.viewport_x == col and cursor.viewport_y == row) this = p.cursor_color;
                if (!std.meta.eql(this, run_color)) {
                    if (run_color) |rc| r.rectCells(lay, run_start, col, y, rc, stats);
                    run_color = this;
                    run_start = col;
                }
            }
            if (run_color) |rc| r.rectCells(lay, run_start, col, y, rc, stats);
        }
    }

    // The text and its lines, and each row marked drawn.
    fn text(r: *Renderer, p: Pass, stats: *Stats) void {
        const v = p.v;
        const f = p.f;
        const lay = p.lay;
        const colors = p.colors;
        const bg = colors.background;
        const cursor = p.cursor;
        var it = v.rows_it;
        _ = c.ghostty_render_state_get(v.render, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&it)); // safe: libghostty's out-parameter or option, of the type its header names
        var row: u16 = 0;
        while (c.ghostty_render_state_row_iterator_next(it)) : (row += 1) {
            var cells = v.cells;
            if (c.ghostty_render_state_row_get(it, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&cells)) != c.GHOSTTY_SUCCESS) continue; // safe: libghostty's out-parameter or option, of the type its header names
            const y: i32 = @intCast(lay.pad_y + @as(u32, row) * lay.cell_h);
            var col: u16 = 0;
            while (c.ghostty_render_state_row_cells_next(cells)) : (col += 1) {
                var n: u32 = 0;
                _ = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &n);
                const style = cellStyle(cells);
                if (n == 0 and style.underline == 0 and !style.strikethrough and !style.overline) continue;
                if (style.invisible) continue;
                var fg = colors.foreground;
                _ = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
                if (style.inverse) {
                    fg = bg;
                    _ = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &fg);
                }
                if (p.block and cursor.viewport_x == col and cursor.viewport_y == row) fg = bg;
                var color = Color.of(fg);
                if (style.faint) color.a = 128;
                const x: i32 = @intCast(lay.pad_x + @as(u32, col) * lay.cell_w);
                if (n > 0) {
                    var cps: [16]u32 = undefined;
                    _ = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &cps);
                    const cp: u21 = @intCast(@min(cps[0], 0x10FFFF));
                    const st: font.Style = if (style.bold and style.italic) .bold_italic else if (style.bold) .bold else if (style.italic) .italic else .regular;
                    if (!r.special(cp, x, y, lay, color, stats)) r.glyph(f, cp, st, x, y + f.baseline, color, stats);
                }
                const t = f.underline_thick;
                if (style.underline != 0) r.rect(.{ .x = x, .y = y + f.underline_pos, .w = lay.cell_w, .h = t }, color, stats);
                if (style.strikethrough) r.rect(.{ .x = x, .y = y + @divTrunc(f.baseline * 2, 3), .w = lay.cell_w, .h = t }, color, stats);
                if (style.overline) r.rect(.{ .x = x, .y = y, .w = lay.cell_w, .h = t }, color, stats);
            }
            var clean = false;
            _ = c.ghostty_render_state_row_set(it, c.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean);
        }
    }

    // A cursor that is not a block: a bar, an underline or a hollow box.
    fn cursorShape(r: *Renderer, p: Pass, stats: *Stats) void {
        const lay = p.lay;
        const cursor = p.cursor;
        const cursor_color = p.cursor_color;
        const cx: i32 = @intCast(lay.pad_x + @as(u32, cursor.viewport_x) * lay.cell_w);
        const cy: i32 = @intCast(lay.pad_y + @as(u32, cursor.viewport_y) * lay.cell_h);
        const t: u32 = @intFromFloat(@max(1, @round(lay.scale * 1.5)));
        const ti: i32 = @intCast(t);
        const cw: i32 = @intCast(lay.cell_w);
        const ch: i32 = @intCast(lay.cell_h);
        switch (cursor.visual_style) {
            c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => r.rect(.{ .x = cx, .y = cy, .w = t, .h = lay.cell_h }, cursor_color, stats),
            c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => r.rect(.{ .x = cx, .y = cy + ch - ti, .w = lay.cell_w, .h = t }, cursor_color, stats),
            else => {
                r.rect(.{ .x = cx, .y = cy, .w = lay.cell_w, .h = t }, cursor_color, stats);
                r.rect(.{ .x = cx, .y = cy + ch - ti, .w = lay.cell_w, .h = t }, cursor_color, stats);
                r.rect(.{ .x = cx, .y = cy, .w = t, .h = lay.cell_h }, cursor_color, stats);
                r.rect(.{ .x = cx + cw - ti, .y = cy, .w = t, .h = lay.cell_h }, cursor_color, stats);
            },
        }
    }

    // Images not drawn for a while are let go.
    fn forget(r: *Renderer) void {
        var drop: [16]u64 = undefined;
        var nd: usize = 0;
        var ii = r.images.iterator();
        while (ii.next()) |e| if (e.value_ptr.seen + 2 < r.frame and nd < drop.len) {
            drop[nd] = e.key_ptr.*;
            nd += 1;
        };
        for (drop[0..nd]) |k| {
            _ = r.images.remove(k);
            r.backend.vtable.drop(r.backend.ptr, k);
        }
    }

    fn rect(r: *Renderer, rc: Rect, color: Color, stats: *Stats) void {
        if (rc.w == 0 or rc.h == 0) return;
        r.backend.vtable.rect(r.backend.ptr, rc, color);
        stats.rects += 1;
    }

    fn rectCells(r: *Renderer, lay: Layout, from: u16, to: u16, y: i32, color: Color, stats: *Stats) void {
        r.rect(.{ .x = @intCast(lay.pad_x + @as(u32, from) * lay.cell_w), .y = y, .w = @as(u32, to - from) * lay.cell_w, .h = lay.cell_h }, color, stats);
    }

    fn glyph(r: *Renderer, f: *font.Fonts, cp: u21, st: font.Style, x: i32, baseline: i32, color: Color, stats: *Stats) void {
        const s = r.slot(f, cp, st, stats) orelse return;
        if (s.missing or s.w == 0) return;
        const src: Rect = .{ .x = s.x, .y = s.y, .w = s.w, .h = s.h };
        const dst: Rect = .{ .x = x + s.left, .y = baseline - s.top, .w = s.w, .h = s.h };
        r.backend.vtable.glyph(r.backend.ptr, src, dst, color);
        stats.glyphs += 1;
    }

    /// The glyph's place in the atlas, rasterised and uploaded the first
    /// time; a full atlas starts over.
    fn slot(r: *Renderer, f: *font.Fonts, cp: u21, st: font.Style, stats: *Stats) ?Slot {
        const key = (@as(u64, @backingInt(st)) << 32) | cp;
        if (r.glyphs.get(key)) |s| return s;
        const bm = f.raster(cp, st) orelse {
            // a missing glyph not remembered is only looked for again
            r.glyphs.put(r.gpa, key, .{ .x = 0, .y = 0, .w = 0, .h = 0, .left = 0, .top = 0, .missing = true }) catch return null;
            return null;
        };
        if (bm.w + 1 > atlas_size or bm.h + 1 > atlas_size) return null;
        if (r.shelf_x + bm.w + 1 > atlas_size) {
            r.shelf_x = 0;
            r.shelf_y += r.shelf_h + 1;
            r.shelf_h = 0;
        }
        if (r.shelf_y + bm.h + 1 > atlas_size) {
            r.glyphs.clearRetainingCapacity();
            r.shelf_x = 0;
            r.shelf_y = 0;
            r.shelf_h = 0;
        }
        const s: Slot = .{ .x = @intCast(r.shelf_x), .y = @intCast(r.shelf_y), .w = @intCast(bm.w), .h = @intCast(bm.h), .left = @intCast(bm.left), .top = @intCast(bm.top) };
        if (bm.w > 0 and bm.h > 0) {
            r.backend.vtable.atlas(r.backend.ptr, .{ .x = s.x, .y = s.y, .w = bm.w, .h = bm.h }, bm.pixels);
            stats.uploads += 1;
            stats.upload_bytes += bm.pixels.len;
        }
        r.shelf_x += bm.w + 1;
        r.shelf_h = @max(r.shelf_h, bm.h);
        r.glyphs.put(r.gpa, key, s) catch return null;
        return s;
    }

    /// Block elements and sextants, drawn to fill the cell exactly as a
    /// font cannot promise: what a program's picture falls back to is whole.
    fn special(r: *Renderer, cp: u21, x: i32, y: i32, lay: Layout, color: Color, stats: *Stats) bool {
        const w: i32 = @intCast(lay.cell_w);
        const h: i32 = @intCast(lay.cell_h);
        switch (cp) {
            0x2588 => r.rect(span(x, y, x + w, y + h), color, stats), // █
            0x2580 => r.rect(span(x, y, x + w, y + @divTrunc(h, 2)), color, stats), // ▀
            0x2590 => r.rect(span(x + @divTrunc(w, 2), y, x + w, y + h), color, stats), // ▐
            0x2581...0x2587 => {
                const eighths: i32 = cp - 0x2580;
                r.rect(span(x, y + h - @divTrunc(h * eighths, 8), x + w, y + h), color, stats);
            },
            0x2589...0x258F => {
                const eighths: i32 = 8 - @as(i32, cp - 0x2588);
                r.rect(span(x, y, x + @divTrunc(w * eighths, 8), y + h), color, stats);
            },
            0x2596...0x259F => {
                // quadrants: bits tl, tr, bl, br
                const q = [_]u4{ 0b0100, 0b1000, 0b0001, 0b1101, 0b1001, 0b0111, 0b1011, 0b0010, 0b0110, 0b1110 };
                const bits = q[cp - 0x2596];
                const xs = [_]i32{ x, x + @divTrunc(w, 2), x + w };
                const ys = [_]i32{ y, y + @divTrunc(h, 2), y + h };
                for (0..4) |i| if (bits & (@as(u4, 1) << @intCast(i)) != 0)
                    r.rect(span(xs[i % 2], ys[i / 2], xs[i % 2 + 1], ys[i / 2 + 1]), color, stats);
            },
            0x1FB00...0x1FB3B => {
                var bits: u32 = cp - 0x1FB00 + 1;
                if (bits >= 21) bits += 1;
                if (bits >= 42) bits += 1;
                const xs = [_]i32{ x, x + @divTrunc(w, 2), x + w };
                const ys = [_]i32{ y, y + @divTrunc(h, 3), y + @divTrunc(h * 2, 3), y + h };
                for (0..6) |i| if (bits & (@as(u32, 1) << @intCast(i)) != 0)
                    r.rect(span(xs[i % 2], ys[i / 2], xs[i % 2 + 1], ys[i / 2 + 1]), color, stats);
            },
            else => return false,
        }
        return true;
    }

    fn pictures(r: *Renderer, v: *Vt, kitty: c.GhosttyKittyGraphics, lay: Layout, layer: c.GhosttyKittyPlacementLayer, stats: *Stats) void {
        var l = layer;
        _ = c.ghostty_kitty_graphics_placement_iterator_set(v.placements, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_LAYER, &l);
        var it = v.placements;
        if (c.ghostty_kitty_graphics_get(kitty, c.GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, @ptrCast(&it)) != c.GHOSTTY_SUCCESS) return; // safe: libghostty's out-parameter or option, of the type its header names
        while (c.ghostty_kitty_graphics_placement_next(it)) {
            var id: u32 = 0;
            _ = c.ghostty_kitty_graphics_placement_get(it, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &id);
            const img = c.ghostty_kitty_graphics_image(kitty, id);
            if (img == null) continue;
            var info = std.mem.zeroes(c.GhosttyKittyGraphicsPlacementRenderInfo);
            info.size = @sizeOf(c.GhosttyKittyGraphicsPlacementRenderInfo);
            if (c.ghostty_kitty_graphics_placement_render_info(it, img, v.term, &info) != c.GHOSTTY_SUCCESS) continue;
            if (!info.viewport_visible or info.pixel_width == 0 or info.pixel_height == 0) continue;
            // The image's generation names its content: a new one, new pixels
            // for the same image.
            var gen: u64 = 0;
            _ = c.ghostty_kitty_graphics_image_get(img, c.GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &gen);
            const key: u64 = id;
            if (r.images.getPtr(key)) |e| {
                e.seen = r.frame;
                if (e.generation != gen) {
                    if (!r.upload(img, key, gen, stats)) continue;
                }
            } else if (!r.upload(img, key, gen, stats)) continue;
            var xo: u32 = 0;
            var yo: u32 = 0;
            _ = c.ghostty_kitty_graphics_placement_get(it, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &xo);
            _ = c.ghostty_kitty_graphics_placement_get(it, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &yo);
            const dx: i64 = @as(i64, lay.pad_x) + @as(i64, info.viewport_col) * lay.cell_w + xo;
            const dy: i64 = @as(i64, lay.pad_y) + @as(i64, info.viewport_row) * lay.cell_h + yo;
            const src: Rect = .{ .x = @intCast(info.source_x), .y = @intCast(info.source_y), .w = info.source_width, .h = info.source_height };
            const dst: Rect = .{ .x = @intCast(dx), .y = @intCast(dy), .w = info.pixel_width, .h = info.pixel_height };
            r.backend.vtable.quad(r.backend.ptr, key, src, dst);
            stats.images += 1;
            stats.image_pixels += @as(u64, info.pixel_width) * info.pixel_height;
        }
    }

    fn upload(r: *Renderer, img: c.GhosttyKittyGraphicsImage, key: u64, generation: u64, stats: *Stats) bool {
        var iw: u32 = 0;
        var ih: u32 = 0;
        var fmt: c.GhosttyKittyImageFormat = c.GHOSTTY_KITTY_IMAGE_FORMAT_RGBA;
        var data: [*c]const u8 = null;
        var len: usize = 0;
        _ = c.ghostty_kitty_graphics_image_get(img, c.GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &iw);
        _ = c.ghostty_kitty_graphics_image_get(img, c.GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &ih);
        _ = c.ghostty_kitty_graphics_image_get(img, c.GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &fmt);
        _ = c.ghostty_kitty_graphics_image_get(img, c.GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, @ptrCast(&data)); // safe: libghostty's out-parameter or option, of the type its header names
        _ = c.ghostty_kitty_graphics_image_get(img, c.GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &len);
        const bpp: usize = switch (fmt) {
            c.GHOSTTY_KITTY_IMAGE_FORMAT_RGBA => 4,
            c.GHOSTTY_KITTY_IMAGE_FORMAT_RGB => 3,
            c.GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA => 2,
            c.GHOSTTY_KITTY_IMAGE_FORMAT_GRAY => 1,
            else => return false,
        };
        const n = @as(usize, iw) * ih;
        if (data == null or len < n * bpp or n == 0) return false;
        const src = data[0 .. n * bpp];
        const rgba: []const u8 = if (bpp == 4) src else blk: {
            r.rgba.resize(r.gpa, n * 4) catch return false;
            const out = r.rgba.items;
            for (0..n) |i| {
                const s = src[i * bpp ..];
                const px: [4]u8 = switch (bpp) {
                    3 => .{ s[0], s[1], s[2], 255 },
                    2 => .{ s[0], s[0], s[0], s[1] },
                    else => .{ s[0], s[0], s[0], 255 },
                };
                @memcpy(out[i * 4 ..][0..4], &px);
            }
            break :blk out;
        };
        r.backend.vtable.image(r.backend.ptr, key, iw, ih, rgba);
        r.images.put(r.gpa, key, .{ .seen = r.frame, .generation = generation }) catch return false;
        stats.uploads += 1;
        stats.upload_bytes += rgba.len;
        return true;
    }
};

fn span(x0: i32, y0: i32, x1: i32, y1: i32) Rect {
    return .{ .x = x0, .y = y0, .w = @intCast(@max(0, x1 - x0)), .h = @intCast(@max(0, y1 - y0)) };
}

fn cellStyle(cells: c.GhosttyRenderStateRowCells) c.GhosttyStyle {
    var style = std.mem.zeroes(c.GhosttyStyle);
    style.size = @sizeOf(c.GhosttyStyle);
    _ = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
    return style;
}
