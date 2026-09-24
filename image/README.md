# CybexOS live image

The image packages the shared Hyprland/Quickshell desktop and offline
application set. The proposed boot path is **Cybex firmware menu → Cybex
Plymouth → live desktop/welcome → three-screen installer**. After an encrypted
installation, it is **disk unlock → automatic login → desktop**.

The September 23 implementation has source, Qt, backend-fixture and browser
checks only. **No ISO was built or booted for these changes.** The earlier
image in [VALIDATION.md](VALIDATION.md) predates this implementation and does
not qualify it. See [IMPLEMENTATION-2026-09-23.md](IMPLEMENTATION-2026-09-23.md)
for changes and remaining integration checks, and the historical
[audit](AUDIT-2026-09-23.md) for the original findings.
The September 24 source also replaces GDM with SDDM and shares the workstation's
login policy. Earlier GDM boot results do not qualify this migration.
The replacement desktop RPM built successfully in a disposable Fedora VM.
ISO creation was then deferred at the user's request; no new ISO was completed
or booted, and temporary build artifacts were removed.

## Installation experience

| Screen | Required choices | Defaults |
| --- | --- | --- |
| Your setup | Username, password/confirmation, keyboard | Language, timezone and hostname under More options; live keyboard applied before password entry, with a test field |
| Install location | Disk, identified by model and capacity | LUKS2-encrypted Btrfs, shared initial disk/account password, automatic login |
| Review and install | Explicit confirmation to erase the selected disk | Anaconda's actual partition plan, progress, completion and reboot |

The custom Cockpit page uses Fedora 44 Anaconda's DBus storage/account/task
interfaces. Anaconda performs validation, partitioning and installation.
The full Anaconda Web UI remains available for advanced storage. The simple
flow requires a disk of at least 64 GiB and erases the selected disk.
Encryption can be disabled explicitly; that path uses a normal login screen.
Root stays locked, and the new user has administrator privileges.

Passwords are passed through the privileged local transport and Anaconda's
in-memory interfaces. The account is stored as a password hash. CybexOS's
confirmation/progress files contain neither the password nor its hash.
Installation runs in a durable systemd worker and progress survives a browser
reload. A failed or lost installation worker requires inspection/restart;
the UI does not automatically retry disk writes.

The account and encryption passwords start equal; changing one later does
not change the other. GNOME Keyring remains encrypted and can unlock through
SDDM's PAM stack using the briefly cached boot passphrase. An absent/expired
cache or different keyring password falls back to the application's unlock
prompt. No passwordless keyring or longer-lived password cache is created. See
[INSTALLER.md](INSTALLER.md) for interfaces, keyboard constraints and upstream
version references.

## Desktop and first boot

Both deployment paths consume [the shared desktop contract](../assets/desktop-contract.json),
wallpaper collection, existing Cybex Plymouth artwork, helpers, firewall zone
and sysctl policy. Bluetooth visibility matches the workstation default.
The image contains the repository desktop and default applications; it does
not export personal plugins (including the Omarchy plugin), credentials,
monitor overrides or private launchers from the build machine. The private
portal keybinding is enabled only when its helper exists.

The firmware menu uses the same dark background and warm accent as Plymouth
and the installer. Media checks, basic graphics and recovery entries are
preserved. Installed accounts are seeded before reboot. Live login copies
only desktop essentials before starting Hyprland; a background service copies
the large offline application seed and reports progress in the welcome
window. Reflinks are used where supported. Partially copied files never
become active, personal files/symlinks are preserved, and interrupted seeding
can be resumed with `cybex prepare-apps`. Developer tool links and editor
configuration activate after their dependencies are copied.

On an installed system the first login opens the welcome window: the Cybex
wordmark, a scrollable row of popular Wallhaven wallpapers that apply with one
click (the shell searches, downloads and applies them over
`cybexos-runtime ipc wallpaper …`), and a Settings button. Offline, the row
shows the wallpaper folder instead. Closing the window finishes the welcome;
`cybex welcome` opens it again. The live session keeps its install-or-explore
choice. The window finds its QML beside the program, so
`python3 image/rootfs/usr/bin/cybexos-welcome` runs it from a checkout.

