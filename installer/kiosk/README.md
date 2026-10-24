# cybexos-installer

The installation ISO's screen on tty1: one Rust binary that draws with Slint's
software renderer straight to KMS/DRM and reads keyboard, mouse and touch
through libinput, in a logind seat session as the unprivileged
`cybexos-installer` user. It needs no compositor, browser, Qt or GPU userspace.
It owns no installation logic: `../cybexos-installerd` keeps the draft and drives
the one disk-writing worker, `../cybexos-install`. See
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
| `src/protocol.rs`, `src/client.rs` | `cybexos.installer-state.v1` messages and the socket client |
| `src/zoom.rs`, `src/main.rs` | display zoom, KMS start-up, restarts and the text fallback |
| `src/preview.rs` | `installer-preview`: headless PNG renders of every screen |

## Develop

The pinned Nixpkgs builds this crate (`rust-version` 1.95). Slint needs
Fontconfig, libinput, libxkbcommon, udev and libseat development files:

```sh
nix-shell -p cargo rustc pkg-config fontconfig libinput libxkbcommon udev seatd
cargo test
../cybexos-installerd --dump-static > /tmp/static.json   # PYTHONPATH=../../lifecycle
cargo run --features preview --bin installer-preview -- /tmp/static.json /tmp/renders
```

Renders use fixture snapshots at a fixed moment (2026-10-23 19:00 UTC). Compare
them with the design reference, `../ui-reference/index.html`, when changing the
screens. The time zone tests read the host's TZif files (`TZDIR`).

## Runtime contract

- Socket: `CYBEXOS_INSTALLER_SOCKET`, default `/run/cybexos-installer/control.sock`.
  On every connection the screen sends `{"action":"hello","client":"screen"}`;
  snapshots count the attached screens in `screens`, which automation waits for.
- Zoom: `CYBEXOS_INSTALLER_ZOOM` (a number, or `auto`) and
  `CYBEXOS_INSTALLER_RESOLUTION` (`WIDTHxHEIGHT`); `SLINT_SCALE_FACTOR` wins.
- Keyboard: `XKB_DEFAULT_LAYOUT`, from `/run/cybexos-installer/keyboard.env`.
  Slint's KMS backend compiles the keymap once, so a layout change restarts the
  screen (exit 0; the unit restarts it).
- Exit 75: no usable display after four attempts; the daemon was asked to put
  the text installer on tty1, and the unit does not restart the screen.
- The pinned Slint dependencies have a small local patch, `slint-kms.patch`,
  applied to the Nix build's private vendor copy. It draws the software cursor
  in the same partial-rendering pass, damages its old and new bounds, and adds
  XKB-aware held-key repeat (350 ms delay, 33 ms interval). Buttons ignore
  repeated activation keys. Test the packaged KMS backend through Nix; plain
  Cargo uses the upstream dependencies without this patch.
- KMS software frames render in cached RAM instead of blending in uncached
  display memory. Only physical damage is copied to scanout, including the two
  preceding frames for triple buffering. New buffers or unknown ages receive a
  complete cached frame. This keeps native resolution and firmware graphics
  support. `SLINT_KMS_NO_SHADOW_BUFFER=1` restores direct rendering for controlled
  comparisons; it is not the default. `tests/presentation.rs` exercises the exact
  vendored damage-copy module, including padding, 16/32-bit formats and physical
  coordinates after rotation.
- Sheets disable background keyboard targets; Tab/Shift+Tab stay in the sheet
  and Escape closes it. Controls show focus rings. Snapshot updates keep list
  models and delegates, including focused rows and Wi-Fi credentials; a changed
  network identity clears the Wi-Fi selection instead of transferring a secret.
- Socket writes run on a background writer and cannot stall the UI. Queued
  requests belong to one connection and are discarded after reconnecting.
  Diagnostics and USB discovery run independently of draft edits; duplicate
  diagnostics are coalesced and disconnected clients cancel their queries.
- Log scrolling works with arrows, Page Up/Down, Home and End. Updates follow
  new output only while the reader is at the end; scrolling up preserves the
  reading position across automatic refreshes.
- Slint's KMS backend quits on Ctrl+Alt+Backspace/Delete and panics when its
  seat is deactivated (a VT switch); the unit restarts it and the screen resumes
  from the daemon's next snapshot.

## Asset provenance

| Asset | Source | Licence |
|---|---|---|
| `assets/fonts/SpaceGrotesk-{Regular,Medium,Bold}.ttf` | [floriankarsten/space-grotesk](https://github.com/floriankarsten/space-grotesk) `fonts/ttf/static/`, master on 2026-10-23 | SIL OFL 1.1, `assets/fonts/OFL-SpaceGrotesk.txt` |
| `assets/fonts/JetBrainsMono-{Regular,Medium,SemiBold,Bold}.ttf` | [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono) tag v2.304, `fonts/ttf/` | SIL OFL 1.1, `assets/fonts/OFL-JetBrainsMono.txt` |
| `assets/landmask.txt` | Derived from [Natural Earth](https://www.naturalearthdata.com/) 1:110m land (`ne_110m_land.geojson`), sampled at 2° cell centres | Public domain |
| `assets/logo.svg`, `assets/symbol.svg` | Copies of `assets/brand/logo/svg/cybexos-logo-on-dark.svg` and `assets/brand/symbol/svg/cybexos-symbol-on-dark.svg` | Repository MIT licence |

Font SHA-256 at import: SpaceGrotesk-Regular
`5ede28c4425f3fe4830c8f4754b39e9a87a93d0c3baa5e0a9924532aaa8a98bd`, Medium
`3183b7eb0b4241476360e2cd8e527868616cc16d3ce332c4376505989b772b44`, Bold
`7209bbb75fc0f5c546a5f5773b0db74ffc6abf04c2148c1105cace5765a96bdb`;
JetBrainsMono-Regular `a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f`,
Medium `31c92d01a8a08528b718a43addf0ad3df0af2ca4b7b3290a452f70f358e14d3d`, SemiBold
`1b3bfa1ed5665a4ce3f9feb68d2d4e40e70bf8b4b7d9a3edd418f321b4e166a0`, Bold
`5590990c82e097397517f275f430af4546e1c45cff408bde4255dad142479dcb`.
