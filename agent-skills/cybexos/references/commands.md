# Commands and desktop helpers

Prefer installed commands over reconstructed shell pipelines. Read their
active source under `~/.local/share/cybexos/current` or run their help
before using an unfamiliar option.

## CybexOS

- `cybex version` reports the active release.
- `cybex verify` and `cybex doctor` run non-destructive
  installed-system checks. Add `--source` only when repository/developer checks
  are intended.
- `cybex update --check` checks the configured release channel.
- `cybexos-update-run status --json`, `log-dir`, and `read-log` inspect a
  durable update without starting one.

An actual `cybex update`, `configure`, `install`, or `uninstall` needs
explicit user intent. So do `cybexos-update-run cancel`, reboot,
shutdown, and recovery/reset operations. Do not infer authorization from a
request to diagnose or check status.

## Desktop actions

These commands act in the user's graphical session. A direct request for the
corresponding action supplies intent; otherwise explain the command rather
than launching an interactive selector or sending data.

- `screenshot` selects a region, saves it under `~/Pictures/Screenshots`, and
  copies it. `screenshot fullscreen` captures the focused monitor. A
  notification offers Satty editing.
- `screen-record` toggles a selected-region recording. The first call starts;
  the next verified call stops and saves under `~/Videos/Screen Recordings`.
- `screen-ocr` selects a region and copies recognized English text to the
  clipboard.
- `quickshell-reminder add MINUTES [MESSAGE]` schedules a persistent reminder.
  Use `list --json`, `cancel ID`, or `clear` for management. Convert natural
  language durations to a positive whole number of minutes and preserve the
  user's message.
- `localsend` launches/passes arguments to the LocalSend Flatpak.
  `localsend-share clipboard`, `localsend-share file [PATH...]`, and
  `localsend-share folder [PATH...]` send through its headless interface;
  omitted paths open an interactive chooser.

Screen capture, recording, OCR, reminders, and LocalSend are user-visible or
externally consequential. Report cancellation or command failure accurately;
do not retry a send, capture, or reminder creation unless the first attempt is
known not to have completed.
