# hull

A terminal program of the family in a window of its own, as a native app: the program runs unchanged on a
pty, libghostty-vt keeps its terminal, and hull draws that terminal in a window that carries the app's name.
This is the **spike**: it proves the route on WAKE so the package can be designed from facts.

## Running it

```sh
export PATH="$HOME/.local/share/bay/zig/0.17.0:$PATH"
zig build                                   # hull; first build also fetches Zig 0.16.0 for libs/
zig build test                              # the units, hull-protocol's among them
zig build app                               # zig-out/app/WAKE.app from apps/wake/hull.zon
open zig-out/app/WAKE.app
./zig-out/bin/hull --app apps/wake          # the same, unpackaged
./zig-out/bin/hull -- /bin/zsh              # any program, hull's defaults
tools/look.sh hide-and-seek                 # shots/hide-and-seek.png, headless
./zig-out/bin/hull --app apps/wake --headless out.png --at 6.5 --keys 1.5:enter,3.5:enter
./zig-out/bin/hull --app apps/wake --bench  # presses keys itself; latency, frame time, memory, startup
HULL_SNAP=/tmp/f.png@3 ./zig-out/bin/hull --app apps/wake   # the window's own GL frame, read back
```

## Layout

- `src/vt.zig`: libghostty-vt through its C API: the effects that answer the program, the theme as defaults.
- `src/render.zig`: the frame as draws against a narrow backend: glyph atlas upload, image upload, rects, quads,
  present. `src/gl.zig` is that backend on raylib (OpenGL); `src/cpu.zig` the same on the CPU, for PNGs.
- `src/font.zig`: ztypeset faces, the cell, glyph rasters; `src/window.zig`: raylib's window, GLFW's keys.
- `src/settings.zig` and `protocol/hull_protocol.zig`: hull's settings and the channel a program sees them on.
- `libs/`: libghostty-vt (the family's ghostty pin) and raylib 6.0, built as static C libraries by Zig 0.16.0,
  the Zig their pins need; hull is Zig 0.17.0 and links them. `tools/zig16.sh` fetches that Zig, checked.
- `apps/wake/hull.zon`: WAKE as an app: name, id, version, icon, program, window policy, terminal.

## An app's hull.zon

The app sets everything; nothing is read from the user's terminal configuration.

| hull.zon | Ghostty's setting it stands for |
|---|---|
| `name`, `id`, `version`, `icon` | (the bundle: CFBundleName/DisplayName/Executable, identifier, icon) |
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

hull-protocol (`b.dependency("hull", ...).module("hull-protocol")`, std and strand only) frames JSON lines:
`hello` (every setting: kind, range or values, default, value, hull's words, `available` and `reason`), `set`,
`changed` (any change, whoever made it, availability included), `refused` (hull's words for why), `get`.
hull's settings: `theme`, `background-opacity` (unavailable in full screen, value kept), `font-size`,
`padding`, `fullscreen`. Chosen values are kept in `~/Library/Application Support/<id>/hull-settings.json`.
A theme change also reaches the program the standard way: new OSC 4/10/11 defaults and, under mode 2031,
`CSI ? 997 ; 1|2 n`.
