# Beta.16: the Settings redesign — 2026-10-28

Beta.16 carries the Settings redesign ([docs/settings.md](../settings.md)) and
the Mac-like desktop style merged after beta.15 (`f2ebcc6`).

## Changes

- `dc5b9c6`: the Settings redesign.
  - **Layout:**
    - The rail is Home and three groups of six pages, each with its own glyph.
    - Keyboard (Layouts, Shortcuts) and Backup & storage (Backups, Recovery
      points, Disk space) have tabs. About became Home.
    - Plugins moved to Personalize and the Assistant to System. The dock's
      switches moved to Workspaces & dock.
  - **Home:** the computer and its update state, a storage, battery or memory,
    backups and network strip, and what needs attention. Then recently changed
    settings with Undo, shell health, the Welcome guide, the settings file and
    Reset all.
  - **Search and header:**
    - A search palette (`/`, Ctrl+K, Ctrl+F) shows each setting's current
      value, runs actions, and switches settings with Ctrl+Enter.
    - The header has Back (Alt+Left), a widget breadcrumb and a Changes chip.
  - **Changes:**
    - The chip counts drafts on any page and opens one review of them. Pages
      holding a draft are marked in the rail.
    - Groups that build a system change say "Administrator · restart" before
      they are edited.
  - **Appearance:** a theme gallery. The window is 960 × 700 (scaled), up from
    900 × 664.
  - **Updater:** a timezone and a system language chosen together are one
    regional request (`cybex config region` with two FIELD VALUE PREVIOUS
    triples), so one generation and one restart.
- `1a9b62b`: `VERSION` advances to beta.16.

## Evidence before the image

All of this ran on `dc5b9c6` and `1a9b62b`, whose only difference is
`VERSION`.

- **`tests/run` and `tests/qml-lint`:**
  - 713 NixOS Python tests, 25 system-settings, 5 settings-ownership and
    23 model-usage tests passed.
  - 1518 Node tests ran: 1502 passed, 16 were skipped and none failed.
  - qml-lint found no errors in 447 QML files and 4 harnesses. Only the 8
    warnings already present remain.
  - The Dutch catalog has no missing or unused entries.
- **`tests/settings-pages.py`** is new. It runs the real shell from source under
  a private headless Sway and checks:
  - every page and tab, and the legacy ids `about`, `shortcuts` and `storage`;
  - Back and Alt+Left, and that closing forgets the trail;
  - the palette: "/" opens it, Enter jumps to and highlights Night light, and
    Ctrl+Enter switches Do Not Disturb in place;
  - Recently changed and its Undo;
  - a timezone and a touchpad draft reviewed and applied from the Changes
    sheet. The recording `cybex` received one `cybex config region timezone
    Europe/Berlin "Europe/Amsterdam"` call; the previous value was the host's
    real timezone, read over D-Bus.

  The run includes the narrow window and light mode, and no QML warnings
  appeared. A separate probe in the same environment timed the shell's IPC
  replies while Settings opened. The slowest reply was 29 ms opening Home,
  35 ms opening Appearance, and 24 ms opening Home through the old `about` id,
  against about 20 ms when idle. The probe's `cybex doctor` was a fixture.
- **The existing headless harnesses** passed through the redesigned window:
  `tests/shortcut-editor.py` (Keyboard → Shortcuts, opened through the old id)
  and `tests/welcome-guide.py`.
- **The lifecycle VM test** (`checks.x86_64-linux.vm`, with
  `QEMU_OPTS=-no-user-config`) passed in 175 s. It now stages a timezone and a
  language together through the real updater:
  - `cybex config region timezone Europe/Berlin '"UTC"' locale nl_NL.UTF-8
    '["LANG=en_US.UTF-8"]'` went through `cybexos-request` and
    `cybexos-region.service`, and produced one `region` candidate in 23 s.
  - The candidate's `desktop-settings.json` is
    `{"timezone": "Europe/Berlin", "locale": "nl_NL.UTF-8"}`. Its
    `/etc/localtime` resolves to `zoneinfo/Europe/Berlin` and its
    `locale.conf` has `LANG=nl_NL.UTF-8`.
  - The running system and `/etc/nixos` were unchanged. A request naming
    `timezone` twice was refused, and the candidate was discarded.

  The test machine now declares `en_US` and `nl_NL` as supported locales, so
  the prebuilt candidate already contains both. This VM test ran on the tree
  before the version bump.
- **Real Hyprland `--verify-config`** of the beta.16 payload system
  (`desktop_check.verify_compositor`) passed.

