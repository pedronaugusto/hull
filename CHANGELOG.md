# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- hull packages a terminal program as a desktop app: the program runs on a pseudo-terminal inside hull's window, libghostty-vt emulates the terminal and SDL3 draws it.
- `addApp(b, hull, .{ .program, .config, .icon })` packages a program from its own build: on macOS a bundle named for the app, elsewhere the same layout in a folder. It returns `error.LazyDependencyNeeded` while hull's own dependencies are still to be fetched, for the build to return.
- The app's `hull.zon`: its name, identifier and version, its window (size, policy, opacity, padding) and its terminal (font, theme). A file hull cannot read is refused with each refusal's line and column (`config.parse` returns `Parsed`).
- The `hull-protocol` module, std and strand alone, through which a program inside hull reads and changes its settings while it runs. A program that only speaks it asks for hull with `.runner = false` and fetches nothing of the window's.
- The runner, `hull`, in a window or headless (`--headless out.png`), with a keys script for the headless run (`headless.parsePresses`).

### Platforms

- The runner builds where SDL3 does: x86_64 and aarch64 Linux, macOS and Windows. For any other target hull is `hull-protocol` alone, and asking for the runner there stops the build naming why.

### Fixed

- `headless.parsePresses` gives back what it read when a later key is refused, where the list leaked.
