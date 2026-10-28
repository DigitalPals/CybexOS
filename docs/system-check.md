# System check

`cybex doctor` is a read-only check of this computer. It looks for missing
drivers, failed services, missing sound output, low disk space, worn
batteries, unsynchronized clocks, desktop errors and available firmware
updates, and explains each finding in one line. It needs no AI account: the
welcome guide runs it locally, and the Cybex OS Assistant runs it before
explaining problems and proposing fixes.

```sh
cybex doctor          # a short readable report, problems first
cybex doctor --json   # the machine-readable report below
```

It runs as the desktop user: no administrator rights, no network access (fwupd
answers from its downloaded metadata) and no writes. Every probe has its own
time limit, all run at once, and the whole report waits at most about twelve
seconds. A probe that fails or times out becomes `unknown`. The exit status is
0 whenever the check ran, whatever it found, and 2 for a usage error. The check
does not qualify hardware or change anything; a passing check is not evidence
that a device is supported.

## What it checks

States: `problem` needs attention, `suggestion` is worth doing, `ok` is fine,
`info` is context and `unknown` could not be checked. Checks are conservative,
so a fresh installation should not show a problem.

| id | Looks at | Not `ok` when |
| --- | --- | --- |
| `graphics` | Display controllers (PCI class 03) and their kernel driver, from sysfs; names from `lspci` | A GPU has no driver (`problem`); an NVIDIA GPU runs `nouveau` or no driver (`suggestion`, the NVIDIA driver is the explicit `cybexos.hardware.nvidia` choice); the NVIDIA driver is selected but not in use (`problem`, or `suggestion` when only a restart is missing) |
| `drivers` | PCI network, storage, sound, multimedia, USB, Thunderbolt and SD-reader functions; USB Bluetooth, camera and audio interfaces | Any has no kernel driver (`problem`). Bridges, signal processing, system peripherals, vendor-specific devices such as fingerprint readers, SR-IOV functions, USB device-mode controllers and AMD's audio coprocessor (which declines machines without digital microphones) are not flagged |
| `firmware-files` | "Direct firmware load … failed" and "failed to load … firmware" lines in this boot's kernel log | Always `info` when files are missing: drivers often probe several versions. `unknown` if the journal is not readable |
| `services` | `systemctl --failed` for the system and the desktop user | Any failed unit (`problem`) |
| `audio` | PipeWire's PulseAudio sinks (`pactl`, addressed at the running server so none is started) | Sound hardware exists but only a placeholder output (`problem`); no sound hardware at all is `info` |
| `secure-boot` | UEFI or legacy mode, `SecureBoot`/`SetupMode` EFI variables (or `bootctl status`) | Secure Boot off is the current Cybex OS installation and is `info`, never a problem; legacy BIOS is `info` |
| `firmware-updates` | `cybexos-firmware-update plan` (fwupd, cached metadata) | Updates available (`suggestion`) |
| `storage` | Free space on `/`, and on `/home` and `/nix` when separate | Under 5 % or 5 GiB free (`problem`), under 15 % (`suggestion`) |
| `battery` | `/sys/class/power_supply/BAT*` full-charge against design capacity | Under 60 % (`suggestion`); no battery is `ok` |
| `time` | `timedatectl` NTP state, NetworkManager connectivity, uptime | Automatic time off, or unsynchronized after 15 minutes online (`suggestion`); offline or just booted is `info` |
| `desktop` | `hyprctl -j configerrors`, `cybex shell status` | Hyprland configuration errors or the shell in safe mode (`problem`); outside a Hyprland session it is `unknown` |

## Privacy

The report contains device model names, PCI/USB vendor:device IDs, PCI slots,
kernel driver names, firmware file names, systemd unit names and sizes. It is
built not to contain serial numbers, MAC or IP addresses, hostnames, network
names, user names, home paths or the machine ID: those are never read where a
check can avoid them, and anything taken from another program's text (unit
names, Hyprland errors) is scrubbed to placeholders such as `[user]`,
`[hostname]`, `[mac]`, `[uuid]` and `~`. Bluetooth outputs are listed as
"Bluetooth audio device", because their names are often the owner's.

