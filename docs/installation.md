# Fresh installation

Boot a completed Cybex OS x86_64 ISO in UEFI mode. The ISO starts only the
installer: there is no live desktop, display manager, live account or sudo. The
boot menu (`nix/modules/iso-boot.nix`) starts the default after ten seconds and
offers:

- **Install Cybex OS**, the default.
- **Install with basic graphics**: `nomodeset`, so the screen draws on the
  firmware framebuffer (simpledrm) when a native display driver fails.
- **Start Cybex OS on this computer**, only when GRUB finds an installed Cybex OS
  boot loader on partition 1 of a disk: it chainloads that loader, for a USB
  stick left plugged in after installation. Firmware that connects only the
  boot drive (some fast-boot settings) leaves the entry out.
- **Troubleshooting ›**: **Show all boot messages** (the installer with kernel
  and systemd output), **Install in text mode** (the terminal installer on
  tty1), **Run from memory** (`copytoram`, 16 GB RAM or more, after which the USB
  drive can be removed), **Serial console** (ttyS0, 115200), **Rotate the
  screen ›** (the console and the graphical installer, through `fbcon=rotate`
  and `cybexos.rotate`) and **Memory test** (Memtest86+).
- **Firmware settings** and **Shut down**.

Every installer entry starts the same fresh installer; none starts a disk
operation by itself. NixOS's text-mode menu remains on `t`. A legacy BIOS start
shows how to start the drive in UEFI mode instead of an installer that would
refuse to install; it offers restart, shut down, or continuing without
installing.

The installed system's boot menu uses the same theme (see
[recovery](recovery.md)); the firmware lists it as **CybexOS**. Installed
systems boot quietly behind the Plymouth splash, whose logo stays where the
menu drew it. PXE uses the same ISO and shows the same menu. iVentoy's NixOS hook
needs the upstream scripted live initrd; installed machines use systemd stage
one. A successful virtual-CD boot does not establish a successful iVentoy boot.

## The installer screen

tty1 shows `cybexos-installer`, a Rust and Slint kiosk drawn by Slint's software
renderer straight to KMS/DRM, with keyboard, mouse and touch input through
libinput. It needs no compositor, browser, Qt or GPU userspace, so one image
draws through amdgpu, i915/xe, nouveau, virtio-gpu or the firmware framebuffer,
and the medium carries no separate NVIDIA kernel. The 1280×800 design canvas is
zoomed to the largest connected mode (1920×1200 → 1.5, 2880×1800 → 2.25) and
centred. It runs as the unprivileged `cybexos-installer` user in a logind session
on seat0, the same unit shape as NixOS's `services.cage`. If no display device
works after a few attempts, it switches tty1 to the text installer.

