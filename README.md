# hull

hull packages a terminal program as a desktop app. The program runs on a pty inside hull's window;
[libghostty-vt](https://github.com/ghostty-org/ghostty) emulates the terminal and SDL3 draws it.

- Text from ztypeset's glyphs, kitty pictures drawn pixel for pixel, the kitty keyboard protocol.
- The terminal configured by the app's `hull.zon`: font, theme, padding, opacity, window size and policy.
- Settings a program can read and change while it runs, over `hull-protocol`.
- A bundle made from the app's own build with `addApp`.

Status: **0.0.0**, private. macOS works; Linux builds; Windows is not built yet. MIT.

## An app from its own build

The app's repository carries its `hull.zon` and icon; its build makes the app:

```zig
const hull = @import("hull");

const app = hull.addApp(b, b.dependency("hull", .{ .target = target, .optimize = optimize }), .{
    .program = exe,                       // the program, unchanged
    .config = b.path("app/hull.zon"),     // who it is, its window, its terminal
    .icon = b.path("app/icon.png"),       // square, 1024 px
});
b.step("app", "Package the program as an app").dependOn(app.step);
```

`zig build app` puts `<name>.app` in `zig-out/app` on macOS: hull's runner as `Contents/MacOS/<name>`, the
program in `Contents/Resources/program`, its `hull.zon` beside, an `.icns` of the icon, ad-hoc signed. Elsewhere
the same layout in a folder of the app's name, until each platform's installer is made.

## Running it

```sh
bay test                                    # the gate: format, lint, fuzz targets, units, an example app packaged
zig build                                   # the runner (zig-out/bin/hull) and the bundler
./zig-out/bin/hull --app DIR                # an app's hull.zon in DIR, unpackaged
./zig-out/bin/hull -- /bin/zsh              # any program, hull's defaults
./zig-out/bin/hull --app DIR --headless out.png --at 6.5 --keys 1.5:enter,3.5:enter   # a frame, no display
HULL_SNAP=/tmp/f.png@3 ./zig-out/bin/hull --app DIR    # the window's own frame, read back
HULL_DIAG=1 ./zig-out/bin/hull --app DIR    # memory every two seconds, and the frame and key times at the end
```

## Layout

- `src/vt.zig`: libghostty-vt through its C API, from Ghostty's zig-0.17 branch, as the family takes it until the
  port merges: the effects that answer the program, the theme as defaults, PNG pictures decoded by `pngdec.zig`
  (the program's bytes, untrusted and bounded).
- `src/render.zig`: a frame as draws against a narrow backend (glyph atlas, images, rects, quads, present);
  `gpu.zig` is that backend on SDL3's renderer (Metal on macOS, Direct3D on Windows, Vulkan on Linux), `cpu.zig`
  the same on the CPU, for PNGs.
- `src/window.zig`: SDL3's window and its events; `keys.zig` its keys as libghostty's.
- `src/font.zig`: ztypeset faces, the cell, glyph rasters.
- `src/settings.zig` and `protocol/hull_protocol.zig`: hull's settings and the channel a program sees them on.
- `tools/bundle.zig`: the bundler `addApp` runs; `examples/hello`: an app as a program's build makes one.

## An app's hull.zon

The app sets everything; nothing is read from the user's terminal configuration.

| hull.zon | Ghostty's setting it stands for |
|---|---|
| `name`, `id`, `version` | (the bundle: CFBundleName/DisplayName/Executable, identifier, version) |
| `window.cols`, `.rows`, `.min_cols`, `.min_rows`, `.resizable` | `window-width`, `window-height`, resizing |
| `window.tabs`, `.new_windows` (both off) | tabs and `⌘N`; one program per window |
| `window.program_title` (off) | `title`: a title the program sets is ignored; the window says the app's name |
| `window.quit_with_program`, `.close_key` | `confirm-close-surface`, `quit-after-last-window-closed` |
| `terminal.font`, `font_bold`, `font_italic`, `font_bold_italic`, `font_size` | `font-family*`, `font-size` |
| `terminal.font_fallback` | (system fallback; hull has no font discovery yet) |
| `terminal.adjust_cell_width`, `adjust_cell_height` | `adjust-cell-width`, `adjust-cell-height` |
| `terminal.theme`, `background`, `foreground`, `cursor_color`, `palette` | `theme`, `background`, `foreground`, `cursor-color`, `palette` |
| `terminal.background_opacity` (80..100, windowed only) | `background-opacity` |
| `terminal.padding_x`, `padding_y` (always balanced) | `window-padding-x/-y`, `window-padding-balance` |
| `terminal.cursor_style`, `cursor_blink` | `cursor-style`, `cursor-style-blink` |
| `terminal.option_as_alt` | `macos-option-as-alt` |
| `terminal.scrollback` | `scrollback-limit` |

## What a program sees

`TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=hull`, `HULL=<version>`, `HULL_APP=<id>`, and
`HULL_SOCKET=fd:3`: the channel to hull's settings. Its presence is how a program knows it runs in hull. Other
terminals' variables (TMUX, KITTY_*, GHOSTTY_*, ITERM_*, ...) are removed. XTVERSION answers `hull <version>`.

hull-protocol frames JSON lines: `hello` (every setting: its kind, range or values, a toggle's two words, its
default and value, hull's words, `available` and `reason`), `set`, `changed` (any change, whoever made it,
availability included), `refused` (hull's words for why) and `get`. A program takes it as
`b.dependency("hull", .{ .runner = false, ... }).module("hull-protocol")`: std and strand only, and none of
hull's window is fetched.
hull's settings: `theme`, `background_opacity` (unavailable in full screen, value kept), `font_size`,
`padding`, `fullscreen`. Chosen values are kept in `~/Library/Application Support/<id>/hull-settings.json`.
A theme change also reaches the program the standard way: new OSC 4/10/11 defaults and, under mode 2031,
`CSI ? 997 ; 1|2 n`.