The default application payload includes the desktop/media tools, Steam,
Docker, Podman/Distrobox, Tailscale, Brave, 1Password, ChatGPT, LocalSend,
Spotify, Android SDK, Rust, Claude Code, OpenCode, Codex CLI and T3 Code.
The payload is prepared for offline installation and first use. Online
services still need their accounts/network access. T3 waits for its offline
seed rather than downloading a fallback during setup.

The temporary live account has administrative access and autologin; live
locking is disabled. The destination cleanup removes the account, its
privileges and live-only services/installer files, sets the shared firewall
policy, and rebuilds initramfs after removing live configuration. Installed
autologin requires the requested policy and verified root encryption, is
rechecked at boot, and is attempted only on the first SDDM start in each boot.
Logout and later SDDM starts return to the login screen.

## Source checks: no ISO or VM

```bash
# Fedora dependencies: python3-pyside6 python3-jinja2 python3-pyyaml python3-gobject-base glib2
# pykickstart nodejs24 gnupg2 git ripgrep
PYTHONDONTWRITEBYTECODE=1 python3 image/check-source
./tests/run

# Alternatively, the image fixture environment:
docker build -f image/Containerfile.tests -t cybexos-image-tests:44 image
docker run --rm -v "$PWD:/source:ro" cybexos-image-tests:44
```

`image/check-source` exercises Qt welcome loading, user isolation, interrupted
seeding, branding, installer confirmation/worker/Anaconda adapter contracts,
artifact delivery/cache, firmware discovery, iVentoy responses and release
metadata. CI runs these fixtures without an image build or VM.

`image/browser-smoke.cjs` optionally exercises the real HTML/CSS/JavaScript
against a fake Cockpit transport in a headless Chromium browser. It contacts
only its temporary loopback fixture server. Install `playwright-core@1.63.0`
in a disposable dependency directory and set `NODE_PATH` to its `node_modules`:

```bash
CYBEXOS_BROWSER=/usr/bin/brave-origin node image/browser-smoke.cjs
```

It checks the minimal flow, encryption default, erase confirmation, password
clearing, progress/reload recovery and a narrow viewport. Screenshots are
only written when `CYBEXOS_UI_SCREENSHOTS` specifies a directory.

## Builder

Python 3.11+, PyYAML and writable `/dev/kvm` are required. Host packages:

- Fedora: `qemu-kvm qemu-img xorriso openssh-clients python3-pyyaml edk2-ovmf`.
- Debian: `qemu-system-x86 qemu-utils cloud-image-utils openssh-client python3-yaml ovmf`.

The VM smoke and installation tests also need Tesseract with English data:
`tesseract tesseract-langpack-eng` on Fedora, or `tesseract-ocr tesseract-ocr-eng`
on Debian. It recognizes the disk-unlock prompt and a terminal execution
marker before the harness types private fixture input. The image builder
itself does not require OCR.

Allow approximately 180 GiB free staging space and 24 GiB available RAM for
the complete application build. OVMF is needed for later UEFI qualification.
`cloud-localds`, `xorriso`, `genisoimage` or `mkisofs` can create the builder's
cloud-init seed. Preflight checks resources and tools without creating files,
downloading or starting a VM:

```bash
./image/build --preflight
```

When a build is authorized:

```bash
./image/build
# Optional: --output /path/to/new-task-directory --memory 24576 --cpus 8
# Optional: --compression zstd (xz remains the established default)
# Optional: --update-channel /path/to/public-update-channel.json
```

Default output is `~/.local/share/cybexos/images/BUILD-ID/`; each ID combines
UTC time and a random suffix. Output must be empty and outside `/data/pxe/iso`.
The builder:

1. Verifies the pinned Fedora Cloud 44 base and starts a disposable KVM guest.
2. Transfers an explicit source allowlist, build provenance and, if supplied,
   a validated public update key/channel. Personal runtime directories and
   private signing keys are not inputs.
