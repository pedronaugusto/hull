//! The faces hull draws text in, through ztypeset (FreeType underneath):
//! the cell measured from the face, and each glyph rasterised as 8-bit
//! coverage at the device's pixel size. The renderer keeps the glyphs in
//! its atlas; this only rasterises.
const std = @import("std");
const zt = @import("ztypeset");
const fonts = @import("fonts");

pub const Style = enum(u2) { regular, bold, italic, bold_italic };

/// A rasterised glyph, borrowed until the next `raster`: coverage, and
/// where it sits against the cell's left edge and the baseline.
pub const Bitmap = struct {
    w: u32,
    h: u32,
    left: i32,
    top: i32,
    pixels: []const u8,
};

pub const Fonts = struct {
    gpa: std.mem.Allocator,
    lib: zt.Library,
    font: [4]zt.Font,
    face: [4]zt.Face,
    /// The cell, device pixels.
    cell_w: u32,
    cell_h: u32,
    /// The baseline, down from the cell's top.
    baseline: i32,
    underline_pos: i32,
    underline_thick: u32,
    scratch: std.ArrayList(u8) = .empty,

    pub const Bytes = [4][]const u8;

    pub const default_bytes: Bytes = .{ fonts.regular, fonts.bold, fonts.italic, fonts.bold_italic };

    /// The faces at `px` device pixels to the em, `adjust` pixels added to
    /// the cell each way.
    pub fn init(gpa: std.mem.Allocator, bytes: Bytes, px: f32, adjust_w: f32, adjust_h: f32) !Fonts {
        const lib = try zt.Library.init();
        errdefer lib.deinit();
        var f: Fonts = .{ .gpa = gpa, .lib = lib, .font = undefined, .face = undefined, .cell_w = 0, .cell_h = 0, .baseline = 0, .underline_pos = 0, .underline_thick = 1 };
        for (0..4) |i| {
            f.font[i] = try lib.createFont(bytes[i], 0);
            f.face[i] = try f.font[i].face(0, px);
        }
        const m = try f.face[0].metrics();
        const gid = f.font[0].glyphIndex('M');
        const ext = try f.face[0].glyphExtents(gid, .light);
        f.cell_w = @intFromFloat(@max(1, @round(ext.x_advance + adjust_w)));
        const asc = @round(m.ascender);
        const desc = @round(-m.descender);
        const line = @max(@round(m.line_height), asc + desc);
        f.cell_h = @intFromFloat(@max(1, line + @round(adjust_h)));
        // The line's leading shared above and below, as Ghostty does.
        const extra = @as(f32, @floatFromInt(f.cell_h)) - (asc + desc);
        f.baseline = @intFromFloat(asc + @floor(extra / 2));
        f.underline_pos = f.baseline + @as(i32, @intFromFloat(@max(1, @round(-m.underline_position))));
        f.underline_thick = @intFromFloat(@max(1, @round(m.underline_thickness)));
        return f;
    }

    pub fn deinit(f: *Fonts) void {
        f.scratch.deinit(f.gpa);
        for (0..4) |i| {
            f.face[i].deinit();
            f.font[i].deinit();
        }
        f.lib.deinit();
    }

    /// `cp` in `style`, from the regular face when the styled one lacks
    /// it; null when no face has it.
    pub fn raster(f: *Fonts, cp: u21, style: Style) ?Bitmap {
        var i: usize = @intFromEnum(style);
        var gid = f.font[i].glyphIndex(cp);
        if (gid == 0 and i != 0) {
            i = 0;
            gid = f.font[0].glyphIndex(cp);
        }
        if (gid == 0) return null;
        const bm = f.face[i].renderGlyph(gid, .a8, .light, 0, 0) catch return null;
        f.scratch.resize(f.gpa, bm.width * bm.height) catch return null;
        const px = f.scratch.items;
        if (bm.pixels) |src| {
            for (0..bm.height) |y| {
                const row: usize = if (bm.pitch >= 0) y * @as(usize, @intCast(bm.pitch)) else (bm.height - 1 - y) * @as(usize, @intCast(-bm.pitch));
                @memcpy(px[y * bm.width ..][0..bm.width], src[row..][0..bm.width]);
            }
        }
        return .{ .w = bm.width, .h = bm.height, .left = bm.left, .top = bm.top, .pixels = px };
    }
};

test "the cell of JetBrains Mono at 28 px" {
    var f = try Fonts.init(std.testing.allocator, Fonts.default_bytes, 28, 0, 0);
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 17), f.cell_w);
    try std.testing.expect(f.cell_h >= 34 and f.cell_h <= 38);
    const g = f.raster('A', .regular).?;
    try std.testing.expect(g.w > 0 and g.h > 0);
    try std.testing.expect(f.raster(0x10FFFD, .bold) == null);
}