Nothing leaves the computer. The welcome guide reads the report locally. When
the person asks the assistant to check the computer, the assistant runs the
same command and sends its output to their AI provider as part of that
conversation.

## JSON

```json
{
  "version": 1,
  "checkedAt": "2026-10-28T12:00:00Z",
  "overall": "ok" | "suggestion" | "problem",
  "counts": {"problem": 0, "suggestion": 1, "ok": 7, "info": 1, "unknown": 2},
  "checks": [
    {"id": "graphics", "state": "ok" | "suggestion" | "problem" | "info" | "unknown",
     "title": "Graphics", "summary": "one English line", "detail": "English, may be empty",
     "facts": { "...": "structured data for the assistant" }}
  ],
  "scope": "Read-only checks of this computer. They do not qualify hardware or change anything."
}
```

`checks` always holds every id exactly once, in this order: `graphics`,
`drivers`, `firmware-files`, `services`, `audio`, `secure-boot`,
`firmware-updates`, `storage`, `battery`, `time`, `desktop`. `overall` is
`problem` if any check is a problem, else `suggestion` if any is a
suggestion, else `ok`; `info` and `unknown` never raise it. `summary` and
`detail` are English sentences for people; `facts` is for the assistant and
may gain keys:

| id | `facts` |
| --- | --- |
| `graphics` | `gpus: [{name, vendorDevice, driver, slot}]`, `nvidiaDriverSelected: bool \| null`, `restartPending: bool` |
| `drivers` | `missing: [{bus: "pci" \| "usb", kind, name, vendorDevice, class?, slot?}]` |
| `firmware-files` | `readable: bool`, `missing: [{driver, file, error}]` |
| `services` | `system: [unit] \| null`, `user: [unit] \| null` (`null`: that service manager did not answer) |
| `audio` | `soundCards: int`, `outputs: [{description, bus, state}]` |
| `secure-boot` | `mode: "uefi" \| "legacy"`, `secureBoot`, `setupMode: bool \| null`, `bootLoader: "grub" \| "systemd-boot" \| null` |
| `firmware-updates` | `updates: [{name, vendor, from, to, needsReboot}]` |
| `storage` | `filesystems: [{mount, sizeBytes, freeBytes, freePercent, state}]` |
| `battery` | `batteries: [{name, capacityPercent, cycleCount, model, manufacturer, status, chargeLimit}]` |
| `time` | `ntpEnabled`, `ntpSynchronized`, `connectivity`, `uptimeMinutes` |
| `desktop` | `hyprland: {session, configErrors: [text] \| null}`, `shell: {safeMode: bool \| null, reason}` |

A check that crashed or missed the deadline reports `unknown` with a generic
summary (and `facts.error`, the exception type, for a crash).

## The assistant

The assistant's approval policy treats `cybex doctor` and `cybex doctor --json`
as read-only, so they run without a card. A turn the shell starts with
`context.purpose: "system-check"` tells the agent to run the check first,
follow the skill's [system check reference](../agent-skills/cybexos/references/system-check.md),
explain the findings most important first, and change nothing until the
person agrees (see [the assistant protocol](assistant.md#protocol)). Fixes go
through the normal lifecycle: personal declarations in `/etc/nixos/local`,
`cybex update stage local`, the review card, `cybex update apply`; firmware
through the Update drawer's firmware action.

## Tests

`tests/nixos/test_doctor.py` runs the helper against fixture sysfs, `/etc`,
`/run` and `/proc` trees and stub commands: each check's states, the JSON
shape and order, `overall`/`counts`, command and probe timeouts, privacy
(a planted hostname, user name, MAC, IP, UUID, machine ID and serial numbers
never appear) and the `cybex doctor` dispatch. The desktop package's install
check runs `cybexos-doctor --json` in the build sandbox, where nearly every
check is `unknown`. Neither is a check on real hardware.
