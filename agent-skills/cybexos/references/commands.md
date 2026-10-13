# Commands and desktop helpers

Prefer installed commands over reconstructed shell pipelines. On RPM systems,
packaged command sources live under `/usr/share/cybexos`; on source-checkout
systems, inspect the active release under `~/.local/share/cybexos/current` or
run help before using an unfamiliar option.

## CybexOS

- `cybex version` reports the active desktop release.
- `cybex doctor --json` runs read-only installed-system diagnostics.
- `cybex update-channel status --json` reports the configured RPM update
  channel. This does not start an update.
- On source-checkout installations, `cybex update --check` checks the
  configured release channel. ISO installations use
  `cybex update-channel status --json` for read-only RPM channel status;
  `cybex update --check` is not supported there.
- `sudo /usr/libexec/cybexos-reconcile --status` inspects pending versioned
  account and machine policy reconciliation; `--retry` requests a retry.
  RPM upgrades defer that work to `cybexos-reconcile.service` and its timer.
- On source-checkout installations, `cybex verify` and `cybex doctor` provide
  installed checks; add `--source` only when repository/developer checks are
  intended.
- `cybexos-update-run status --json`, `log-dir`, and `read-log` inspect a
  durable source-checkout update without starting one.

A public RPM channel is enabled only after reviewing and verifying its public
configuration and key fingerprint. The explicit enrollment command is:

```bash
sudo cybex update-channel enroll /path/to/public.json \
  --fingerprint FULL_OPENPGP_PRIMARY_FINGERPRINT
```

Add `--check` to validate the channel without enabling it. The default public
configuration path is `image/channels/stable.json` in the source tree. Enrollment
pins the public key and signed metadata before updates are enabled. Never use a
private signing key on the installed workstation.

An actual `cybex update`, `configure`, `install`, or `uninstall` needs explicit
user intent. So do update cancellation, reboot, shutdown, and recovery/reset
operations. Do not infer authorization from a request to diagnose or check
status.

## Desktop actions

These commands act in the user's graphical session. A direct request for the
corresponding action supplies intent; otherwise explain the command rather
than launching an interactive selector or sending data.

- `screenshot` selects a region, saves it under `~/Pictures/Screenshots`, and
  copies it. `screenshot fullscreen` captures the focused monitor.
- `screen-record` toggles a selected-region recording. The first call starts;
  the next call stops and saves under `~/Videos/Screen Recordings`.
- `screen-ocr` selects a region and copies recognized English text to the
  clipboard.
- `quickshell-reminder add MINUTES [MESSAGE]` schedules a persistent reminder.
  Use `list --json`, `cancel ID`, or `clear` for management.
- `localsend` launches the LocalSend Flatpak. `localsend-share clipboard`,
  `localsend-share file [PATH...]`, and `localsend-share folder [PATH...]`
  send through its headless interface; omitted paths open an interactive
  chooser.

Screen capture, recording, OCR, reminders, and LocalSend are user-visible or
externally consequential. Report cancellation or command failure accurately;
do not retry a send, capture, or reminder creation unless the first attempt is
known not to have completed.
