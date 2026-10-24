# Fresh installation

Boot a completed NerdOS x86_64 ISO in UEFI mode. The ISO starts only the
installer: there is no live desktop, display manager, live account or sudo. The
boot menu offers:

- **Install NerdOS VERSION**, the default.
- **Install NerdOS VERSION - safe graphics**: `nomodeset`, so the screen draws on
  the firmware framebuffer (simpledrm) when a native display driver fails.
- **Install NerdOS VERSION - text mode**: the terminal installer on tty1.
- **Verbose boot diagnostics**: the default installer with kernel messages.

Every entry starts the same fresh installer; none starts a disk operation by
itself. The upstream **Options** submenu, firmware setup and shutdown entries
remain. PXE uses the same ISO. iVentoy's NixOS hook needs the upstream scripted
live initrd; installed machines use systemd stage one. A successful virtual-CD
boot does not establish a successful iVentoy boot.

## The installer screen

tty1 shows `nerdos-installer`, a Rust and Slint kiosk drawn by Slint's software
renderer straight to KMS/DRM, with keyboard, mouse and touch input through
libinput. It needs no compositor, browser, Qt or GPU userspace, so one image
draws through amdgpu, i915/xe, nouveau, virtio-gpu or the firmware framebuffer,
and the medium carries no separate NVIDIA kernel. The 1280×800 design canvas is
zoomed to the largest connected mode (1920×1200 → 1.5, 2880×1800 → 2.25) and
centred. It runs as the unprivileged `nerdos-installer` user in a logind session
on seat0, the same unit shape as NixOS's `services.cage`. If no display device
works after a few attempts, it switches tty1 to the text installer.

The screen owns no state. `nerdos-installerd` (root) keeps the non-secret draft,
Wi-Fi, time zone detection, the keyboard layout and diagnostics, and drives the
one disk-writing worker, `nerdos-install --json-ui`, over its private protocol.
The screen receives bounded JSON snapshots (`nerdos.installer-state.v1`) over
`/run/nerdos-installer/control.sock` (mode 0660, group `nerdos-installer`). A
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
  opens the most recent 256 KiB of the private log `/run/nerdos-installer.log`,
  refreshed every two seconds; it can be saved to another USB stick (the medium
  itself is read-only). Arrow keys, Page Up/Down, Home and End scroll the log.
  Refresh keeps your reading position; End resumes following new output. The
  log belongs to this boot only.
- **Done** offers restart or power off; installation never reboots by itself.

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
`/etc/nerdos/installer-reserved-names.json`. The worker validates again. The
optional name becomes the account's description; it may not contain colons,
commas, backslashes, double quotes, dollar signs, backticks or control
characters. The computer name follows `USERNAME-nerdos` until edited and has the
same character rules.

One password of at least eight characters, without character-class rules, sets
both the login and the LUKS2 key, so it is typed twice. It is held only in the
screen and service memory until the final click, then passed to the worker over
its private stdin; it never appears in a snapshot, the draft, a log or an
argument. First desktop login requires the password; automatic login is a
later, explicit machine choice and requires verified encryption.

Changing the keyboard writes `/run/nerdos-installer/keyboard.env` and loads the
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

### Recovery and other interfaces

The serial console and tty2 are root shells on the physical medium; there is no
SSH, live account or sudo. `nmtui` configures the network. `nerdos-install
--terminal` is the same installer as text; the text-mode boot entry runs it on
tty1, and the screen's menu switches tty1 to it after cancelling the idle
graphical worker. `nerd install`, `./install` and `./bootstrap` enter the same
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
installer/nerdos-installerd --dump-static > static.json   # with lifecycle/ on PYTHONPATH
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
input independently of NerdOS. This does not make installation fully offline:
release authentication and packages not bundled on the medium require internet.

Use a backed-up target disk of at least 64 GiB. Installation erases only the
explicitly selected whole disk after its graphical confirmation. Its serial is
checked automatically; it is never a typing exercise. Mounted disks,
active swap and changed identities are rejected. Passwords use private input,
not arguments or configuration source. The installer creates a 16 GiB ESP and
an ext4 root, optionally under LUKS2, with zram rather than persistent plaintext
swap. Root stays locked; the chosen wheel user authorizes administration.
The EFI partition accommodates the full early graphics firmware and ten retained
boot generations, including room to copy the next generation before cleanup.
Its layout and minimum disk size come from the shared Nix module contract.

`nixos-generate-config` records actual hardware and filesystems. DMI/PCI/ACPI/
EDID detection selects narrowly scoped XPS/NVIDIA declarations. The machine
flake follows the stable Nixpkgs input and pins the authenticated NerdOS exact
revision/NAR identity. The complete target is built and installed through the
shared modules. First login installs missing vendor-skill discovery symlinks
and never overwrites a pre-existing personal skill.

Production media install only their own exact tested source. Before asking for
choices, the installer fetches the immutable signed manifest for the medium's
`/etc/nerdos/release.json` version (`releases/download/vVERSION/manifest.json`)
over public HTTPS, verifies its Ed25519 signature and supported metadata, and
requires its version, exact revision and NAR to equal the medium's. A channel is
never consulted to select a newer release; the medium's channel policy still
applies (stable rejects a prerelease medium). Any mismatch stops before disk
erasure and vendor evaluation. The medium's channel is written to `machine.nix`
as an explicit `nerdos.updates.channel`, so a later stable vendor release does
not move a beta machine; the vendor default is `beta` for prerelease versions and
`stable` otherwise, and the administrator may change it.

Production installation is blocked until owner-controlled trust keys and an
authenticated published release exist. For isolated development qualification,
`nerdos-install --development-source /path/to/source` explicitly selects an
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
`nerdos-installer-ui.service` and `nerdos-installerd.service` first; stopping the
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
the encryption switch (plain case), typing a name and `NerdQA` (the service must
receive `nerdqa`), both passwords, and a pointer click on **Erase … & install**.
The serial console only observes the service's snapshots; QA-only choices (the
installed serial console, the smaller application set) go through the same
service. It checks plain and encrypted installed password login, then exercises
the staged updater and rollback. `--applications minimal` explicitly selects fewer optional
groups; it does not qualify the standard application selection. VM files are
removed when the tool exits. Screenshots and JSON evidence are retained only
when requested. `--serial-console` is an installer option for this isolated test;
normal interactive installations do not enable a serial console.