The screen owns no state. `cybexos-installerd` (root) keeps the non-secret draft,
Wi-Fi, time zone detection, the keyboard layout and diagnostics, and drives the
one disk-writing worker, `cybexos-install --json-ui`, over its private protocol.
The screen receives bounded JSON snapshots (`cybexos.installer-state.v1`) over
`/run/cybexos-installer/control.sock` (mode 0660, group `cybexos-installer`). A
screen restart, whether for a keyboard change, a crash or Ctrl+Alt+Backspace
(which Slint's KMS backend treats as quit), resumes on the same step. The service
unit uses `KillMode=process`, and the worker keeps installing if its output is
lost, so a restarted screen or service never interrupts an installation.

The flow is **Welcome → Disk → You → Review → Installing → Done**:

- **Welcome** sets the language and keyboard and shows the system check:
  firmware (UEFI, Secure Boot), network, release verification, disks, graphics
  and memory. An unsigned development ISO says so; **Use this test build** (or
  Enter) is the explicit consent. Without a network, **Connect to Wi-Fi** opens
  the network sheet, which uses the desktop's own NetworkManager helper.
- **Disk** lists usable whole disks with model, size and contents; the only
  usable disk is preselected. **More options** shows serial numbers and the
  disks that cannot be used, with the reason. Encryption (LUKS2) is on by
  default; the layout (16 GiB ESP, 64 GiB minimum) is the shared module contract.
- **You** asks for an optional name, a username, the password twice, the time
  zone and the computer name. Names follow the rules below.
- **Review** names the disk and what is on it, and summarizes every choice with
  **Change** or **Customize** (application groups, and the NVIDIA driver when an
  NVIDIA GPU is detected). Changes made here are reviewed again automatically.
  Only clicking **Erase … & install** authorizes erasure; Enter never does, and
  there is no serial or ERASE typing. The worker binds that click to the reviewed
  plan with a fresh token and rechecks the disk's identity before writing.
- **Installing** reports the worker's six real stages and the elapsed time,
  without an invented percentage or estimate. **Show installation details**
  opens the most recent 256 KiB of the private log `/run/cybexos-installer.log`,
  refreshed every two seconds; it can be saved to another USB stick (the medium
  itself is read-only). Arrow keys, Page Up/Down, Home and End scroll the log.
  Refresh keeps your reading position; End resumes following new output. The
  log belongs to this boot only.
- **Done** offers restart or power off; installation never reboots by itself.

Before building the desktop, the installer explicitly copies already-built
dependencies from the medium into the fresh machine's Nix store. This also
reuses outputs such as shell completions that prohibit cache substitution and
would otherwise be rebuilt by `nixos-install`. The dependency graph comes from
the reviewed machine configuration, so an application group is not copied just
because it is bundled on the medium. Nix verifies the transferred contents;
only this trusted local copy waives signatures, as with the installer’s existing
source transfer. Remote cache verification remains enabled. Hardware and account
configuration still build through the normal NixOS installer. The installation
record at `/var/lib/cybexos/installation.json` records the number of seeded paths
and transfer time, and the completion status retains the elapsed time.

A stop before any disk change explains the cause and the next steps: Secure Boot
(with **Restart into firmware settings**; the installer never turns Secure Boot
off), a legacy BIOS boot, an unauthenticated medium or a missing network. A
failure after the disk was changed says so and opens the log. The menu (⋯) has
the installation log, a recovery shell on tty2 (Alt+F1 returns), the text
installer, restart into firmware settings, restart and power off.

### Names and passwords

The username field accepts only what the worker accepts, `[a-z][a-z0-9-]{0,30}`.
Uppercase becomes lowercase as you type and accents fold to their base letter;
any other character, and a leading digit or hyphen, is refused with a one-line
reason. A name typed under **Your name** suggests the username until you edit
it. Reserved names are refused before review: `root`, `nixos`, and every user and
group name of the installed product, recorded on the medium in
`/etc/cybexos/installer-reserved-names.json`. The worker validates again. The
optional name becomes the account's description; it may not contain colons,
commas, backslashes, double quotes, dollar signs, backticks or control
characters. The computer name follows `USERNAME-cybexos` until edited and has the
same character rules.

One password of at least eight characters, without character-class rules, sets
both the login and the LUKS2 key, so it is typed twice. It is held only in the
screen and service memory until the final click, then passed to the worker over
its private stdin; it never appears in a snapshot, the draft, a log or an
argument. On an encrypted disk, unlocking it at startup signs you in: SDDM
logs in automatically once per boot after verifying the encryption, and the
disk passphrase, cached for 2.5 minutes, unlocks GNOME Keyring. Logging out,
restarting the login manager or a failed check returns to password login.
Without encryption every desktop login asks for the password.

Changing the keyboard writes `/run/cybexos-installer/keyboard.env` and loads the
matching console keymap; the screen restarts with the new layout, because
Slint's KMS backend reads the XKB layout when it starts, and clears any typed
password so it is retyped with the layout that will unlock the disk.

### Time zones

The zone list comes from the medium's own `zone.tab`: one familiar entry per
country, so Amsterdam stays Amsterdam although tzdata merges its data with
Brussels. The medium and the installed system use the same tzdata, from the one
tested Nixpkgs revision. Search matches city, country, tzdata's notes ("most of
Ukraine"), retired names through backward links (Kiev → Kyiv, Calcutta →
Kolkata) and offsets (`utc+9`). Fixed offsets are opt-in and labelled with the
true sign: `Etc/GMT+5` is UTC−05:00. Each row shows the live local time, computed
from the medium's TZif files; the selected zone also shows its next clock change.
The world map shades day and night; clicking it selects the nearest zone. The
selection is always a zone ID, never a position in a filtered list.

The service suggests a zone from the public IP address through ipapi.co, with a
bounded timeout, once a network is available. A suggestion never replaces a zone
chosen by hand; **Detect again** asks once more.

### Network

