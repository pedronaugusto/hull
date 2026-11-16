//! One key as the platform saw it, in libghostty-vt's terms: its header's
//! types alone, so what reads keys needs no more of libghostty than that.
const c = @import("vt");

/// One key as the platform saw it, for `Vt.encodeKey`.
pub const Key = struct {
    action: Action,
    /// The physical key, libghostty's W3C code.
    key: c.GhosttyKey,
    mods: c.GhosttyMods = 0,
    consumed: c.GhosttyMods = 0,
    /// The text the key produced under the layout and mods, if any.
    text: []const u8 = "",
    /// The key's character with no modifiers, 0 for none.
    unshifted: u32 = 0,

    pub const Action = enum(c_uint) { release = 0, press = 1, repeat = 2 };
};