Nothing ran on physical hardware.

## Artifact and source

- Served image: `/data/pxe/iso/cybexos-1.0.0-beta.16.iso` (7,120,576,512 bytes).
- Download: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.16.iso>.
- Checksum: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.16.iso.sha256>.
- SHA-256: `a9228387d25e5d9e2c6ea0daae25b9c5b444c89e53fb80c106aae6adb756907e`.
- Exact build revision: `1a9b62bc0f275164e300a7561f0fc3a664b587b2`.
- Source NAR: `sha256-XGuyX4E0wMoYrg+xYVjOEXF4nu5hltTGt0xtRIy2igU=`.
- Version/platform: 1.0.0-beta.16, NixOS 26.05, x86_64-linux.

The ISO built from the exact committed Git flake and passed
`scripts/check-image-parity` in 41 sections against that revision and NAR. The
lock file was unchanged. This record is a later documentation-only commit; no
signed release or channel publication was performed.

## Installation qualification

`scripts/qualify-installations ISO --scenario lifecycle --interactive
--applications standard` installed the final ISO through the real tty1
installer screen onto blank disposable UEFI disks.

- **First attempt (`--case both`):**
  - The encrypted installation passed all 16 installation milestones and all
    9 lifecycle checks.
  - The plain installation stopped after 11 milestones. A single
    `cybexos-runtime ipc welcome status` call exceeded the runtime's 2-second
    IPC limit while the welcome guide was stepping aside for Settings. The
    diagnostics collected straight afterwards showed the guide open and
    aside, IPC answering, no QML warnings in the shell's invocation, no failed
    units and no Hyprland configuration errors.

    The guide had already started its own system check at first login, so
    opening Home started no second one. Measured on the host, opening Home
    never delayed the shell's IPC by more than 29 ms. beta.9's first attempt
    stopped in the same way, and a re-run of the same source passed.
- **Re-run of the plain case (`--case plain`) on the identical ISO** passed
  all 16 milestones and all 9 lifecycle checks.

Both cases thus have a full pass on this exact image: 50 results with the
installed release identity at `1a9b62b`. The milestones and lifecycle checks
are the same as for beta.15. On both installed desktops, under real Hyprland:

- `cybexos-runtime ipc settings open shortcuts` opened the Keyboard page on
  its Shortcuts tab;
- the welcome guide stepped aside for Settings opened on Home and resumed;
- the qualifier's screenshots show Home's identity line ("Cybex OS
  1.0.0-beta.16 · NixOS 26.05"), its storage, memory, backups and network
  strip, and "Personal files aren't backed up" under Needs attention.

The qualifier now checks the page and tab (`settings status` reports `tab`),
and opens `home` where it opened `about`.

Not exercised:

- applying a regional change and restarting into it. The VM test prepared and
  discarded the combined candidate; the apply, trial boot and confirmation
  path is the same as for any local deployment, which the lifecycle checks
  cover;
- the Changes sheet applying real touchpad or keyboard drafts on an installed
  desktop. The headless harness's fake `hyprctl` cannot apply input settings,
  and the sheet reported that correctly;
- recovery-point cleanup through the sheet;
- physical hardware, Secure Boot, physical PXE boot and signed-channel
  updating.

Known cosmetic issue: after an IPC or palette jump, keyboard focus and its ring
stay on the rail entry that had focus, rather than moving to the newly current
page.

## PXE delivery and cleanup

The image and its SHA-256 sidecar were copied and verified outside the served
tree, then moved in without overwriting, with mode 0644. beta.14 and beta.15
and their checksums stayed unchanged. The served checksum and a full HTTP
download matched.

iVentoy's refresh returned success, its status was running, and the image tree
lists `cybexos-1.0.0-beta.14.iso`, `cybexos-1.0.0-beta.15.iso` and
`cybexos-1.0.0-beta.16.iso`. `iventoy.service` stayed active, and no restart
was needed.

The qualification leases `155122d78e5f41039afa5c1f1a2d96cb` and
`b57300c410474854888093b2716a5e8c` and the VM test leases closed with nothing
remaining. Task staging under `/data/tmp` was removed after this record:
qualification disks, screenshots, logs, harness screenshots, the parity
staging and the VM test output.

The final image output
`/nix/store/khssra02xghmfsz5dh6ach92kxw7h3s1-cybexos-1.0.0-beta.16-x86_64-linux.iso`
and successful check outputs remain in the Nix-managed build cache.
