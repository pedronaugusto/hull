//! The runner's modules whose properties the fuzz job fuzzes, those that read
//! input and need no more of libghostty-vt than its header: the keys script,
//! hull.zon, and the PNG reader. Built without libghostty, so a fuzzing
//! session builds none of it.
test {
    _ = @import("presses.zig");
    _ = @import("config.zig");
    _ = @import("pngdec.zig");
}
