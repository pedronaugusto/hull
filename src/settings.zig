//! hull's own settings, the window's and the terminal's, and the channel a
//! program changes them over (hull-protocol). hull declares them, applies
//! them live, and keeps what the player chose in the app's own folder; a
//! program's settings page lists them beside its own.
const std = @import("std");
const builtin = @import("builtin");
const hp = @import("hull-protocol");
const config = @import("config.zig");
const input = @import("input.zig");
const theme = @import("theme.zig");
const Session = @import("session.zig").Session;
const version = @import("vt.zig").version;
const log = std.log.scoped(.hull);

/// hull's words for its settings, by name: what a settings page shows when
/// the program has no words of its own for one.
pub const words = struct {
    pub const theme = "Theme";
    pub const background_opacity = "Background opacity";
    pub const font_size = "Text size";
    pub const padding = "Margin";
    pub const fullscreen = "Full screen";
    /// Full screen's two values, off first.
    pub const fullscreen_values = [_]hp.Choice{
        .{ .name = "off", .label = "Windowed" },
        .{ .name = "on", .label = "Full screen" },
    };
    pub const opaque_in_fullscreen = "Full screen is always opaque";
    /// Why a set was refused, by the error hull met.
    pub fn refusal(err: anyerror) []const u8 {
        return switch (err) {
            error.OutOfRange => "That is outside the setting's range",
            error.UnknownSetting => "hull has no setting by that name",
            error.UnknownTheme => "hull has no theme by that name",
            error.NotANumber, error.NotAThemeName, error.NotAToggle => "That is not a value this setting takes",
            else => "hull could not apply that",
        };
    }
    /// Every theme, by its name and Ghostty's words for it: the app's short list first, then the rest.
    pub fn themes(a: std.mem.Allocator, featured: []const []const u8) !struct { []const hp.Choice, u32 } {
        const table = &@import("theme.zig").all;
        var list: std.ArrayList(hp.Choice) = try .initCapacity(a, table.len);
        for (featured) |name| if (@import("theme.zig").byName(name)) |t| if (!has(list.items, t.name)) list.appendAssumeCapacity(.{ .name = t.name, .label = t.label });
        const first: u32 = @intCast(list.items.len); // safe: below the table's few hundred
        for (table) |*t| if (!has(list.items[0..first], t.name)) list.appendAssumeCapacity(.{ .name = t.name, .label = t.label });
        return .{ list.items, first };
    }
    fn has(list: []const hp.Choice, name: []const u8) bool {
        for (list) |c| if (std.mem.eql(u8, c.name, name)) return true;
        return false;
    }
};

/// What the player chose, as kept between runs; a field left out is the
/// app's own default.
pub const Saved = struct {
    theme: ?[]const u8 = null,
    background_opacity: ?u8 = null,
    font_size: ?f32 = null,
    padding: ?u16 = null,
    fullscreen: ?bool = null,
};

pub const Effect = enum { none, redraw, fullscreen };

