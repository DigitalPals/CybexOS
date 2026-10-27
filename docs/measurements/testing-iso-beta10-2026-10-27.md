# Beta.10 testing ISO: Software Update — 2026-10-27

Beta.10 replaces the System updates popover with the **Software Update** app
and adds background preparation and automatic restart confirmation. See
[updates](../updates.md) for the behavior contract.

## Change

- **The app.** `SoftwareUpdateWindow.qml` and `SoftwareUpdate/` provide one
  page per updater state. Four entry points open it:
  - the menubar indicator;
  - Control Center's **Review** button;
  - the launcher, both the desktop entry and the action;
  - `cybexos-software-update`.

  `UpdatesPopover.qml` and its panel registration were removed.
- **The readable review.**
  - Each installed system declares component versions in
    `/etc/cybexos/components.json`: Cybex OS, NixOS, kernel,
    Mesa/NVIDIA, firmware and Hyprland.
  - The worker groups a prepared change into `highlights`: components, apps
    with visible `.desktop` entries, programs without a window, and a count of
    background components. The review token covers this grouping.
- **Machine policy.** `/var/lib/cybexos/update-automatic.json`, changed with
  `cybex update automatic prepare|confirm on|off`. Both settings default to on.
- **The units.**
  - `cybexos-update-auto.service` (with a timer) submits an ordinary `stage`
    request. It acts only when the updater is idle or done, runs only on AC
    power, skips metered networks, and prepares each target once.
  - `cybexos-update-confirm.service` submits `confirm` when the system is
    awaiting login.
  - A polkit rule lets an active local `wheel` session start only these two
    units without a password.
- **Failures.** `cybex update discard` now also dismisses failed, interrupted
  and rolled-back states. Their files and logs are kept.

## Artifact and source

- PXE host: `thebeast` (`10.10.0.7`).
- Image: `/data/pxe/iso/cybexos-1.0.0-beta.10.iso`.
- Size: 7,120,576,512 bytes (6.63 GiB).
- SHA-256: `d9f1fd19925fdcba8d6d186cc5b1d2ee64ae90f5b60d2f903eac58f6fc732378`.
- Frozen source: `/nix/store/817li02sblkz5jzkpb7klcyszawkhdjf-source`.
- Source NAR: `sha256-u4GExjHvSgkUmJ+amXojL45i314xm6nGAK/V9kNdTf0=`.
- Embedded release: `1.0.0-beta.10`, revision `uncommitted`, NixOS 26.05.
- ISO output: `/nix/store/nsa7ngzk6a372l4dyjaqqfn3nffx3vw5-cybexos-1.0.0-beta.10-x86_64-linux.iso`.
- Shared contract: `/nix/store/yp92vgqhyknj58lzp6p4bp8p8y53w0fj-cybexos-shared-installation-contract.json`.

The ISO, shared-contract check, staged-updater VM driver and installation
qualification used this one source identity. The qualifier itself received two
harness-only fixes after the freeze; it runs on the host and is not part of the
image:
- it retries a base64 installer-state read that serial-console text corrupted;
- it reads the auto unit's JSON result line rather than systemd's
  `Finished…` line.

This record was written after the freeze and is not bundled. No signed public
release was published.

## Checks actually exercised

**Source and build:**
- `tests/run` passed in the development shell: 667 Python, 1,460 Node and the
  native-helper suites. `tests/qml-lint` passed for 432 QML files and four
  harnesses. Its 8 warnings are the existing ones; none come from the new
  files.
- `tests/update-flow.py` passed. It runs the real packaged Quickshell under
  private headless Sway, with scripted `cybex`, `systemctl` and session-action
  boundaries, so it starts no system unit and never reboots the host. It
  covered:
  - the menubar and Control Center opening the window;
  - authorization cancellation;
  - durable worker failure across a shell restart;
  - the readable review (three components and one app);
  - a single install;
  - **Restart Now** reaching the session action;
  - automatic confirmation starting the confirm unit exactly once;
  - manual confirmation after a failed or disabled automatic one;
  - the automatic-download switch;
  - background preparation waiting for the settle period or an explicit
    check, then requested once;
  - a discovery error, recovery and dismissal pages.

  Screenshots in dark and light themes were reviewed.