3. Installs applications, assembles the desktop RPM, composes and compresses
   the image, with named phases, elapsed times and failure summaries.
4. Reuses only checksum-pinned cached upstream archives/fonts/COPR keys.
   Moving npm, Flatpak and repository content is not treated as verified cache.
5. Verifies all copied checksums and atomically publishes `artifacts/`, with
   a uniquely named ISO, desktop RPM, manifests and `SHA256SUMS`.
6. Stops the guest and removes temporary disks/keys on success, failure or
   normal interruption. Logs and small provenance records stay with output.

The persistent cache defaults to `~/.cache/cybexos/image`; `--cache` changes
it. `build.json` records revision, dirty state, source archive/configuration
hashes, host tools and timings; installed `/usr/share/cybexos/build.json`
identifies the source build. `applications.json`, `packages.txt` and
`package-manifest.json` record the application contract, RPM versions and
staged payload. The latter is not an extracted-RPM audit.

Moving Fedora/vendor updates mean builds are not byte-for-byte reproducible.
The compose adapter verifies upstream RPM signatures before installation;
local upstream application RPMs are inventory-checksummed at the transaction
boundary. The locally built desktop RPM becomes signed through the release
step below. zstd is available for measurement, but compression size/startup
benchmarks have not been run; xz remains the default.

`--debug-on-failure` retains a failed builder only while the command remains
running; `builder.json` contains its SSH command. Interrupt when inspection
is finished to trigger cleanup. Do not retain superseded large test artifacts.

## Desktop updates and signing

Image installations use `cybex update` for DNF/Flatpak updates. Desktop package
versions come from `VERSION`, with a timestamp/revision release suffix and
installed provenance. Epoch 1 permits upgrading the older hardcoded alpha
version. Existing checkout installations retain their source updater.

A default build ships a **disabled** desktop update channel. Enabling actual
desktop updates requires your HTTPS repository URL and existing signing key.
Prepare a public configuration before building, for example:

```json
{
  "baseurl": "https://YOUR-HOST/cybexos/44/x86_64",
  "fingerprint": "YOUR-COMPLETE-OPENPGP-PRIMARY-FINGERPRINT",
  "key_file": "CYBEXOS-desktop.asc"
}
```

`key_file` is public ASCII armor, relative to this JSON file or an absolute
path. The builder checks its full fingerprint, rejects private/revoked/expired
key material and transfers only the normalized public channel. Both package
and repository metadata signature checks are enabled. Keep the URL/key stable
across updates; key rotation needs an explicit migration.

After an authorized build, create a signed local repository from existing
RPMs on a Fedora signing host (`rpm-sign`, `createrepo_c`, `gnupg2`):

```bash
./image/release-repository /path/to/artifacts/cybexos-desktop-*.rpm \
  --output /path/to/new-release-directory \
  --public-key /path/to/CYBEXOS-desktop.asc \
  --key YOUR-COMPLETE-OPENPGP-PRIMARY-FINGERPRINT \
  --baseurl https://YOUR-HOST/cybexos/44/x86_64
```

The RPM must have been built with that same enabled channel; a disabled or
different bundled channel is rejected. The tool signs copies, independently
verifies the RPM signatures using only the public key, signs/verifies metadata
and the release manifest, writes checksums, and atomically publishes a new
local directory. Original RPMs and the system RPM keyring remain untouched.
`--gnupghome` can select an existing signing keyring. Hosting/deployment is a
separate action; the tool does not upload anything or create signing keys.
No real signed repository was created for this implementation.

## Future ISO qualification and PXE publication

These commands are opt-in operations, **not part of source checks**. They were
not executed for the September 23 changes. Completed testing ISOs belong in
`/data/pxe/iso`; keep incomplete builds outside that tree.

