# Private alpha validation — 2026-09-05

This record predates the rename to CybexOS and keeps the former
`fedora-config` names of the artifacts that were validated.

Validated ISO: `FC-LIVE-44.iso`, Fedora 44, desktop RPM
`fedora-config-desktop-0.1.0-0.1.alpha.fc44.noarch`.

SHA-256:

```text
3358a9dc418154b1ccfa809d00ccf8624d9c706b3571a34c6ddcfc401a2172e1
```

The final artifacts are in `~/.local/share/fedora-config/images/alpha-01/`.
This record applies to this ISO; rebuilds use moving upstream repositories.

| Check | Result |
| --- | --- |
| Six account-isolation and welcome/QML tests | Passed |
| Kickstart validation, including the interactive cleanup hook | Passed |
| ShellCheck and application desktop-file validation | Passed |
| Upstream RPM signature checks during composition | Passed |
| BIOS live boot, welcome and Quickshell audit | Passed |
| UEFI live boot, welcome and Quickshell audit | Passed |
| Graphical Anaconda installation, internet route removed before confirmation | Passed |
| Whole-disk installation with encrypted Btrfs root/home | Passed |
| Installed target cleanup and account/session configuration | Passed |
| UEFI boot from the installed disk without an ISO | Passed |
| Disk unlock, GDM login and installed Hyprland welcome | Passed |
| Installed personalization button and Quickshell audit | Passed |
| ISO/RPM checksums after copying to the delivery directory | Passed |

The installation test used QEMU/KVM with a q35 machine, four virtual CPUs,
8 GiB RAM, virtio graphics, a blank 48 GiB virtual disk, and OVMF without
Secure Boot. The actual Anaconda Web UI was driven through a private SSH
tunnel. Temporary SSH access was added for inspection after boot; the ISO
and installer were not patched during the final test.

Before the first installed boot, the target had no live account, live sudo
or Polkit grants, live startup unit, live dracut configuration, autologin, or
test SSH key. Root was locked and SSH disabled. The installed account had
Hyprland selected in AccountsService. The installed system booted with
SELinux enforcing and encrypted Btrfs mounted at `/` and `/home`.

Each live shell test checked the service MainPID against every `qs` PID and
checked the current invocation's journal for QML errors. The final installed
test began and ended with one healthy service-owned Quickshell process.
Hyprland reported no configuration errors. Qt emitted software-rendering and
portal-registration warnings in the VM; the tested welcome and settings
interfaces rendered and worked.

Diagnostic logs and screenshots are retained under
`~/.local/state/fedora-config/iso-research/`. The delivery directory includes
selected evidence in `validation/`. Test VMs are stopped; temporary host SSH
keys are removed. The final installed test disk is retained separately under
`images/live-test-08/installed.qcow2` for inspection.

Not qualified by this test: physical hardware, Secure Boot, BIOS installation
to disk, dual boot, manual partitioning, recovery, and hardware-specific
graphics or networking. Public distribution also needs a repository license,
redistribution/branding review, and signed desktop RPM update hosting, as
described in [README.md](README.md).

## Testing image rebuild — 2026-09-06

Built the current source with `image/build` and placed the requested testing
image at `/data/pxe/iso/CybexOS-Live-44.iso` (2,293,989,376 bytes). Its adjacent
`CybexOS-Live-44.iso.sha256` records the verified delivery checksum:

```text
23cfb3c10e73955298da1ae156957e9a9d27da9f1a0c43508554f2dac6871061
```

Composition, upstream package signature checks, graphics-package checks,
installer-tool checks, and artifact checksum verification passed. Inspection
with `xorriso` confirmed BIOS and standard UEFI boot entries. This rebuild
has not been boot-tested and does not inherit the previous image's validation.
The optional `mkefiboot` Mac HFS+ image step reported a mount failure; Mac boot
support is unverified. Temporary build outputs, logs, and the builder VM
workspace were removed; only the ISO and its checksum were retained.

