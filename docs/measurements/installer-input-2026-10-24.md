# Installer cursor, keyboard and responsiveness — 2026-10-24

This audit covers the ISO kiosk's KMS/software renderer and libinput backend,
Slint controls and sheets, socket client, state service and diagnostic requests.
The disk-writing worker and the shared ISO/installation modules were reviewed;
their installation sequence and safety checks were not changed. Most actual
installation time remains in copying, downloading and building the selected
NixOS closure. No before/after installation-duration claim is made.

The source was frozen before this result record. No workstation deployment,
host reboot, physical disk operation, release publication or new ISO was
performed. The existing served testing image was preserved.

## Findings and changes

- **Invisible cursor:** Slint 1.18.1's KMS software renderer accepts a cursor
  drawing callback but never invokes it. The local dependency patch draws it
  inside the software renderer's partial-rendering pass and invalidates both
  old and new bounds before collecting damage. This preserves double-buffer
  repainting, scaling, rotation and the existing framebuffer-stride handling.
- **Incomplete keyboard access:** Close, links, top-bar chips, menu and picker
  rows, disk details and password visibility were pointer-only. They now have
  keyboard targets and focus indicators. Background targets are disabled while
  a sheet is open; Tab/Shift+Tab remain inside and Escape closes the sheet.
  The welcome shortcut now runs after focused controls instead of intercepting
  their Enter key. Review has no default Enter action; the erase control must be chosen explicitly.
- **Held keys:** the upstream libinput path has no repeat. The pinned patch
  uses XKB's repeatability and current modifier state, with a 350 ms delay and
  33 ms interval. Release and device removal cancel repeat. Activation controls
  swallow repeated Enter/Space, and fields swallow repeated Enter.
- **Snapshot churn:** every snapshot replaced all list models. Models now keep
  their identity and update only changed rows; identical state is skipped.
  Unrelated updates preserve focus and Wi-Fi password fields. If a rescan
  changes the network at the selected index, selection is cleared so credentials
  cannot transfer to a different SSID. Hidden account maps are not regenerated
  on other screens' timer ticks.
- **Blocking I/O:** socket writes moved off the UI thread, have a timeout, and
  belong to one connection generation. Old queued requests are discarded after
  reconnecting; serialized requests are cleared on drop. Slow diagnostics and
  USB discovery run independently of the daemon's request reader, with duplicate
  queries coalesced and disconnected queries cancelled. Diagnostic subprocesses
  are killed and reaped on timeout/cancellation.
- **Reading logs:** arrows, Page Up/Down, Home and End scroll the log. Automatic
  refresh preserves an older reading position; End resumes following output.

The Slint patch is applied only to the Nix build's private vendor copy. It does
not modify a global Cargo cache, the shared Nixpkgs input, or the running shell.
Plain Cargo builds use unpatched upstream dependencies; use the Nix package for
KMS runtime verification.

## Verification

- Python installer worker/network/daemon suites: **68 tests passed**.
- Rust controller/protocol/name/time-zone/map/socket suites and actual rendered
  Slint interaction tests: **26 tests passed**. These cover Close in all seven
  sheets; forward and reverse Tab containment; focus surviving a network update;
  Wi-Fi secrets surviving a signal change and selection clearing on reorder;
  repeated Enter never invoking Install; log scrolling and reading-position
  preservation; and an unread socket not blocking its sender.
- **100 identical snapshots scheduled zero frames**, measured through the real
  controller and software window. This is a bounded redraw regression check,
  not an estimate of physical typing latency or installation speed.

## Real KMS runtime check

A disposable QEMU/KVM guest booted the existing UEFI installer ISO with virtio
KMS at 1280×800, a USB absolute pointer and the PS/2 keyboard. The host store was
shared read-only into a guest-only writable overlay, and transient guest unit
overrides selected the exact final package below. The installer remained an
unprivileged logind-seat service; no compositor or alternative renderer was used.

- The unmodified ISO reproduced the missing cursor: moving over an inert region
  changed zero cursor pixels.
- The final package drew the cursor in five successive moves (188 non-background
  pixels each); the previous positions were clean after every move, including
  revisiting earlier positions across the double buffers.
- Holding `a` for 850 ms produced **16 characters**. Holding Backspace for 650 ms
  deleted **11 characters**. After key release the name stayed unchanged during
  the subsequent observation.
- A real menu click followed by Tab/Enter opened Installation details; another
  Tab/Enter reached Close and returned to the welcome screen. The actual VM
  display captures were inspected.
- Both installer services remained active, the UI journal showed no runtime
  errors, and the service reported `phase: setup`, `diskTouched: false`.

This was repeated on the final package after an earlier iteration. Initial
harness attempts exposed a socket-startup race and a read-only-store limitation;
waiting for the socket and using a guest-only writable overlay resolved those
harness issues. Neither was an installer regression.

## Exact build

- Frozen source: `/nix/store/xr5z0l13g31yd3h5vz3asm0xv9lyhbzl-source`.
- Source NAR: `sha256-ypuqxSE7wnp47bQCKwzeyEcmNR13LvHdPrWJocvScAY=`.
- Packaged installer: `/nix/store/i9kv3bqc22ajb8afdvx4r2yn58mw7bbq-nerdos-installer-1.0.0-beta.2`.
- `nix build .#installer-ui` passed, including all 26 Rust tests in the release
  build. The lock file was not refreshed.
- Before the new patch and test files are tracked by Git, reproduce with
  `nix build "path:$PWD#installer-ui"` so Nix includes them. Validation used a
  frozen non-Git source directory.
- VM boot medium: existing
  `nerdos-1.0.0-beta.2-20261024-installer-kiosk-6421fc1ac80f.iso`, SHA-256
  `219b6af61f7ecce186e13bed2dc11f6dc89c332acc53610738e32b33b85ad186`.

## Qualification limits

The VM runtime checks use an existing ISO with the newly built installer package
injected only into the disposable guest. They do not establish ISO/source parity
for a new image, a fresh installation, installed desktop behavior, physical
AMD/Intel/NVIDIA output, touch, HiDPI, Wi-Fi joining, USB log saving, Secure Boot,
or staged updater qualification. The worker/updater and hardware release gates
remain in force. Physical cursor visibility and input latency still need checking
on a rebuilt ISO using the same final source identity.

## Cleanup

Removed the task's 5.1 GiB remote staging directory and eight task-specific Nix
package outputs (50.84 MiB), together with local temporary captures, harnesses
and logs. No task VM, mount or ISO output was retained. The Nix store paths above
record historical validation identities; the tested package outputs have been
deleted. Normal shared Nix dependency and source caches remain.
