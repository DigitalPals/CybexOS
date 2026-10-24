# Installer graphics / beta.2 — 2026-10-23

The Minisforum X1 Pro 370 still showed identical corruption with the previous
7.2.11 ISO. The user confirmed that its separate NerdOS GRUB menu displayed
correctly; corruption began after selecting the live/install entry, before any
desktop. That image did not resolve the physical issue.

## Findings and changes

The previous image has AMD/Intel/Nouveau drivers, Mesa 26.1.8 and the identified
Radeon 890M / Strix Point firmware in its live filesystem, but none of those
native GPU modules or firmware in its initrd. Its early display depends on
the firmware framebuffer. Shared hardware configuration now makes `amdgpu`,
`radeon`, `i915`, `xe`, `virtio_gpu` and, unless NVIDIA's vendor driver is
selected, `nouveau` available to initrd udev. Explicit NVIDIA configurations
load `nvidia`, `nvidia_modeset` and `nvidia_drm` early. This preserves native
graphics and the same installation contract on live and installed machines.

An isolated VM reached Linux through the real iVentoy service using the old
image, then timed out after 90 seconds waiting for `NERDOS_INSTALL`. iVentoy
1.0.41's NixOS hook inserts its NIC/NBD setup before `mount the root` in a
scripted `/init`; it installs no systemd stage-one unit. The old image's
systemd initrd therefore never invokes that setup. The live image now uses
NixOS 26.05's supported upstream scripted initrd; installed systems retain
systemd stage one. Scripted initrd is deprecated upstream and scheduled for
removal in 26.11, so a deliberate future major upgrade must revisit this
transport integration. This does not establish the cause of the physical
framebuffer corruption.

The default live entry retains Linux 7.2.11 and Mesa/Nouveau. A separate
NVIDIA-open entry includes vendor driver 595.71.05, its userspace and firmware,
using the pinned stable/LTS Linux 6.18.57. An actual build of that driver with
7.2.11 failed because it references the removed `strncpy` interface; NVIDIA
support was retained with the supported kernel rather than omitted. The live
NVIDIA profile keeps Intel/AMD drivers and avoids global NVIDIA renderer
overrides or guessed PRIME bus addresses. The installed closed-driver choice
defaults to `legacy_580`; NixOS's branch option remains machine-overridable.
Generation-specific hardware qualification is still required.

Prominent verbose/native-text/firmware-text entries use the same live system
and guided installer. Only the explicitly selected firmware-text entry uses
`nomodeset`. Console ordering keeps serial logging while making the local
screen the primary console. None of the entries automatically partitions a
disk, and Secure Boot and firewall settings were not disabled.

## Exact testing image

- Filename: `nerdos-1.0.0-beta.2-20261023-pxe-gfx-7a36d3d7ccea.iso`.
- Beast path: `/data/pxe/iso/nerdos-1.0.0-beta.2-20261023-pxe-gfx-7a36d3d7ccea.iso`.
- Size: 9,920,796,672 bytes (9.24 GiB); companion checksum: 120 bytes.
- SHA-256: `d73f9bee58d7275f8d1bcc758c83e28b380ca4940cc9c09d7ca9b3479b06410f`.
- Source NAR: `sha256-ejbT18zqTGhcpIRM3QKQLoGiXlLXfJ37kayURMZJ4cw=`.
- Source revision: `uncommitted`; version: `1.0.0-beta.2`; NixOS: 26.05.
- Nixpkgs remains `da6dc0e7b26060f2f71ce3ef7088fb56ee44fa36`.
- [ISO download](http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.2-20261023-pxe-gfx-7a36d3d7ccea.iso)
  and [checksum](http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.2-20261023-pxe-gfx-7a36d3d7ccea.iso.sha256).

The source snapshot was frozen before this result record. Unrelated workspace
work was preserved. This is development media, not an authenticated release.

## Exercised checks

The sandboxed ISO build and shared live/installed installation-contract check
passed. Image/source parity passed for the completed ISO and this exact frozen
source, including all kernel/initrd/system tuples in both boot menus and the
identical menu embedded in the EFI FAT image. Seven parser regression cases
passed, including rejection of mixed profiles, duplicate directives, split
entries and duplicate `init=` parameters.

The completed image's default initrd is 1,464,583,410 bytes and contains the
six native GPU drivers above, including the identified Strix Point firmware.
The NVIDIA initrd is 189,395,231 bytes and contains its vendor modules alongside
AMD/Intel/virtio drivers, without Nouveau. The added early firmware and second
kernel/profile account for the larger image and PXE transfer.