On the iVentoy host, `image/publish-pxe /path/to/artifacts` verifies the artifact
set and prints a plan. Adding `--execute` copies the ISO/checksum through
staging, verifies them before publication, preserves existing images, then
requires iVentoy refresh success, completed refresh, running PXE, filename
presence and an active service. Identical-file retries are supported. The
default API contract is iVentoy 1.0.41; review its installed UI after upgrades
and provide `--api-contract` for a changed schema. A failed refresh retains
the verified ISO for inspection and does not automatically restart PXE.

When boot tests are separately authorized:

```bash
./image/test-live /data/pxe/iso/CybexOS-Live-44-BUILD-ID.iso \
  --output /path/to/new-live-test --execute-vm

./image/qualify /data/pxe/iso/CybexOS-Live-44-BUILD-ID.iso \
  --output /path/to/new-install-test --execute-vm --erase-disposable-disk
```

The harness detects Fedora/Debian UEFI firmware (raw or qcow2), uses bounded
readiness checks and blocks guest outbound networking. `--firmware bios`
selects BIOS. An adjacent `ISO-FILENAME.iso.sha256` must verify before a VM
can start. The smoke test checks the live desktop/applications; qualification
also installs to its newly created, serial-identified virtual disk, reboots
without the ISO, unlocks it and checks encryption, autologin, desktop defaults,
SELinux and live-account cleanup. It verifies an encrypted GNOME login keyring
without requesting an unlock, stores a synthetic secret, and confirms that
secret is available after another cold boot. Logout, compositor crash and
SDDM restart must return to a greeter; password login must restore both the
desktop and keyring. Another cold boot temporarily disables the cached-password
PAM module in the disposable guest, checks that the vault stays locked, then
verifies recovery through normal password login. The final cold boot injects
a single early launcher failure in the guest. It requires a working greeter,
a consumed autologin attempt, disabled autologin after restarting SDDM, and
successful password-login recovery; the original launcher is then restored.
It drives the backend; the
browser fixture separately covers frontend flow. A passing fixture is not a
boot result.

Installation qualification uses four virtual CPUs, 16 GiB RAM and a new
100 GiB sparse disk. It performs one live boot and four installed cold boots;
the three logout/crash/restart cases reuse the running installation. The
installer deadline defaults to 30 minutes (`--install-timeout 1800`); boot,
application seeding and recovery have separate bounded waits. Runtime has not
yet been benchmarked.

The ISO path and checksum are mandatory even when QEMU runs locally. The
harness resolves the path and rejects a symlink to an image outside
`/data/pxe/iso`. `image/publish-pxe` runs on the actual iVentoy host and requires
its local service and API; it cannot publish remotely using only an HTTP URL.
A build workstation needs filesystem access to that verified publication or
must run qualification on the PXE host. A local directory with the same name
does not establish that PXE publication and refresh succeeded.

`--hold` on the smoke test allows inspection using `image/vm-control` and
`vm.json`. By default cleanup removes disks, credentials, screenshots and VM
logs; small JSON reports remain. `--keep-artifacts` is only for unresolved
diagnostics, and retained paths/sizes must be reported and later cleaned.
Qualification's graphical keyboard bootstrap and greeter focus assumptions
still need real VM validation; it stops instead of blindly retrying passwords.
Physical GPUs, Secure Boot, international early-boot password entry, screen
lock, suspend/resume and real application/account credential behavior need
separate checks.

## Graphics and release boundary

The payload includes Fedora kernel drivers, Mesa OpenGL/EGL/Vulkan and explicit
AMD, Intel and NVIDIA firmware, plus DRM in the generic live initramfs. It does
not force a GPU vendor. Nouveau/NVK support depends on the GPU; proprietary
NVIDIA drivers are not bundled. Investigate graphics with `lspci -nnk`,
`hyprctl monitors all` and `journalctl -b -k`; basic-graphics recovery intentionally
disables normal modesetting.

This remains a private alpha. The repository has no software license;
`LicenseRef-Not-Licensed` grants no distribution rights. Public distribution
requires the project's licensing/redistribution decisions, actual update
hosting and successful release/hardware qualification.
