# CybexOS live image

The live image packages the existing Hyprland/Quickshell desktop, boots into
a temporary account, and opens a welcome window with **Install CybexOS**
and **Try the desktop first**. Installation uses Fedora 44's Anaconda Web UI.
Anaconda owns disk selection, partitioning, encryption, account creation,
installation progress, and its final destructive confirmation. The welcome
application never runs a partitioning command.

The ISO carries the full default application set: desktop and media apps,
Fastfetch and shell tools, Steam, Docker, Podman/Distrobox, Tailscale, Brave,
1Password, ChatGPT, LocalSend, Spotify, developer tools, the Android SDK,
Rust, Claude Code, OpenCode, Codex CLI, and T3 Code. Installation and initial
application setup work offline. Signing in and using online services still
require the relevant accounts and network access.

## Try the image

In the build output directory, run `sha256sum --check SHA256SUMS`. Open
`CybexOS-Live-44.iso` in a virtual machine, or choose **Custom image** in Fedora
Media Writer and follow its prompts to write the ISO to your chosen USB drive.
Writing an image replaces the contents of that USB drive.

Boot the image and choose **Install CybexOS** in the welcome window.
Anaconda walks through language, timezone, storage, optional disk encryption,
and your account. Review the selected disk before confirming installation.
When installation finishes, restart and remove the USB drive. Log in to your
new account to open the Hyprland/Quickshell desktop and its first-login welcome.

## Build on Debian or Fedora

On Debian, the host prerequisites are `qemu-system-x86`, `qemu-utils`,
`cloud-image-utils`, and `openssh-client`, plus read/write access to `/dev/kvm`.
Python 3.11 or later is required. The host does not need Anaconda, RPM build
tools, privileged containers, loop devices, or Fedora installed.

```bash
./image/build --output "$HOME/.local/share/cybexos/images/alpha-01"
```

Use a new, empty output directory for each build. Allow approximately 180 GiB
of free disk space and 24 GiB of RAM for the complete application build. The builder:

1. Downloads and SHA-256-verifies the same Fedora Cloud 44 base used by the
   existing VM convergence test.
2. Boots an isolated KVM guest with a new 220 GiB sparse overlay and temporary
   SSH credentials. Only those virtual disks are attached.
3. Transfers an explicit allowlist of source files and runs the existing
   application role in the disposable guest. It installs pinned upstream
   tools, complete system Flatpaks, and a clean per-user application seed.
4. Builds the desktop RPM, adds the shared application lists to the compose
   kickstart, and creates the live ISO with the `livecd-tools` image library.
   Applications are selected directly, so later application removals leave
   the desktop package installed.
5. Copies the ISO, RPM, application and payload manifests, and checksums to the output directory.
6. Stops its VM and removes the temporary disk and credentials on success,
   failure, or a normal interruption. Build and console logs are retained.

The builder uses Fedora's moving security-update repositories, so successive
builds are not byte-for-byte reproducible. The Cloud base, COPR key, and font
downloads are checksum-verified. All upstream RPM repositories retain package
signature checks. Fedora 44 ships an older `livecd-tools` whose transaction
implementation skips signature checking; `image/compose` supplies a DNF
adapter that checks every upstream RPM before any installation script runs.
Only the freshly built private alpha desktop RPM and inventory-checksummed
upstream application RPMs may use the local repository. The latter are
SHA-256-verified again at the transaction boundary. Vendor repositories retain
their package and metadata signature policies.

## Runtime and accounts

`cybexos-desktop` owns shared files under `/usr/share/cybexos`,
session units under `/usr/lib/systemd/user`, and commands under `/usr/bin` and
`/usr/libexec`. It reuses the existing QML, Hyprland modules, helper scripts,
and checksum-pinned fonts. The image packaging step adapts system helper paths
in its staging directory; the Ansible installation is unchanged.

At login, `cybexos-user-init` copies absent application defaults from
the offline seed, using filesystem reflinks when available, and creates
absent runtime/helper links. Seed-owned symlinks are relative, so every
account gets working toolchains and independent writable application state.
The first live login can take around a minute while the toolchains are copied
into the writable overlay. Installed Btrfs systems can use reflinks instead.
Existing files and even dangling links are preserved. No first-login download
or privileged background installer is needed. Shell preferences, plugins, themes, and Hyprland overrides
remain per-user. The system keyboard choice is read through locale1 at login.

The live account is created at boot in the writable overlay, not baked into
the packaged desktop. It has temporary autologin and administrative access.
Anaconda's post-install script explicitly removes that account, its privilege
rules, and live-only startup files from the destination, and restores GDM
without autologin. It records Hyprland as the new accounts' GDM session so the
first login opens the intended desktop. The installed user sees a separate
first-login welcome.
Locking and idle lock are disabled in the passwordless live session.

On image installations, `cybex update` uses the existing durable DNF
and Flatpak updater. Desktop RPM updates will require a signed RPM repository;
the Ansible source-release updater is not used to replace RPM-owned files.
The original checkout-based installer and its update channel remain available
for existing installations.

## Checks

### Graphics coverage