## Complete offline application image — 2026-09-06

Testing image: `/data/pxe/iso/CybexOS-Live-44-full-apps-20260906.iso`
(7,181,475,840 bytes, 6.69 GiB), with an adjacent `.sha256` file.

```text
440618fa5115b5939016e5b33143bcd46bc334c2387e849d3cbadfbc1c1e26d2
```

This image includes 140 explicit native application package selections,
1,693 installed RPMs including dependencies, all three configured Flatpaks
and their runtimes, and the offline user application/toolchain seed.
The application and CLI are named `cybex`; `fedora-config` remains a
compatibility command.

| Check | Result |
| --- | --- |
| All 16 source-check stages, 11 image tests, and 3 application-default tests | Passed |
| Upstream signatures, pinned payload checksums, and complete application manifests | Passed |
| Uninterrupted UEFI live boot with outbound networking blocked | Passed |
| Fastfetch, AI CLIs, Rust, Android tools, Neovim, T3 Code digest, and dictation model offline | Passed in live and installed accounts |
| Graphical Anaconda installation onto a blank 100 GiB virtual disk, entirely offline | Passed |
| Graceful shutdown and UEFI boot from the installed disk without a CD-ROM | Passed |
| New-account Hyprland session, installed welcome, and live-account cleanup | Passed |
| Sole service-owned Quickshell process and current journal audit | Passed before and after live/installed checks |
| SELinux enforcing, no Hyprland configuration errors, Docker and Tailscale active | Passed |
| Delivered ISO checksum and iVentoy refresh/list/service checks | Passed |

Tests used QEMU/KVM, four virtual CPUs, 16 GiB RAM, virtio graphics and OVMF
without Secure Boot. The installed root and home use Btrfs. The test harness
now allows 150 seconds for first-login seed copying and flushes guest writes
before stopping a held VM. The final installation was shut down normally;
abruptly stopping an earlier test had lost its final unflushed filesystem
changes. No image modification was needed for the successful repeat.

Temporary builder/test VMs, disks, logs, screenshots, and duplicate build
outputs were removed. Only the delivered ISO and checksum remain from this
build. Existing PXE images were preserved, and iVentoy remained running.
Physical hardware, Secure Boot and BIOS installation were not tested for
this image.

## Simple installer VM installation — 2026-09-25

Build `20260925T140839Z-5f33cb32` from commit `a2d31c2`, published as
`CybexOS-Live-44-20260925T140839Z-5f33cb32.iso`.

SHA-256:

```text
c8d527fef5628ffbf575414e962d27a44af483869a14d1a1703b79d96cad142b
```

This was a manual run on the PXE host, not `image/qualify`, which needs
Tesseract there. The VM booted the ISO's kernel with a serial debug shell to
enable SSH, launched `liveinst` inside the live Hyprland session and drove
`cybexos-installer-backend` with the page's requests.

| Check | Result |
| --- | --- |
| Inventory, geolocated timezone (Europe/Amsterdam), live keyboard | Passed |
| Plan and confirmation of encrypted Btrfs on a blank 100 GiB virtual disk | Passed |
| All 41 Anaconda steps, both CybexOS `%post` scripts | Passed |
| Target policy: verified encrypted root, `autologin: true` | Passed |
| UEFI boot from the installed disk, passphrase, automatic login to the welcome window | Passed |

The previous build failed at "Running post-installation scripts":
`firewall-offline-cmd --set-default-zone=cybexos` exits 16
(`ZONE_ALREADY_SET`) because the live image already defaults to that zone.
Anaconda then skipped the rest of both scripts plus its log copy and SELinux
context tasks. Such installations boot, but show the SDDM greeter.

Tests used QEMU/KVM, eight virtual CPUs, 16 GiB RAM, virtio graphics and OVMF
without Secure Boot. Keyring unlock, logout/crash recovery, physical hardware
and BIOS installation were not tested. The VM, its disk and screenshots were
removed.
