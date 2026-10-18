//! SDL3's keys as libghostty's: the physical key by its scancode (USB's
//! usage ids, named by their US position, which is what the kitty
//! protocol's codes are), and SDL's modifier bits as libghostty's.
const std = @import("std");
const c = @import("../vt.zig").c;

/// The key at `scancode`, or unidentified.
pub fn key(scancode: u32) c.GhosttyKey {
    const sc: c_int = @intCast(@min(scancode, 512)); // safe: held to 512
    return switch (sc) {
        4...29 => @intCast(c.GHOSTTY_KEY_A + (sc - 4)),
        30...38 => @intCast(c.GHOSTTY_KEY_DIGIT_1 + (sc - 30)),
        39 => c.GHOSTTY_KEY_DIGIT_0,
        40 => c.GHOSTTY_KEY_ENTER,
        41 => c.GHOSTTY_KEY_ESCAPE,
        42 => c.GHOSTTY_KEY_BACKSPACE,
        43 => c.GHOSTTY_KEY_TAB,
        44 => c.GHOSTTY_KEY_SPACE,
        45 => c.GHOSTTY_KEY_MINUS,
        46 => c.GHOSTTY_KEY_EQUAL,
        47 => c.GHOSTTY_KEY_BRACKET_LEFT,
        48 => c.GHOSTTY_KEY_BRACKET_RIGHT,
        49 => c.GHOSTTY_KEY_BACKSLASH,
        51 => c.GHOSTTY_KEY_SEMICOLON,
        52 => c.GHOSTTY_KEY_QUOTE,
        53 => c.GHOSTTY_KEY_BACKQUOTE,
        54 => c.GHOSTTY_KEY_COMMA,
        55 => c.GHOSTTY_KEY_PERIOD,
        56 => c.GHOSTTY_KEY_SLASH,
        57 => c.GHOSTTY_KEY_CAPS_LOCK,
        58...69 => @intCast(c.GHOSTTY_KEY_F1 + (sc - 58)),
        70 => c.GHOSTTY_KEY_PRINT_SCREEN,
        71 => c.GHOSTTY_KEY_SCROLL_LOCK,
        72 => c.GHOSTTY_KEY_PAUSE,
        73 => c.GHOSTTY_KEY_INSERT,
        74 => c.GHOSTTY_KEY_HOME,
        75 => c.GHOSTTY_KEY_PAGE_UP,
        76 => c.GHOSTTY_KEY_DELETE,
        77 => c.GHOSTTY_KEY_END,
        78 => c.GHOSTTY_KEY_PAGE_DOWN,
        79 => c.GHOSTTY_KEY_ARROW_RIGHT,
        80 => c.GHOSTTY_KEY_ARROW_LEFT,
        81 => c.GHOSTTY_KEY_ARROW_DOWN,
        82 => c.GHOSTTY_KEY_ARROW_UP,
        83 => c.GHOSTTY_KEY_NUM_LOCK,
        84 => c.GHOSTTY_KEY_NUMPAD_DIVIDE,
        85 => c.GHOSTTY_KEY_NUMPAD_MULTIPLY,
        86 => c.GHOSTTY_KEY_NUMPAD_SUBTRACT,
        87 => c.GHOSTTY_KEY_NUMPAD_ADD,
        88 => c.GHOSTTY_KEY_NUMPAD_ENTER,
        89...97 => @intCast(c.GHOSTTY_KEY_NUMPAD_1 + (sc - 89)),
        98 => c.GHOSTTY_KEY_NUMPAD_0,
        99 => c.GHOSTTY_KEY_NUMPAD_DECIMAL,
        100 => c.GHOSTTY_KEY_INTL_BACKSLASH,
        101 => c.GHOSTTY_KEY_CONTEXT_MENU,
        103 => c.GHOSTTY_KEY_NUMPAD_EQUAL,
        104...115 => @intCast(c.GHOSTTY_KEY_F13 + (sc - 104)),
        224 => c.GHOSTTY_KEY_CONTROL_LEFT,
        225 => c.GHOSTTY_KEY_SHIFT_LEFT,
        226 => c.GHOSTTY_KEY_ALT_LEFT,
        227 => c.GHOSTTY_KEY_META_LEFT,
        228 => c.GHOSTTY_KEY_CONTROL_RIGHT,
        229 => c.GHOSTTY_KEY_SHIFT_RIGHT,
        230 => c.GHOSTTY_KEY_ALT_RIGHT,
        231 => c.GHOSTTY_KEY_META_RIGHT,
        else => c.GHOSTTY_KEY_UNIDENTIFIED,
    };
}

/// SDL's `SDL_Keymod` bits as libghostty's: shift, ctrl, alt, super, caps lock, num lock.
pub fn mods(m: u16) c.GhosttyMods {
    var out: c.GhosttyMods = 0;
    if (m & 0x0003 != 0) out |= c.GHOSTTY_MODS_SHIFT;
    if (m & 0x00c0 != 0) out |= c.GHOSTTY_MODS_CTRL;
    if (m & 0x0300 != 0) out |= c.GHOSTTY_MODS_ALT;
    if (m & 0x0c00 != 0) out |= c.GHOSTTY_MODS_SUPER;
    if (m & 0x2000 != 0) out |= c.GHOSTTY_MODS_CAPS_LOCK;
    if (m & 0x1000 != 0) out |= c.GHOSTTY_MODS_NUM_LOCK;
    return out;
}

test "scancodes and mods" {
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_Q), key(20));
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_DIGIT_0), key(39));
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_ARROW_LEFT), key(80));
    try std.testing.expectEqual(@as(c.GhosttyMods, c.GHOSTTY_MODS_CTRL | c.GHOSTTY_MODS_SHIFT), mods(0x0041));
}
