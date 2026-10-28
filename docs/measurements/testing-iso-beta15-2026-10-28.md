# Beta.15: the welcome guide closes what Connect opened — 2026-10-28

On beta.14, after signing in on the Connect step, the desktop still showed the
sign-in's terminal, the Brave window it opened and 1Password. Leaving the
guide now closes them.

## Changes

- `3852a25`: while the guide stands aside for the assistant's sign-in, it
  records every window that opens (the terminal, the browser the agent
  opens, 1Password asked to unlock). While it stands aside for 1Password, it
  records only 1Password's windows. Finish, and Close while the guide shows,
  close the recorded windows as their close buttons would. The guide stays on
  screen until they are gone, at most 2 s. A sign-in still waiting keeps its
  windows; closing the guide from its pill keeps them all.
- The same commit matches 1Password's window class without case. In the VM
  the real 1Password's window has the Wayland app id `1password`, so the
  guide's "close 1Password to come back" check, which looked for
  `1Password`, may not have fired on beta.14.
- `56468b8`: `VERSION` advances to beta.15.

## Evidence before the image

- `checks.x86_64-linux.browser-1password` passes on `56468b8` (about 70 s).
  Besides the browser link and the tick (see the beta.14 record), it now runs
  the Connect sign-in through the real assistant service with a scripted
  Claude Code. That script opens its sign-in page with `xdg-open`, detached,
  as Claude Code does, inside the real kitty terminal the guide starts. The
  guide recorded five windows:
  - a stand-in 1Password window left open, with the pill's Resume instead of
    closing it;
  - the real 1Password's own window (`1password`): the dialog saying the
    made-up account stops it from starting;
  - the kitty terminal;
  - Brave Origin (`brave-origin`);
  - the keyring prompt Brave raised, which happens only in this VM because
    its sign-in leaves the keyring locked.

  A window opened while the guide showed was not recorded. After Close, all
  five were gone once the guide's layer was, and that window stayed. The kitty
  terminal, held at a shell prompt after the login, closed without asking.
- `checks.x86_64-linux.hyprland-pointer` (Connect with a stand-in 1Password on
  real Hyprland, and the Assistant drags) and the `lifecycle` flake check
  passed on `56468b8`.
- `tests/welcome-guide.py` (real shell, headless Sway) checks that Finish asks
  to close exactly the 1Password window left open and the sign-in's windows,
  and not a window the person opened during 1Password. Node tests cover the
  rule, including a sign-in still waiting.
- `tests/run` (699 Python and 1468 Node tests) and `tests/qml-lint` passed on
  `3852a25`, whose only difference from `56468b8` is `VERSION`. Nothing ran on
  physical hardware.

## Artifact and source

- Served image: `/data/pxe/iso/cybexos-1.0.0-beta.15.iso` (7,120,576,512 bytes).
- Download: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.15.iso>.
- Checksum: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.15.iso.sha256> (92 bytes).
- SHA-256: `dbfdfac7dbf90c1675a396803588ba20fde6dddf2a82124d9133b7cb0837e21b`.
- Exact build revision: `56468b8509527f5ffcf1ef8d571cd833b6a2706f`.
- Source NAR: `sha256-vsLYC0F7vRDf6KCGe9TuSYe0Q+jzD3Cu3VdPmM6hXjo=`.
- Version/platform: 1.0.0-beta.15, NixOS 26.05, x86_64-linux.

The ISO built from the exact committed Git flake and passed
`scripts/check-image-parity` in 41 sections against that revision and NAR. The
lock file was unchanged. This record is a later documentation-only commit; no
signed release or channel publication was performed.

## Installation qualification

`scripts/qualify-installations --case both --scenario lifecycle --interactive
--applications standard` installed the final ISO through the real tty1
installer screen onto blank disposable UEFI disks, once plain and once
encrypted. Both passed all 16 installation milestones and all 9 lifecycle
checks, 50 results in all, with the installed release identity at
`56468b8`.

The milestones and lifecycle checks are the same as for beta.14: source
identity, store transfer, boot, encryption, the desktop and GUI checks, the
welcome guide at first login, shortcuts, desktop health and password changes;
then automatic preparation, update failures and recovery, trial boot and
fallback, confirmation and rollback with personal persistence.

Not exercised:
- a real 1Password account, its main window, and whether closing that window
  at the end of the guide quits 1Password (which would disconnect Brave's
  extension until 1Password starts again);
- whether Brave, which restores its last session, brings back the sign-in tab
  the next time it opens;
- a real Claude Code or Codex sign-in;
- 1Password's "Start at login", which the session cannot honour because it
  does not run XDG autostart entries;
- physical hardware, Secure Boot, physical PXE boot and signed-channel
  updating.

## PXE delivery and cleanup

The image and its SHA-256 sidecar were copied and verified outside the served
tree, then moved in without overwriting, with mode 0644; beta.14 and its
checksum stayed unchanged. The served checksum and a full HTTP download
matched. iVentoy's refresh returned success, its status returned to running,
and the image tree lists `cybexos-1.0.0-beta.14.iso` and
`cybexos-1.0.0-beta.15.iso`. `iventoy.service` stayed active, and no restart
was needed.

The qualification lease `d216745ada9d441188f53834b5340637` and the VM test
leases closed with nothing remaining. Task staging under `/data/tmp`
(qualification disks, screenshots, logs and VM test outputs) was removed after
this record. The final image output
`/nix/store/5zx794hhpihndis1dx527kp9xp41qwi3-cybexos-1.0.0-beta.15-x86_64-linux.iso`
and successful check outputs remain in the Nix-managed build cache.
