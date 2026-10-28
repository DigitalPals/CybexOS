# System check

`cybex doctor --json` is a read-only snapshot of this computer: no root, no
network, no writes. Run it first, then explain the result in plain words,
most important first. `problem` needs attention, `suggestion` is worth doing,
`info` and `unknown` are context, not faults. Keep a reply that will be read
aloud to the problems and suggestions. A finding is not hardware
qualification: never say a device, driver or model is qualified or fully
supported because a check passed.

Propose fixes and wait for the person's agreement before changing anything.
Every system change follows the skill's lifecycle: a narrowly scoped module in
`/etc/nixos/local/` imported from `local/default.nix`, `cybex update stage
local`, the review card from `cybex update status`, then `cybex update apply
TRANSACTION REVIEW_TOKEN`. Desktop preferences stay in `~/.config/cybexos`.
Never use sudo, `nixos-rebuild`, `systemctl reset-failed` or a vendor file
edit to make a check pass, and never restart the computer; say when a restart
is needed. `cybex doctor`, `lspci`, `lsusb`, `lsblk`, `df`, `systemctl
status`, `journalctl` and `hyprctl -j configerrors` run without a card; other
commands ask the person first.

Each check has `id`, `state`, `summary`, `detail` and `facts`. Facts never
contain serials, addresses, hostnames, user names or home paths; `[user]`,
`[hostname]`, `[uuid]` and `[device]` are placeholders, so query the real name
locally (for example `systemctl --failed`) instead of using it.

## graphics

`facts.gpus` lists `{name, vendorDevice, driver, slot}`;
`facts.nvidiaDriverSelected` is whether the running configuration selects the
NVIDIA driver (from `/etc/cybexos/components.json`), `facts.restartPending`
whether the installed system selects it but this boot predates it.

- A GPU with no driver (`problem`): `journalctl -k -b | grep -iE 'drm|amdgpu|i915|xe'`.
  Report it with `cybex report` if a supported GPU fails.
- NVIDIA on `nouveau` or no driver (`suggestion`): the NVIDIA driver is an
  explicit machine choice. The installer writes `cybexos.hardware.nvidia`,
  `hardware.nvidiaOpen` and, on hybrid laptops, `hardware.nvidiaPrime` into
  `/etc/nixos/machine.nix`; read it first
  (`grep -n nvidia /etc/nixos/machine.nix`). A GPU added after installation
  leaves `hardware.nvidia = false` there, so a personal module overrides that
  deliberate choice with `mkForce`, for example `/etc/nixos/local/nvidia.nix`:

  ```nix
  { lib, ... }: {
    cybexos.hardware.nvidia = lib.mkForce true;
    # Open kernel module (default): Turing (GTX 16, RTX 20) or newer.
    # Maxwell, Pascal or Volta need the proprietary module instead:
    # cybexos.hardware.nvidiaOpen = lib.mkForce false;
    # Hybrid laptop with exactly one Intel or AMD GPU beside the NVIDIA one:
    # cybexos.hardware.nvidiaPrime = { enable = true; intelBusId = "PCI:0:2:0"; nvidiaBusId = "PCI:1:0:0"; };
  }
  ```

  Import it from `local/default.nix`, stage, review and apply; the person
  restarts afterwards. PRIME bus IDs come from `facts.gpus[].slot`
  `0000:BB:DD.F` as decimal `PCI:B:D:F` (`0000:c1:00.0` is `PCI:193:0:0`);
  use `amdgpuBusId` for an AMD integrated GPU and only domain `0000`. Without
  PRIME, the NVIDIA GPU drives the desktop. The driver's userspace is unfree;
  selecting it permits only the NVIDIA packages. NVIDIA support is declared,
  not qualified on representative GPUs; say so.
- NVIDIA selected but not in use (`problem`): `journalctl -k -b | grep -iE
  'nvidia|nvrm'`. An older GPU rejected by the open module needs
  `cybexos.hardware.nvidiaOpen = lib.mkForce false;`. With
  `facts.restartPending` the state is a `suggestion`: only a restart is needed.

## drivers