- The ISO build, shared installation-contract check, and
  `scripts/check-image-parity` passed. Parity covered all 41 source, image and
  package comparisons against the frozen source.

**NixOS VM** (`checks.x86_64-linux.vm`, frozen source, 155.7 s): passed. It
covered:
- the component manifest against `uname -r` and `nixos-version`;
- the default policy as an unprivileged user;
- the active timer and the installed polkit rule;
- an inactive `runuser` session being denied the unit start;
- policy changes with mode 0644;
- the auto unit skipping when `disabled` or `ready`;
- the confirm unit skipping when `idle`;
- a real software stage publishing `highlights` without store paths.

**Installed-system qualification**
(`scripts/qualify-installations --interactive --applications minimal
--scenario lifecycle`), plain install: passed.
- **Installation:** real tty1 installer, installed boot, GRUB and quiet boot.
- **First login:** desktop health, welcome guide, keyboard shortcuts, real
  Polkit/PAM prompts for SSH and updater staging, and two password-change
  reboots.
- **Fresh policy:** the fresh installation reported the
  `{"prepare": true, "confirm": true}` default. The run then turned
  preparation off for determinism.
- **Background preparation** (`automaticPreparation`): started from the
  installed system against a real newer Nixpkgs (`da6dc0e` → `718f670`).
  - It submitted `stage upstream` and reached `ready`.
  - Its review listed the NixOS build change (21 Oct → 26 Oct 2026), two
    programs without a window and one background component.
- **Automatic confirmation:** for the personal baseline and the local
  candidate, the signed-in desktop's Quickshell started
  `cybexos-update-confirm.service` through the session polkit rule. The
  resulting `confirm` request passed health and committed the boot default;
  the qualifier never ran `cybex update confirm`.
- **Unconfirmed trial:** with the confirm policy off, an unconfirmed trial
  boot fell back to the previous generation.
- **Other lifecycle checks:** evaluation and build failures, interrupted
  staging, rollback and personal persistence passed.

**Installed-system qualification, encrypted install:** passed. It covered:
- the same milestones as the plain install, using SDDM automatic login after
  disk unlock;
- the same lifecycle checks;
- automatic confirmation after automatic login. The qualifier accepts that
  this can finish before its first status poll.

An earlier combined run failed before any update operation:
- the plain install hit the serial base64 read flake, fixed above;
- the encrypted lifecycle hit the journal-line parsing bug, fixed above. Its
  installed status already showed the auto unit's upstream `stage` request
  building.

A rerun of the encrypted case then stopped at discovery on GitHub's
unauthenticated API rate limit. That is an external quota, reported
accurately. It passed after the limit reset.

## Limits

- The Software Update window was exercised in the headless Sway test, not
  clicked on the installed Hyprland desktop. The installed runs covered its
  backend units and the shell's confirmation trigger.
- Background preparation's AC-power and metered-network conditions are unit
  and fixture tested. A battery-powered or metered machine was not used.
- Signed Cybex OS channel delivery, physical hardware, Secure Boot and physical
  PXE boot were not qualified.

## Delivery and cleanup

The served file and its checksum sidecar matched:
- in the staging directory, on the same filesystem;
- after an atomic move into `/data/pxe/iso`;
- after a complete HTTP download from
  <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.10.iso>.

A complete copy briefly existed in the served directory as a hidden
`.partial` file. It was removed before the iVentoy refresh, and the delivered
file was moved in atomically. iVentoy refresh returned `result: success`, its
status returned `running`, and the image tree listed beta.7 to beta.10.
`iventoy.service` was active. Beta.7, beta.8 and beta.9 were preserved.

All eight task leases (VM tests and qualification runs) were checked closed,
with no errors or preserved volumes. Their workspaces, VM disks and logs were
removed. The following were deleted:
- task scratch directories under `/data/tmp`: build and test logs, parity
  extraction, UI and qualification screenshots, and qualification JSON;
- intermediate driver and ISO result links.

No task-owned mounts, VMs or developer Quickshell processes remain. This task
created nothing in `~/.local/share/cybexos/images`. Normal content-addressed
Nix outputs remain under Nix's management.

Retained deliverables:
- the beta.10 ISO (7,120,576,512 bytes) and its 92-byte checksum;
- the repository changes and this record.
