//! GLFW's keys as libghostty's: the physical key (GLFW names keys by
//! their US position, which is what the kitty protocol's codes are), and
//! the character it makes with no modifiers on the active layout.
const std = @import("std");
const c = @import("vt.zig").c;

pub fn key(glfw: c_int) c.GhosttyKey {
    return switch (glfw) {
        65...90 => @intCast(c.GHOSTTY_KEY_A + (glfw - 65)),
        48...57 => @intCast(c.GHOSTTY_KEY_DIGIT_0 + (glfw - 48)),
        290...314 => @intCast(c.GHOSTTY_KEY_F1 + (glfw - 290)),
        320...329 => @intCast(c.GHOSTTY_KEY_NUMPAD_0 + (glfw - 320)),
        32 => c.GHOSTTY_KEY_SPACE,
        39 => c.GHOSTTY_KEY_QUOTE,
        44 => c.GHOSTTY_KEY_COMMA,
        45 => c.GHOSTTY_KEY_MINUS,
        46 => c.GHOSTTY_KEY_PERIOD,
        47 => c.GHOSTTY_KEY_SLASH,
        59 => c.GHOSTTY_KEY_SEMICOLON,
        61 => c.GHOSTTY_KEY_EQUAL,
        91 => c.GHOSTTY_KEY_BRACKET_LEFT,
        92 => c.GHOSTTY_KEY_BACKSLASH,
        93 => c.GHOSTTY_KEY_BRACKET_RIGHT,
        96 => c.GHOSTTY_KEY_BACKQUOTE,
        161 => c.GHOSTTY_KEY_INTL_BACKSLASH,
        256 => c.GHOSTTY_KEY_ESCAPE,
        257 => c.GHOSTTY_KEY_ENTER,
        258 => c.GHOSTTY_KEY_TAB,
        259 => c.GHOSTTY_KEY_BACKSPACE,
        260 => c.GHOSTTY_KEY_INSERT,
        261 => c.GHOSTTY_KEY_DELETE,
        262 => c.GHOSTTY_KEY_ARROW_RIGHT,
        263 => c.GHOSTTY_KEY_ARROW_LEFT,
        264 => c.GHOSTTY_KEY_ARROW_DOWN,
        265 => c.GHOSTTY_KEY_ARROW_UP,
        266 => c.GHOSTTY_KEY_PAGE_UP,
        267 => c.GHOSTTY_KEY_PAGE_DOWN,
        268 => c.GHOSTTY_KEY_HOME,
        269 => c.GHOSTTY_KEY_END,
        280 => c.GHOSTTY_KEY_CAPS_LOCK,
        281 => c.GHOSTTY_KEY_SCROLL_LOCK,
        282 => c.GHOSTTY_KEY_NUM_LOCK,
        283 => c.GHOSTTY_KEY_PRINT_SCREEN,
        284 => c.GHOSTTY_KEY_PAUSE,
        330 => c.GHOSTTY_KEY_NUMPAD_DECIMAL,
        331 => c.GHOSTTY_KEY_NUMPAD_DIVIDE,
        332 => c.GHOSTTY_KEY_NUMPAD_MULTIPLY,
        333 => c.GHOSTTY_KEY_NUMPAD_SUBTRACT,
        334 => c.GHOSTTY_KEY_NUMPAD_ADD,
        335 => c.GHOSTTY_KEY_NUMPAD_ENTER,
        336 => c.GHOSTTY_KEY_NUMPAD_EQUAL,
        340 => c.GHOSTTY_KEY_SHIFT_LEFT,
        341 => c.GHOSTTY_KEY_CONTROL_LEFT,
        342 => c.GHOSTTY_KEY_ALT_LEFT,
        343 => c.GHOSTTY_KEY_META_LEFT,
        344 => c.GHOSTTY_KEY_SHIFT_RIGHT,
        345 => c.GHOSTTY_KEY_CONTROL_RIGHT,
        346 => c.GHOSTTY_KEY_ALT_RIGHT,
        347 => c.GHOSTTY_KEY_META_RIGHT,
        348 => c.GHOSTTY_KEY_CONTEXT_MENU,
        else => c.GHOSTTY_KEY_UNIDENTIFIED,
    };
}

/// The key's character on a US layout with no modifiers, for when the
/// layout's own name for it is not to be had.
pub fn usUnshifted(glfw: c_int) u32 {
    return switch (glfw) {
        65...90 => @intCast(glfw + 32),
        32, 39, 44...57, 59, 61, 91...93, 96 => @intCast(glfw),
        else => 0,
    };
}

/// GLFW's modifier bits are libghostty's: shift, ctrl, alt, super, caps,
/// num lock, in that order.
pub fn mods(glfw: c_int) c.GhosttyMods {
    return @intCast(glfw & 0x3f);
}

test "keys and mods" {
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_Q), key(81));
    try std.testing.expectEqual(@as(u32, 'q'), usUnshifted(81));
    try std.testing.expectEqual(@as(c.GhosttyMods, c.GHOSTTY_MODS_CTRL | c.GHOSTTY_MODS_SHIFT), mods(3));
}