`facts.missing` lists PCI network, storage, sound, multimedia, USB,
Thunderbolt and SD-reader functions and USB Bluetooth, camera and audio
interfaces with no kernel driver. Identify the device with `lspci -nnk -s
SLOT` or `lsusb -d VENDOR:DEVICE` and look for its driver in the kernel log.
If NixOS packages an out-of-tree driver for it (a
`config.boot.kernelPackages.*` module such as `broadcom_sta`), propose a
personal module with `boot.extraModulePackages` and `boot.kernelModules`, and
scope any unfree or insecure permission to that package. Never unbind or
blacklist a working driver to make the check pass. Fingerprint readers
(vendor-specific USB class) are driven by `fprintd`, not a kernel driver, and
are not listed.

## firmware-files

Always `info`. `facts.missing` lists `{driver, file, error}` from this boot's
kernel log. Drivers probe several versions (iwlwifi, amdgpu) and
`regulatory.db` is optional, so explain it only when that device misbehaves.
`hardware.enableRedistributableFirmware` is already on; a missing file the
device needs means newer `linux-firmware`, which arrives with
`cybex update stage upstream`. `unknown` means the journal is not readable.

## services

`facts.system` and `facts.user` list failed units (`null`: that manager did
not answer). Dig in with `systemctl status UNIT --no-pager` and `journalctl -b
-u UNIT --no-pager -n 100` (`--user` for desktop units). A failing personal
service is fixed in its own `/etc/nixos/local` module and staged; a failing
vendor unit is reported with `cybex report` instead of editing vendor files.
Restarting a desktop unit (`systemctl --user restart UNIT`) is an action that
needs the person's approval; system units need the administrator.

## audio

`problem` means sound hardware exists but only a placeholder output is
offered. Check `systemctl --user status pipewire wireplumber`, `journalctl
--user -b -u wireplumber` and `journalctl -k -b | grep -iE 'snd|sof'`. A
missing SOF firmware or topology appears in `firmware-files`. `unknown` means
the sound server is not reachable from this process. Bluetooth outputs are
shown as "Bluetooth audio device" to keep the person's device names private.

## secure-boot

Cybex OS currently installs without Secure Boot (`docs/hardware-security.md`):
`info` with `secureBoot: false` is the expected state. Never advise turning
it on in the firmware: the GRUB boot loader (`facts.bootLoader: "grub"`) is
unsigned and the computer would not start. Do not offer key enrollment;
signed media and enrollment are not yet qualified. Legacy BIOS mode is `info`.

## firmware-updates

From fwupd's cached metadata (`cybexos-firmware-update plan`); nothing is
downloaded. `facts.updates` lists `{name, vendor, from, to, needsReboot}`.
Installation uses the Update drawer's firmware action, which runs
`cybexos-firmware-update interactive` in a terminal: it refreshes metadata,
shows the plan and asks for confirmation. Firmware writes are outside Nix
generations and are not undone by a rollback; capsule updates finish during
the next restart. Do not run `fwupdmgr update` yourself.

## storage

`facts.filesystems` gives size, free bytes and percentage for `/`, and for
`/home` or `/nix` when separate. Below 5 % or 5 GiB is a `problem`, below
15 % a `suggestion`. Settings → Storage & cleanup reviews which old system
versions can go (`cybex maintenance status` is read-only; the cleanup preview
asks for administrator authentication). Never run `nix-collect-garbage` or
delete store paths. Suggest `du -sh ~/Downloads
~/.cache ~/.local/share/Trash` to find personal space, and delete personal
files only on request.

## battery

Capacity is `energy_full / energy_full_design` (or `charge_*`): the battery
menu's Capacity (Wh) against the design value. Below 60 % is a `suggestion`: normal wear,
not a fault. `chargeLimit` is the firmware charge threshold, which the
battery menu's Battery health switch manages through UPower when supported.
No battery is `ok`.

## time

`suggestion` when automatic network time is off, or the clock is unsynchronized
after 15 minutes online. Offline or just after boot is `info`. Check
`timedatectl timesync-status` and `systemctl status systemd-timesyncd`.

## desktop

`facts.hyprland.configErrors` comes from `hyprctl -j configerrors`; personal
Hyprland Lua lives in `~/.config/cybexos/hypr/user.lua`. `facts.shell.safeMode` means
the shell fell back to recovery after repeated crashes or by request: read
`journalctl --user -b -u quickshell`, disable an identified broken personal
plugin with `cybex plugin disable ID` (with the person's agreement), then
`cybex shell recover`. `unknown` outside a Hyprland session is expected.