pub const Settings = struct {
    gpa: std.mem.Allocator,
    /// The app's defaults, from hull.zon.
    defaults: config.Terminal,
    fullscreen_default: bool = false,
    theme: []const u8,
    opacity: u8,
    font_size: f32,
    padding: u16,
    /// What the player asked for, and what the window is: the green button
    /// can change the second without the first.
    fullscreen: bool = false,
    is_fullscreen: bool = false,
    /// Where the player's choices are kept, or null not to keep them.
    path: ?[]const u8 = null,
    lines: hp.Lines = .{},
    scratch: std.ArrayList(u8) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, t: config.Terminal) Settings {
        return .{
            .gpa = gpa,
            .defaults = t,
            .theme = t.theme,
            .opacity = t.background_opacity,
            .font_size = t.font_size,
            .padding = t.padding_x,
            .arena = .init(gpa),
        };
    }

    pub fn deinit(st: *Settings) void {
        st.lines.deinit(st.gpa);
        st.scratch.deinit(st.gpa);
        st.arena.deinit();
    }

    /// The opacity drawn: the setting while windowed, whole in full screen.
    pub fn drawnOpacity(st: *const Settings) u8 {
        return if (st.is_fullscreen) 100 else st.opacity;
    }

    /// The player's choices for app `id`, kept in its folder:
    /// ~/Library/Application Support/<id>/hull-settings.json on macOS,
    /// $XDG_CONFIG_HOME/<id>/ (~/.config) elsewhere.
    pub fn load(st: *Settings, io: std.Io, env: *const std.process.Environ.Map, id: []const u8) void {
        st.read(io, env, id) catch |err| switch (err) {
            error.FileNotFound => {}, // nothing chosen yet
            else => log.warn("{s}: {t}; the app's own settings stand", .{ st.path orelse id, err }),
        };
    }

    fn read(st: *Settings, io: std.Io, env: *const std.process.Environ.Map, id: []const u8) !void {
        const a = st.arena.allocator();
        const home = env.get("HOME") orelse return;
        const dir = if (builtin.os.tag == .macos)
            try std.fs.path.join(a, &.{ home, "Library", "Application Support", id })
        else
            try std.fs.path.join(a, &.{ env.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(a, &.{ home, ".config" }), id });
        st.path = try std.fs.path.join(a, &.{ dir, "hull-settings.json" });
        const bytes = try input.read(io, st.path.?, a, input.settings_limit);
        const saved = try @import("strand").json.parseLeaky(Saved, a, bytes, .{ .ignore_unknown_fields = true });
        if (saved.theme) |v| if (theme.byName(v) != null) {
            st.theme = v;
        };
        if (saved.background_opacity) |v| st.opacity = config.clampOpacity(v);
        if (saved.font_size) |v| st.font_size = std.math.clamp(v, 8, 40);
        if (saved.padding) |v| st.padding = @min(v, 64);
        if (saved.fullscreen) |v| st.fullscreen = v;
    }

    fn save(st: *Settings, io: std.Io) void {
        const path = st.path orelse return;
        st.write(io, path) catch |err| log.warn("{s}: {t}; the choice holds until the app closes", .{ path, err });
    }

    fn write(st: *Settings, io: std.Io, path: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try @import("strand").json.write(&w.interface, Saved{
            .theme = st.theme,
            .background_opacity = st.opacity,
            .font_size = st.font_size,
            .padding = st.padding,
            .fullscreen = st.fullscreen,
        }, .{});
        try w.interface.flush();
    }

    /// Every setting as the protocol states it.
    pub fn describe(st: *Settings, a: std.mem.Allocator) ![]hp.Setting {
        const num = struct {
            fn f(al: std.mem.Allocator, v: f64) hp.Value {
                return .{ .number = al.print("{d}", .{v}) catch "0" };
            }
        }.f;
        const out = try a.alloc(hp.Setting, 5);
        const themes, const featured = try words.themes(a, st.defaults.featured_themes);
        out[0] = .{ .name = "theme", .kind = .choice, .label = words.theme, .values = themes, .featured = featured, .default = .{ .string = st.defaults.theme }, .value = .{ .string = st.theme } };
        out[1] = .{
            .name = "background_opacity",
            .kind = .integer,
            .label = words.background_opacity,
            .min = config.opacity_min,
            .max = config.opacity_max,
            .step = 5,
            .default = num(a, @floatFromInt(st.defaults.background_opacity)),
            .value = num(a, @floatFromInt(st.opacity)),
            .available = !st.is_fullscreen,
            .reason = if (st.is_fullscreen) words.opaque_in_fullscreen else null,
        };
        out[2] = .{ .name = "font_size", .kind = .number, .label = words.font_size, .min = 8, .max = 40, .step = 1, .default = num(a, st.defaults.font_size), .value = num(a, st.font_size) };
        out[3] = .{ .name = "padding", .kind = .integer, .label = words.padding, .min = 0, .max = 64, .step = 4, .default = num(a, @floatFromInt(st.defaults.padding_x)), .value = num(a, @floatFromInt(st.padding)) };
        out[4] = .{ .name = "fullscreen", .kind = .toggle, .label = words.fullscreen, .values = &words.fullscreen_values, .default = .{ .boolean = st.fullscreen_default }, .value = .{ .boolean = st.is_fullscreen } };
        return out;
    }

    fn one(st: *Settings, a: std.mem.Allocator, name: []const u8) !?hp.Setting {
        for (try st.describe(a)) |s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    /// Greets the program with every setting.
    pub fn hello(st: *Settings, s: *Session) void {
        var arena: std.heap.ArenaAllocator = .init(st.gpa);
        defer arena.deinit();
        const all = st.describe(arena.allocator()) catch |err| {
            log.warn("the program not greeted: {t}", .{err});
            return;
        };
        st.send(s, .{ .hello = .{ .hull = version, .app = s.app.id, .settings = all } });
    }

    /// Tells the program one setting changed, whoever changed it.
    pub fn changed(st: *Settings, s: *Session, name: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(st.gpa);
        defer arena.deinit();
        const one_ = (st.one(arena.allocator(), name) catch |err| {
            log.warn("the program not told {s} changed: {t}", .{ name, err });
            return;
        }) orelse return;
        st.send(s, .{ .changed = .{ .setting = one_ } });
    }

    // One message, after those waiting. A line is sent whole or not at all, so the program never reads half of one;
    // a program that has left the channel's bound unread loses the notice whole.
    fn send(st: *Settings, s: *Session, m: hp.Message) void {
        if (!s.spawned or !s.program.talks()) return;
        var line: std.Io.Writer.Allocating = .init(st.gpa);
        defer line.deinit();
        hp.write(&line.writer, m) catch |err| {
            log.warn("a notice to the program lost: {t}", .{err}); // out of memory: the notice, never hull
            return;
        };
        _ = s.program.tell(line.written());
    }

    /// Reads what the program sent and answers it; what the window must do
    /// about it.
    pub fn service(st: *Settings, io: std.Io, s: *Session) Effect {
        if (!s.spawned or !s.program.talks()) return .none;
        var effect: Effect = .none;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = s.program.hear(&buf);
            if (n == 0) break;
            st.lines.feed(st.gpa, buf[0..n]) catch return effect;
        }
        while (st.lines.next(&st.scratch, st.gpa) catch null) |line| {
            var arena: std.heap.ArenaAllocator = .init(st.gpa);
            defer arena.deinit();
            const m = hp.read(arena.allocator(), line) catch {
                st.send(s, .{ .refused = .{ .name = "", .reason = "not a hull-protocol line" } });
                continue;
            };
            switch (m) {
                .get => st.hello(s),
                .set => |req| {
                    const e = st.set(io, s, req.name, req.value) catch |err| {
                        st.send(s, .{ .refused = .{ .name = req.name, .reason = words.refusal(err) } });
                        continue;
                    };
                    if (e != .none) effect = e;
                    st.changed(s, req.name);
                },
                else => {},
            }
        }
        return effect;
    }

    /// One setting to a new value, applied and kept.
    pub fn set(st: *Settings, io: std.Io, s: *Session, name: []const u8, value: hp.Value) !Effect {
        defer st.save(io);
        if (std.mem.eql(u8, name, "theme")) {
            const v = switch (value) {
                .string => |x| x,
                else => return error.NotAThemeName,
            };
            const th = theme.byName(v) orelse return error.UnknownTheme;
            st.theme = th.name;
            s.setTheme(th.*);
            return .redraw;
        }
        if (std.mem.eql(u8, name, "background_opacity")) {
            const v = hp.asNumber(value) orelse return error.NotANumber;
            if (v < config.opacity_min or v > config.opacity_max) return error.OutOfRange;
            // kept while unavailable, for when the window is windowed again
            st.opacity = config.clampOpacity(@intFromFloat(@round(v)));
            s.vt.opacity = st.drawnOpacity();
            return .redraw;
        }
        if (std.mem.eql(u8, name, "font_size")) {
            const v = hp.asNumber(value) orelse return error.NotANumber;
            if (v < 8 or v > 40) return error.OutOfRange;
            st.font_size = @floatCast(v);
            try s.setFontSize(st.font_size);
            return .redraw;
        }
        if (std.mem.eql(u8, name, "padding")) {
            const v = hp.asNumber(value) orelse return error.NotANumber;
            if (v < 0 or v > 64) return error.OutOfRange;
            st.padding = @intFromFloat(@round(v));
            s.setPadding(st.padding);
            return .redraw;
        }
        if (std.mem.eql(u8, name, "fullscreen")) {
            st.fullscreen = switch (value) {
                .boolean => |b| b,
                else => return error.NotAToggle,
            };
            return .fullscreen;
        }
        return error.UnknownSetting;
    }

    /// The window went into or out of full screen, by hull or by the
    /// player: opacity's availability follows, and the program hears.
    pub fn windowFullscreen(st: *Settings, s: *Session, on: bool) void {
        if (st.is_fullscreen == on) return;
        st.is_fullscreen = on;
        s.vt.opacity = st.drawnOpacity();
        st.changed(s, "fullscreen");
        st.changed(s, "background_opacity");
    }

    /// Applies what was loaded to a session not yet drawn.
    pub fn applyLoaded(st: *Settings, s: *Session) !void {
        if (!std.mem.eql(u8, st.theme, st.defaults.theme)) if (theme.byName(st.theme)) |th| s.setTheme(th.*);
        s.vt.opacity = st.drawnOpacity();
        if (st.font_size != s.app.terminal.font_size) try s.setFontSize(st.font_size);
        if (st.padding != s.app.terminal.padding_x) s.setPadding(st.padding);
    }
};