The image includes Fedora's kernel driver sets, Mesa OpenGL/EGL and Vulkan
drivers, and explicit AMD, Intel, and NVIDIA GPU firmware packages. These
firmware packages must be listed separately: the compose disables weak
dependencies, so `linux-firmware` alone does not install them. Composition
checks that the required graphics packages are installed before packaging.
The generic live initramfs explicitly includes kernel modesetting (`drm`);
hardware detection chooses the driver, and Hyprland requests each display's
preferred mode. No GPU vendor is forced or blacklisted.

This covers Intel (`i915`/`xe`), AMD (`radeon`/`amdgpu`), NVIDIA through
Nouveau/Mesa (including NVK on supported GPUs), and Fedora's virtual display
drivers such as virtio and VMware. Kernel driver availability does not imply
that every older GPU supports the graphics features Hyprland requires.
Proprietary NVIDIA drivers are not bundled: they require selecting a branch
for the GPU, matching kernel modules, and Secure Boot signing/enrollment when
applicable. Firmware is not a replacement for those drivers on GPUs that need
them. Physical GPU compatibility still needs testing after the next rebuild.

For an unexpected low resolution, `lspci -nnk` (included in the image) shows
the GPU and bound kernel driver, `hyprctl monitors all` shows display modes,
and `sudo journalctl -b -k` exposes firmware, modesetting, and EDID failures.
Boot the normal menu entry when testing graphics; a basic-graphics entry with
`nomodeset` intentionally disables normal kernel modesetting.

### Validation

The first private alpha's completed VM tests and exact ISO checksum are
recorded in [VALIDATION.md](VALIDATION.md).

The [September 23 source and installer audit](AUDIT-2026-09-23.md) records
current desktop parity gaps, build fixes, and proposed boot/installer changes.
It does not qualify a newly built ISO.

```bash
# In Fedora with python3-pyside6 installed:
QT_QPA_PLATFORM=offscreen python3 image/tests

# Or use the isolated test container on Debian:
docker build -f image/Containerfile.tests -t cybexos-image-tests:44 image
docker run --rm -v "$PWD:/source:ro" cybexos-image-tests:44

# Boot and check an image (UEFI testing on Debian also requires ovmf):
./image/test-live "$HOME/.local/share/cybexos/images/alpha-01/CybexOS-Live-44.iso" \
  --output "$HOME/.local/share/cybexos/images/test-01"
```

These exercise two-user isolation, preservation during vendor updates,
installed-system installer gating, startup failure reporting, and real Qt QML
loading for both welcome modes. A booted ISO additionally needs graphical
login, Anaconda installation onto a blank virtual disk, and a successful boot
from that installed disk. A passing package build alone does not prove those.

`image/test-live --hold` keeps its VM available for interacting with Anaconda.
The generated `vm.json` records its loopback-only VNC port, SSH command, and
QMP socket. The test uses 16 GiB RAM, a blank 100 GiB virtual disk, and blocks outbound
networking while checking the complete RPM/Flatpak manifest and user toolchains.
It allows 150 seconds for boot and first-login setup (`--boot-wait` overrides
this), and flushes guest filesystem writes before stopping a held VM.
It boots the ISO through UEFI by default (`--firmware bios`
selects BIOS), opens the live user's terminal through virtual keyboard events,
and adds an ephemeral SSH key to that live session. The ISO itself is not
modified. Interrupting the test audits Quickshell, stops its VM, and removes
the host test key. The virtual disk is retained for inspecting an installation.
The smoke test does not install the system. After a manual installation, stop
the live VM and boot its retained `installed.qcow2` without a CD-ROM, using
the same `OVMF_VARS.fd` for UEFI. Verify disk unlocking, GDM login, and the
installed welcome. Secure Boot requires separate testing.
`image/vm-control` can take screenshots, send clicks/keys, and execute the
recorded SSH command for this disposable VM.

Use `image/build --debug-on-failure` to retain a running failed builder for
inspection. Its `builder.json` contains the SSH command. Interrupt the build
when finished to stop the VM and remove its temporary disk and credentials.

`applications.json` records the full requested RPM and Flatpak contract.
Composition checks every listed application before packaging. `packages.txt`
lists the installed RPM versions. `package-manifest.json` records file hashes
and symlink targets from the staged payload. Upstream executable bytes are
preserved through RPM packaging; the manifest is not an extracted-RPM audit. `SHA256SUMS`
contains the hashes of the actual ISO and RPM artifacts.

## Release boundary

This is a private alpha image. The repository has no software license yet;
the RPM's `LicenseRef-Not-Licensed` records that fact and grants no rights.
Before public distribution, select the repository license, review redistributed
dependencies and Fedora branding, establish RPM signing and update hosting,
and qualify BIOS/UEFI installation and recovery on supported hardware.
Do not describe a local build as a signed or production-ready release.

Upstream implementation references:

- <https://github.com/livecd-tools/livecd-tools>
- <https://github.com/rhinstaller/anaconda/tree/main/data/liveinst>
- <https://github.com/rhinstaller/anaconda-webui>