The medium and fresh installed systems start with Google DNS (`8.8.8.8`,
`8.8.4.4` and their IPv6 equivalents); the initial wired profile ignores DNS
advertised by DHCP, and Wi-Fi joined in the installer inherits it. The worker
checks verified HTTPS access to the download service before setup and again
before erasing the disk. A failure stops before any disk change and offers a
retry; the private log records the resolver stub, upstream servers, routing
domains and the result. These checks never rewrite DNS or disconnect a PXE
interface. NetworkManager and Tailscale share systemd-resolved on installed
systems; signing in to Tailscale can add MagicDNS. See Tailscale's
[Linux DNS guidance](https://tailscale.com/kb/1188/linux-dns).

The network sheet's **Refresh** requests a new Wi-Fi scan. Joining a secured
network creates a profile and supplies its password privately over stdin.
NetworkManager retains that profile for this live boot and reconnects when the
access point returns. Ethernet reconnects automatically when its cable returns.
As the sheet states, these live Wi-Fi credentials are used for installation;
join the network again in the installed desktop.

If a download fails after disk preparation, the installer keeps the mounted
target and waits up to 15 minutes for verified connectivity to return. Open
the network chip to join Wi-Fi, or reconnect Ethernet. It then repeats only the
failed Nix lock, desktop installation or source archive operation, preserving
completed downloads; it never repeats partitioning or formatting. Transfer
failures get at most three attempts. Ordinary build errors still stop and open
the installation details. A failure before disk preparation reports that no
disk was erased; a later failure reports that the selected disk was changed.

### Recovery and other interfaces

The serial console and tty2 are root shells on the physical medium; there is no
SSH, live account or sudo. `nmtui` configures the network. `cybexos-install
--terminal` is the same installer as text; the text-mode boot entry runs it on
tty1, and the screen's menu switches tty1 to it after cancelling the idle
graphical worker. `cybex install`, `./install` and `./bootstrap` enter the same
fresh installer and refuse outside the installation medium. Only one installer
can run at a time.

### Offline payload

The medium carries the free part of the default desktop as a store payload:
the system profile, `/etc`, kernel modules, firmware, systemd and the boot loader
installer of a representative installation. `nixos-install` copies those paths
from the medium instead of downloading them. The machine-specific initrd and
configuration are built during installation; the unfree application groups
(proprietary applications, Steam) and NVIDIA drivers still download. Release
authentication always needs the internet.

### Design reference and previews

`installer/ui-reference/index.html` is the design reference for the screen.
`installer-preview` renders every screen with the real UI and software renderer:

```sh
installer/cybexos-installerd --dump-static > static.json   # with lifecycle/ on PYTHONPATH
cd installer/kiosk && cargo run --features preview --bin installer-preview -- ../../static.json /tmp/renders
```

New menubars enable Model Usage and leave Hermes Agent, Remote Server, T3 Code,
GitHub and Fusebox available but hidden. Installing connected-service support
does not enable their widgets. Saved widget choices remain personal. LAN
discovery is enabled by default: Avahi browses and publishes local addresses,
`.local` resolution is available, and the firewall admits the discovery and
selected application ports. Bibata Modern Classic is the default pointer across
the installed desktop, GTK/Qt/XWayland and SDDM; user cursor preferences remain
overrides.

The ISO retains its tested flake input sources. A fresh machine's first lock
starts with that exact Nixpkgs revision and content hash, retaining the selected
stable branch as its upstream update source. Installation never resolves a newer
branch head implicitly. Later upstream-only updates advance this machine-owned
input independently of Cybex OS. This does not make installation fully offline:
release authentication and packages not bundled on the medium require internet.

Use a backed-up target disk of at least 64 GiB. Installation erases only the
explicitly selected whole disk after its graphical confirmation. Its serial is
checked automatically; it is never a typing exercise. Mounted or read-only disks,
active swap, open encryption/LVM/RAID mappings and changed identities are
rejected. Passwords use private input,
not arguments or configuration source. The installer creates a 16 GiB ESP and
an ext4 root, optionally under LUKS2, with zram rather than persistent plaintext
swap. Root stays locked; the chosen wheel user authorizes administration.
The EFI partition accommodates the full early graphics firmware and ten retained
boot generations, including room to copy the next generation before cleanup.
Its layout and minimum disk size come from the shared Nix module contract.

`nixos-generate-config` records actual hardware and filesystems. DMI/PCI/ACPI/
EDID detection selects narrowly scoped XPS/NVIDIA declarations. The machine
flake follows the stable Nixpkgs input and pins the authenticated Cybex OS exact
revision/NAR identity. The complete target is built and installed through the
shared modules. First login installs missing vendor-skill discovery symlinks
and never overwrites a pre-existing personal skill.

Production media install only their own exact tested source. Before asking for
choices, the installer fetches the immutable signed manifest for the medium's
`/etc/cybexos/release.json` version (`releases/download/vVERSION/manifest.json`)
over public HTTPS, verifies its Ed25519 signature and supported metadata, and
requires its version, exact revision and NAR to equal the medium's. A channel is
never consulted to select a newer release; the medium's channel policy still
applies (stable rejects a prerelease medium). Any mismatch stops before disk
erasure and vendor evaluation. The medium's channel is written to `machine.nix`
as an explicit `cybexos.updates.channel`, so a later stable vendor release does
not move a beta machine; the vendor default is `beta` for prerelease versions and
`stable` otherwise, and the administrator may change it.

Production installation is blocked until owner-controlled trust keys and an
authenticated published release exist. For isolated development qualification,
`cybexos-install --development-source /path/to/source` explicitly selects an
unreleased content-addressed test source. The graphical welcome on an unsigned
development ISO explains this limitation and offers the bundled test build,
requiring explicit consent (default: no) before disk selection. Automated use
still requires `--development-source`. Such a result is not an authenticated
release qualification.

Secure Boot is not disabled. Native Lanzaboote configuration is provided, but
fresh enrollment/signed installation media and out-of-tree-module signing have
not yet been qualified; the installer currently refuses Secure Boot installation
before erasure. See [hardware blockers](hardware-security.md).

Automated isolated installation accepts a non-secret JSON plan with `disk`,
`serial`, `hostname`, `username`, `timezone`, `locale`, `keyboard`, `encrypted`,
`autoLogin`, `secureBoot`, `nvidiaOpen`, optionally `fullName`, `features` and
`desktopKeyboard`, plus `{"password":"…"}` JSON through `--secrets-fd`. Stop
`cybexos-installer-ui.service` and `cybexos-installerd.service` first; stopping the
service cancels its idle worker and releases the installer lock. The same
validation and disk-erasure guard run in every mode. No installer reboots
automatically.

For direct ISO testing without network boot, run the qualification tool in an
isolated KVM environment with QEMU, OVMF, Python pexpect and Pillow available:

```sh
scripts/qualify-installations /path/to/completed.iso --interactive \
  --applications standard --case both --scenario lifecycle \
  --work-dir /path/to/task/vms --screenshots /path/to/task/screenshots \
  --output /path/to/task/installations.json
```

This boots the ISO as a virtual optical disk and installs into disposable disks.
`--interactive` installs through the real tty1 screen with QMP keyboard and
pointer input: Enter for development consent and navigation, a pointer click on
the encryption switch (plain case), typing a name and `CybexQA` (the service must
receive `cybexqa`), both passwords, and a pointer click on **Erase … & install**.
The serial console only observes the service's snapshots; QA-only choices (the
installed serial console, the smaller application set) go through the same
service. It checks plain and encrypted installed password login, then exercises
the staged updater and rollback. On the installed Hyprland session it also checks
the welcome guide at first login (its Hello summary of the installer's
choices loads, its full-screen layer is mapped, a window opened over it makes
it step aside to its resume pill and Resume brings it back, and the dismissed
guide leaves Hyprland's layer list) and the keyboard shortcuts
(`keyboardShortcutsRuntime`): valid `hyprctl binds -j` holding every resolved
key, a complete error-free `keybindings-state.json`, the xkbcli keymap, a remap
and website shortcut applied and reset through the shipped Settings
`keybindings` service with `user.lua` unchanged, Settings opened on
**Keyboard shortcuts**, and no onboarding QML errors in the shell's journal. `--applications minimal` explicitly selects fewer optional
groups; it does not qualify the standard application selection. VM files are
removed when the tool exits. Screenshots and JSON evidence are retained only
when requested. `--serial-console` is an installer option for this isolated test;
normal interactive installations do not enable a serial console.

The separate network test uses the actual ISO's installer daemon, network helper
and NetworkManager with simulated Wi-Fi radios, WPA2, DHCP and internet routing:

```sh
scripts/qualify-installer-network /path/to/completed.iso \
  --work-dir /path/to/task/vms --output /path/to/task/network.json
```

Run it in `nix develop` and inside the host's managed disposable-resource
workflow. It checks Ethernet unplug/replug, scanning, wrong-password rejection,
HTTPS using Wi-Fi as the sole route, and automatic reconnection after access
point loss and NetworkManager restart. It does not qualify physical adapters or
firmware. The [2026-10-24 installer audit](measurements/installer-network-partitioning-2026-10-24.md)
records additional real GUI, WPA3, partitioning and completed-installation tests.
