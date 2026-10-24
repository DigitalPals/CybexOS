# nerdos-installer

The installation ISO's screen on tty1: one Rust binary that draws with Slint's
software renderer straight to KMS/DRM and reads keyboard, mouse and touch
through libinput, in a logind seat session as the unprivileged
`nerdos-installer` user. It needs no compositor, browser, Qt or GPU userspace.
It owns no installation logic: `../nerdos-installerd` keeps the draft and drives
the one disk-writing worker, `../nerdos-install`. See
[docs/installation.md](../../docs/installation.md) for the behaviour.

The approach follows the Tiaris installer kiosk: native Slint over KMS, a
stateless renderer of bounded status documents, display zoom from the DRM mode,
a text fallback, an HTML design reference with headless preview renders, and
embedded fonts. Unlike that kiosk, this screen takes input, so it uses Slint's
libseat backend through logind rather than direct device access as root.

## Layout

| Path | Role |
|---|---|
| `ui/app.slint` | window, 1280×800 canvas, top bar, screen and sheet routing |
| `ui/screens.slint` | welcome and system check, disk, account, review, installing, done, stop and failure screens |
| `ui/sheets.slint` | Wi-Fi, keyboard, language, menu, log and USB save, applications, NVIDIA driver, time zone picker |
| `ui/store.slint` | the `Store` global: every property the screens show and every request they make |
| `ui/widgets.slint`, `ui/theme.slint` | controls, brand tokens and icons |
| `src/ui.rs` | daemon snapshots → `Store`, requests → daemon |
| `src/names.rs` | the username and computer-name filter (`[a-z][a-z0-9-]{0,30}`) |
| `src/zones.rs` | time zone search, live local time and the next clock change from TZif data |
| `src/map.rs` | the dot-matrix world map with day and night shading |
| `src/protocol.rs`, `src/client.rs` | `nerdos.installer-state.v1` messages and the socket client |
| `src/zoom.rs`, `src/main.rs` | display zoom, KMS start-up, restarts and the text fallback |
| `src/preview.rs` | `installer-preview`: headless PNG renders of every screen |

## Develop

The pinned Nixpkgs builds this crate (`rust-version` 1.95). Slint needs
Fontconfig, libinput, libxkbcommon, udev and libseat development files:

```sh
nix-shell -p cargo rustc pkg-config fontconfig libinput libxkbcommon udev seatd
cargo test
../nerdos-installerd --dump-static > /tmp/static.json   # PYTHONPATH=../../lifecycle
cargo run --features preview --bin installer-preview -- /tmp/static.json /tmp/renders
```

Renders use fixture snapshots at a fixed moment (2026-10-23 19:00 UTC). Compare
them with the design reference, `../ui-reference/index.html`, when changing the
screens. The time zone tests read the host's TZif files (`TZDIR`).

## Runtime contract

- Socket: `NERDOS_INSTALLER_SOCKET`, default `/run/nerdos-installer/control.sock`.
  On every connection the screen sends `{"action":"hello","client":"screen"}`;
  snapshots count the attached screens in `screens`, which automation waits for.
- Zoom: `NERDOS_INSTALLER_ZOOM` (a number, or `auto`) and
  `NERDOS_INSTALLER_RESOLUTION` (`WIDTHxHEIGHT`); `SLINT_SCALE_FACTOR` wins.
- Keyboard: `XKB_DEFAULT_LAYOUT`, from `/run/nerdos-installer/keyboard.env`.
  Slint's KMS backend compiles the keymap once, so a layout change restarts the
  screen (exit 0; the unit restarts it).
- Exit 75: no usable display after four attempts; the daemon was asked to put
  the text installer on tty1, and the unit does not restart the screen.
- Slint's KMS backend quits on Ctrl+Alt+Backspace/Delete and panics when its
  seat is deactivated (a VT switch); the unit restarts it and the screen resumes
  from the daemon's next snapshot. Its libinput path has no key repeat.

## Asset provenance

| Asset | Source | Licence |
|---|---|---|
| `assets/fonts/SpaceGrotesk-{Regular,Medium,Bold}.ttf` | [floriankarsten/space-grotesk](https://github.com/floriankarsten/space-grotesk) `fonts/ttf/static/`, master on 2026-10-23 | SIL OFL 1.1, `assets/fonts/OFL-SpaceGrotesk.txt` |
| `assets/fonts/JetBrainsMono-{Regular,Medium,SemiBold,Bold}.ttf` | [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono) tag v2.304, `fonts/ttf/` | SIL OFL 1.1, `assets/fonts/OFL-JetBrainsMono.txt` |
| `assets/landmask.txt` | Derived from [Natural Earth](https://www.naturalearthdata.com/) 1:110m land (`ne_110m_land.geojson`), sampled at 2° cell centres | Public domain |
| `assets/logo.svg`, `assets/symbol.svg` | Copies of `assets/brand/logo/svg/nerdos-logo-on-dark.svg` and `assets/brand/symbol/svg/nerdos-symbol-on-dark.svg` | Repository MIT licence |

Font SHA-256 at import: SpaceGrotesk-Regular
`5ede28c4425f3fe4830c8f4754b39e9a87a93d0c3baa5e0a9924532aaa8a98bd`, Medium
`3183b7eb0b4241476360e2cd8e527868616cc16d3ce332c4376505989b772b44`, Bold
`7209bbb75fc0f5c546a5f5773b0db74ffc6abf04c2148c1105cace5765a96bdb`;
JetBrainsMono-Regular `a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f`,
Medium `31c92d01a8a08528b718a43addf0ad3df0af2ca4b7b3290a452f70f358e14d3d`, SemiBold
`1b3bfa1ed5665a4ce3f9feb68d2d4e40e70bf8b4b7d9a3edd418f321b4e166a0`, Bold
`5590990c82e097397517f275f430af4546e1c45cff408bde4255dad142479dcb`.
