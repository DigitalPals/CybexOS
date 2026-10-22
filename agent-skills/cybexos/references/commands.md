# Commands and desktop helpers

Prefer installed commands over reconstructed shell pipelines. On RPM systems,
packaged command sources live under `/usr/share/cybexos`; on source-checkout
systems, inspect the active release under `~/.local/share/cybexos/current` or
run help before using an unfamiliar option.

## CybexOS

- `cybex version` reports the active desktop release; `cybex doctor --json`
  runs read-only installed-system diagnostics (on checkouts, `cybex verify`
  too; add `--source` only for repository/developer checks).
- `cybex update-channel status --json` reports the RPM update channel. On
  checkouts, `cybex update --check` checks the release channel instead; ISO
  installations do not support it. Neither starts an update.
- `sudo /usr/libexec/cybexos-reconcile --status` inspects pending account and
  machine policy reconciliation after RPM upgrades; `--retry` requests a retry.
- `cybexos-update-run status --json`, `log-dir`, `read-log` and
  `history --json` (finished updates with the recovery point, `snapshotId`,
  each took) inspect the durable updater without starting one.
- `cybexos-runtime ipc updates check` refreshes the desktop's update check;
  `cybexos-runtime ipc updates open` opens the Updates view. Neither installs.
  `systemctl is-enabled cybexos-update-download.timer` shows whether
  background downloads are on (off by default; changing it is a Settings
  choice that asks for authorization).
- `cybex report --json --no-browser` writes a redacted diagnostic bundle
  (`cybexos-report-*.tar.gz`; `--output` picks the path) and prints its
  summary. It uploads nothing; the user reviews and attaches the file.
- `/usr/local/libexec/cybexos-nvidia status` prints the NVIDIA driver state
  (`ready`, `reboot`, `enroll`, `failed`). Never print
  `/var/lib/cybexos/nvidia-mok.json`: it holds the one-time Secure Boot
  enrollment password.
- `cybex factory-reset` (ISO installations only) erases every account and home
  folder for a new owner. It is destructive and interactive (typed
  confirmation, sudo): only on an explicit request, after suggesting
  `cybex backup now`. On a checkout it only explains it is unavailable.

Enable a public RPM channel only after verifying its public configuration and
key fingerprint (`image/channels/stable.json` in the source tree; add
`--check` to validate without enabling). Never use a private signing key on
the workstation:

```bash
sudo cybex update-channel enroll /path/to/public.json \
  --fingerprint FULL_OPENPGP_PRIMARY_FINGERPRINT
```

An actual `cybex update`, `configure`, `install`, or `uninstall` needs explicit
user intent. So do update cancellation, reboot, shutdown, and recovery/reset
operations. Do not infer authorization from a request to diagnose or check
status.

## Backups

`cybex backup` drives encrypted personal-file backups (restic), the same
helper as Settings → Backup & recovery. `status --json` (read-only, no
restic), `snapshots --json` (may ask to unlock the keyring) and `excludes`
(extra patterns go in `~/.config/cybexos/backup-exclude`) only inspect.
Steam userdata, Proton prefixes and rootless container volumes are included;
downloaded games, container images and writable layers are excluded. Live
database files are not a consistent export: use the application's dump/backup
tool into a backed-up home folder, or stop it for the whole backup. System
stores and separately mounted filesystems are outside this home backup.
`setup`, `now`, `restore`, `automatic`, `recovery-key` and `confirm-key` need
explicit user intent. `restore` writes only into a new folder under
`~/Restored`. Never ask for, print, store, or copy a recovery key or the
keyring password; `setup` and `recovery-key` show a new key once, to the user.

## Desktop actions

These commands act in the user's graphical session. A direct request for the
corresponding action supplies intent; otherwise explain the command rather
than launching an interactive selector or sending data.

- `screenshot` selects a region (or a window, with a click), saves it under
  `~/Pictures/Screenshots` and copies it; `screenshot fullscreen` captures the
  focused monitor. `screenshot scroll` captures a region while the user
  scrolls and saves one stitched image when they press Enter, Escape or the
  shortcut again (`screenshot scroll-stop` finishes, never starts, one).
- `screen-record` toggles a region recording, saved under
  `~/Videos/Screen Recordings`; `--webcam` adds a camera preview to the
  recorded area, and `--encoder` prints the encoder a recording would use.
- `screen-ocr` copies a QR code or barcode's content in a selected region,
  or else its English text. It never opens a decoded link.
- `color-picker` lets the user click a pixel and copies its hex colour.
- `quickshell-reminder add MINUTES [MESSAGE]` schedules a persistent reminder;
  `list --json`, `cancel ID` and `clear` manage them.
- `cybex webapp list --json` lists web apps. `install --url URL [--name NAME]
  [--id ID]` adds one (http/https without credentials; `--offline` uses a
  generated icon), `remove ID` removes one for good, `launch ID` opens one.
  The defaults are `slack`, `whatsapp`, `youtube`, `google-photos` and `x`.
- `cybex theme list --json` lists appearance themes; `apply ID` sets mode,
  accent, bar colour and font (and a theme's wallpaper) at once; `export
  ID|CURRENT [DIR] [--name NAME]` writes a shareable folder or `.tar.gz`;
  `install SOURCE` accepts a folder, archive or `https://` Git URL holding
  only data; `remove ID` deletes a user theme. Make a theme in
  `~/.local/share/cybexos/themes/<id>/theme.json` (schema in
  docs/shell-appearance.md#themes), not by editing shell.json theme keys.
- `game-mode status [--json]` reports game mode; `on`, `off` and `toggle`
  turn effects, rounding, gaps and idle locking off until it is turned off or
  the session ends. It notifies on every change.
- `cybexos-runtime ipc launcher open PROVIDER` opens the launcher on a tab
  such as `clipboard` or `actions`; `cybexos-runtime ipc overview toggle`
  (or `open`, `close`) shows the window overview, as `Super+Tab` does.
- `localsend` launches the LocalSend Flatpak. `localsend-share clipboard`,
  `localsend-share file [PATH...]` and `localsend-share folder [PATH...]` send
  through its headless interface; omitted paths open an interactive chooser.

Screen capture, recording, OCR, colour picking, reminders, web app changes and
LocalSend are user-visible or externally consequential. Report cancellation or
command failure accurately; do not retry a send, capture, or reminder creation
unless the first attempt is known not to have completed.

## Sign-in factors

Fingerprints and FIDO2/U2F security keys are managed in Settings → Security
(`cybexos-runtime ipc settings open security`). Enrolment needs the person at
the reader or key, so open the page rather than running `fprintd-enroll` or
`pamu2fcfg` for them. The sudo, Polkit and lock-screen PAM steps belong to
`cybexos-auth-policy` (docs/security.md); do not hand-edit `/etc/pam.d` or
enable authselect's `with-pam-u2f`, which would also reach the login screen.