Both normal and NVIDIA menu entries booted the completed ISO as a virtual
optical disk under UEFI/KVM, with an e1000e NIC, virtio graphics and 8 GiB RAM.
They reported 7.2.11 and 6.18.57 respectively, and the exact beta.2 source NAR.
Managed desktop health passed at start/end, including the sole managed
Quickshell instance and current invocation journal; desktop configuration and
live installer checks passed. ZFS loaded and SSH was inactive. The NVIDIA
profile's VM boot exercises its packaging and Mesa fallback on virtio hardware,
not an actual NVIDIA GPU. No disk installation was performed.

### Network-backed iVentoy boot

The completed beta.2 image also reached a healthy desktop through the real
iVentoy service in an isolated UEFI/KVM guest. `/iso` was mounted from
`/dev/nbd0p1` as ISO9660 and `/nix/.ro-store` from `/dev/loop0` as squashfs.
It reported Linux 7.2.11 and the exact beta.2 NAR above. Managed desktop health
passed at start/end; desktop configuration, live installer and ZFS checks
passed, and SSH was inactive. A framebuffer capture visibly showed the desktop
and development-installer consent prompt. No installation was started.

This used QEMU user networking with isolated DHCP/TFTP and a task-owned HTTP
relay, without changing LAN DHCP, iVentoy configuration or the ISO. The first
unmodified NAT attempt failed during network setup: iVentoy recorded the NAT
host address `10.10.0.7` as the client, rather than the guest's `10.0.2.15`.
For the successful follow-up, the guest GRUB command line selected serial as
primary console and added `boot.debug1devices plymouth.enable=0`. In its
stage-one shell the fixture configured the detected NIC as `10.0.2.15/24`,
added gateway `10.0.2.2`, and appended `vtoy_ip_addr=10.0.2.15` to the guest's
`/ventoy/ventoy.env`, then resumed boot. The iVentoy hook subsequently exposed
the NBD medium and boot completed. This establishes working network-medium
integration with that explicit NAT adjustment; it does not establish an
unmodified automatic LAN PXE boot or physical graphics recovery.

### Actual staged updater

The required sandboxed `checks.x86_64-linux.vm` was run on the frozen source
and failed during real software staging. Its offline guest could not resolve
the hosts for missing Python 3.14.4, Bash and Binutils build inputs. The updater
reported `Staging failed; working system retained`. This derivation remains a
failed check.

An isolated online follow-up used the same immutable test driver and complete
original test script, with outbound QEMU networking and a temporary guest DHCP
connection to reach the upstream cache. No source edits, mocked updater,
candidate injection or assertion removals were used. All original assertions
passed in 118.79 seconds. Real supervised `hello` software staging and
maintenance-policy staging reached `ready`, including actual Nix builds,
candidate desktop validation, closure diffs and review tokens. Personal
configuration, machine locks, desired selections and active policy stayed
unchanged. The exact source NAR was verified unchanged before and afterward.

The driver was
`/nix/store/favlf5c70qakvh521g3vhd2ickhs78l4-nixos-test-driver-nerdos-lifecycle/bin/nixos-test-driver`;
the original test-script SHA-256 was
`26acf1baafa2acc73eeedd698a38826421eb6811fc5dfb53d4f7c2ef01e5caa6`.
This exercises `checks.system` staging, with proprietary/Steam/Docker features
disabled, rather than a full product installation or an applied update.

## Delivery and cleanup

The served ISO and companion checksum were verified after copying, and a full
HTTP download matched the SHA-256 above. At the user's request both superseded
beta.1 ISO/checksum pairs were removed:

- `nerdos-1.0.0-beta.1-20261023-ec5fa706073a.iso`
- `nerdos-1.0.0-beta.1-20261023-k7.2.11-68a754171686.iso`

iVentoy refresh returned `result: success`; its final status was `running`,
the image tree contained only the beta.2 filename (image 4), and
`iventoy.service` was active. No service restart was needed.

Only the requested testing ISO (9,920,796,672 bytes) and checksum (120 bytes)
are retained in `/data/pxe/iso`. Task-owned staging/source copies, VM state,
captures, extracted payloads, logs and the duplicate Nix-store ISO output are
removed. Both local and Beast task directories were verified absent, with no
remaining task processes or mounts. The Beast's served ISO tree uses 9.3 GiB
and its staging directory 4 KiB; neither machine has leftover user image output
under `~/.local/share/nerdos/images/`. The source embedded in the delivered
ISO retains the exact build identity. Shared Nix dependencies and unrelated
workspace work are preserved; no workstation deployment or release publication
was performed.

Physical X1 graphics recovery, AMD/Intel/NVIDIA hardware operation, LAN PXE,
fresh disk installation and installed trial/apply/confirmation/rollback remain
separate qualification boundaries. VM success cannot establish these results.
