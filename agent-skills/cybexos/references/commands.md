# Commands and recovery

- `cybex update check`: independent upstream and authenticated Cybex OS status.
- `cybex update stage upstream|cybexos|both|local`: build and validate a staged
  complete configuration, preserving the working configuration.
- `cybex update status`: durable progress, actual closure changes, errors,
  restart needs, transaction ID and review token.
- `cybex update apply ID TOKEN`: supervised activation of the reviewed build.
- `cybex update confirm`: after an explicit reboot and authenticated desktop
  login, check boot/services/Hyprland/Quickshell and retain the known-good system.
- `cybex update history`: retained deployment identities and recovery state.
- `cybex update rollback [ID]`: restore the pending or selected deployment's
  previous system and configuration. No automatic reboot or application-data
  rollback is implied.
- `cybex plugin ...`, `cybex theme ...`, `cybex shell ...`: persistent desktop
  extensions, themes and diagnostics.

Read the error and transaction status before retrying. Interrupted staging
retains the working system. Interrupted activation is recovered at boot. A trial
boot leaves the previous generation as the persistent boot default until fresh
boot and login health pass. If a trial fails before userspace, reboot and choose
the previous generation; automatic reboots are disabled. Boot the installation
ISO for offline recovery if the firmware cannot find a retained generation.

Persistent credentials, NetworkManager profiles, databases and widget data
remain in place through rollback. Back up and test explicit data migrations
before a future service/schema change; rolling system code back does not undo
data writes. Do not downgrade a database or rewrite an unknown newer schema.

Use the user's normal desktop commands for screenshots (`screenshot region`),
recording (`screen-record`), OCR (`screen-ocr`) and file sharing (`localsend-share`).
Do not capture or transmit private material without an authorized task.
