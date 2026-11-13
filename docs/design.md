# hull's design

hull puts a terminal program in a native window of its own and ships it as an app. The program runs unchanged; hull
is the terminal it runs in, owned by the app. What is built is marked so; the rest is designed.

## The boundary

- **One program per window, unchanged.** A program knows nothing of hull unless it wants to: it runs on a pseudo-terminal
  and draws as it would in any terminal. *Protects:* any terminal program, a visor program or a game, packaged
  without a line changed.
- **The app owns everything; the player's terminal nothing.** Font, theme, opacity, padding and window policy come
  from the app's `hull.zon`, never a terminal configuration. *Protects:* an app that looks the same on every
  machine.
- **The bundle is the app's.** The window, the Dock, the menus and the process carry the app's name and icon.
- **No app is named in hull.** An app's `hull.zon` and icon live in its own repository, and its build packages it
  through `addApp`. *Protects:* a general package, as the family's are.

## The layers

1. **base**: aegis. Every byte the program sends is untrusted; pictures are bounded in size and in what their data
   may inflate to; integer sizes are checked. Built for pictures (`pngdec.zig`).
2. **terminal**: libghostty-vt through its C API, from Ghostty's zig-0.17 branch until its port merges. hull
   supplies what the C library leaves to its embedder: PNG decoding, the answers to the program's queries, the
   theme as the terminal's defaults. Built.
3. **render**: a frame as draws against a narrow backend: a glyph atlas, images, rectangles, quads, present.
   - `gpu.zig` is that backend on SDL3's renderer: Metal on macOS, Direct3D on Windows, Vulkan on Linux. A picture
     keeps its texture and takes new pixels in place. Built.
   - `cpu.zig` is the same on the CPU, for headless frames and tests. Built.
   - A console backend on the family's own rendering framework is a later addition behind the same interface.
4. **program**: conduit's pseudo-terminal and child (`Program.zig`): a session of its own on POSIX, a pseudoconsole
   in passthrough on Windows, and everything it starts ended with it. Its output and its channel are read on
   `std.Io` tasks into queues the loop takes from, and wake it. Built.
5. **window**: SDL3's window and events: keys with their text, input methods, macOS's own full screen, the window's
   pixel density. Built on macOS.
6. **settings**: hull's own, declared, applied live and kept per app (`hull-settings.json`). Built.
7. **packaging**: `addApp` from the app's build, and the bundler it runs where the app is built. Built for macOS.

## Settings: three owners, one page

- **hull** owns the window and terminal: theme (any of Ghostty's, from the same pinned release, built into a table
  by `tools/themes.zig`; Rosé Pine by default, an app's `featured_themes` offered first), background opacity (80–100, 100 by default,
  windowed only), font size, padding, full screen.
- **The program** owns its own; a game's include its look and reading settings.
- A program learns it runs in hull from `HULL_SOCKET` and speaks `hull-protocol` (std and strand alone, and its
  build fetches nothing else: `.runner = false`, with the window's dependencies lazy): hull's
  settings declared with their kinds, values and availability, set, and changes told. A program's settings page
  shows them beside its own; in a terminal there are none.
- hull ships words for its settings; a program may reword them by name.
- A line goes to the program whole or not at all: a task writes the channel as the program reads it, up to 4 MiB
  waiting, so a program that reads late gets every line, never half of one, and one that never reads costs a
  bounded amount.
- A theme change reaches every program the standard way, OSC 4, 10 and 11 and mode 2031's notice, in hull and in
  any terminal alike.

## Platforms

- **macOS:** built. An `.app`, ad-hoc signed; a release signs and notarises.
- **Linux:** the runner builds; an AppImage is to come.
- **Windows:** the runner builds. The program runs on a pseudoconsole asked for passthrough, so the program's own
  bytes reach the terminal rather than the console host's redraw of them (which drops what it does not know,
  kitty pictures among them); a Windows too old for passthrough gets the redraw. The settings channel is conduit's
  duplex pipe, inherited beside the pseudoconsole. Not yet run there.

## Invariants

- The program's bytes are never believed: every size is bounded and every parser fuzzed. *Protects:* a window no
  program can crash or exhaust.
- The program is never changed and never named by hull. *Protects:* one hull for every app.
- A picture is drawn pixel for pixel when its placement is its own size, and by nearest neighbour otherwise.
  *Protects:* a dither that stays a dither.

## Testing

- Units beside the code; fuzz targets for every parser of outside bytes: pictures, `hull.zon`, the headless keys.
- An example app (`examples/hello`) packaged through `addApp` and its bundle checked, under `bay test`.
- Headless frames through the CPU backend, and the window's own frame read back (`HULL_SNAP`).
