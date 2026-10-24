# Installer KMS rendering latency — 2026-10-24

The user still experienced delayed typing and a visibly trailing mouse pointer
on the preceding installer-input ISO, on a MinisForum X1 Pro with AMD 370.
They also observe pointer lag in its BIOS. Its monitor model, resolution and
refresh rate are unknown. This record separates a measured installer rendering
cost from unmeasured physical input/display latency.

## Cause and change

The pinned Slint 1.18.1 KMS software backend has three dumb scanout buffers.
Steady-state buffer age is three, but its software renderer only recognises
ages one and two for partial rendering. It consequently repainted the entire
screen on pointer movement, typing and other small updates. Pixel blending
also reads the destination directly in mapped display memory, which can be
write-combined or uncached on physical graphics. The backend exposes that
memory property; its software renderer did not use it.

The Nix package now renders into one aligned cached RAM frame. It reuses that
frame for partial rendering and copies only current physical damage plus the
previous two frames' damage to scanout, without destination reads. New buffers,
unknown ages and layout changes receive a complete cached frame. Pitch, padding,
rotation coordinates and all existing 16/32-bit formats remain supported.
Native resolution, software KMS, hardware drivers and firmware graphics support
are preserved. The added RAM frame uses approximately 32 MiB at 3840×2160×32-bit.
No disk-writing or shared installation/lifecycle behaviour was changed.

`installer/kiosk/kms-shadow.rs` is copied into the build's private Cargo vendor
copy by `nix/packages/installer.nix`; shared dependency sources are not edited.
`SLINT_KMS_NO_SHADOW_BUFFER=1` restores the preceding direct-rendering path for
controlled comparisons. It is unset in the normal image.

## Repeated runtime comparison

A disposable QEMU/KVM UEFI guest booted the preceding ISO on the Beast, an AMD
Ryzen Threadripper 9970X with 64 logical CPUs. The guest had four vCPUs, 12 GiB
RAM, virtio KMS, a USB absolute pointer and PS/2 keyboard. Both 3840×2160 and
1280×800 were verified as the actual display dimensions. The tested package
was exposed through a read-only host store and guest-only writable overlay.
Only a transient guest unit override selected it. No installation ran.

Each resolution used the same binary in direct/cached/direct/cached order.
Each run injected 720 pointer movements over six seconds, followed by 16
pointer input-to-visible observations and ten typed-character observations.
Old pointer regions cleared, every typed character appeared, the daemon draft
ended with the expected character, and every case ended in `phase: setup`,
`diskTouched: false`. Both cases passed. `SLINT_DEBUG_PERFORMANCE` used
`refresh_lazy,console`; full-speed mode would invalidate partial-rendering work.
ISO compression was not running during these comparisons.

Renderer CPU time came from the actual UI PID's `/proc/PID/stat`, at 100 ticks
per second. The service's `CPUUsageNSec` was unsuitable because PAM moves the
renderer into its logind session scope. Repeated runs gave:

- **3840×2160:** direct 5.17/5.22 CPU-seconds; cached 0.17/0.20 CPU-seconds.
  Mean CPU utilisation fell from **86.58% to 3.08% of one core**, a **96.44%**
  reduction in renderer CPU work for the same six-second motion workload.
- **1280×800:** direct 0.86/0.96 CPU-seconds; cached 0.12/0.11 CPU-seconds.
  Mean CPU utilisation fell from **15.17% to 1.92% of one core**, an **87.36%**
  reduction.

The small-region VNC observer introduces emulator/display polling delay.
Pointer medians were approximately 31 ms at 4K and 30 ms at 1280×800 in both
paths. Typing samples showed strongly repeated polling patterns: per-run
medians were 184/162 ms direct and 184/114 ms cached at 4K; 183/113 ms direct
and 183/183 ms cached at 1280×800. These observations verify eventual pixels
and cursor clearing; **they do not establish lower physical input latency**.
The robust measured improvement is renderer CPU work. A VM also does not
reproduce a physical GPU's mapped-memory read penalty. No acceleration factor
for that additional cost is claimed.

Harness corrections before the recorded comparisons included reusing QEMU's
single QMP connection, moving the visible pointer outside the text sample,
and measuring the real process instead of its original service cgroup. These
were harness problems. Product code did not change during the comparisons.

## Exact source and package

The source was frozen before this record was written. All package, updater and
image checks use this same source; no lock was refreshed.

- Frozen source: `/nix/store/ds8ymmaq78n9a67dsvv1vqlzy2lqns8h-source`.
- Source NAR: `sha256-+mDh5Q7JTUrdalLjRlBz/B7LsGaKVtZSJtT6zEMJNI8=`.
- Installer wrapper: `/nix/store/y3s83rf945wfaalvgzbwabbcb9w6004v-nerdos-installer-1.0.0-beta.2`.
- Screen: `/nix/store/ms2ri2ing818rg7ihxd5hhwn8b9h0g57-nerdos-installer-screen-1.0.0-beta.2`.
- The release package build passed all **30 Rust tests**: 20 unit, six rendered
  interaction and four presentation tests. The latter compile the exact copied
  module and cover three-buffer cursor freshness, partial byte counts, missing
  history, unknown ages, reset, clipping, row padding, 16/32-bit layouts and
  layout changes.
- The shared installation-contract check passed.

This remains an unreleased development image. Physical AMD hardware, BIOS/display
latency, Secure Boot, a full disk installation, installed login/encryption and
end-to-end PXE boot are not qualified by these VM and parity checks. The workstation
was not deployed, partitioned or rebooted, and no release was published.

## Completed image

- Filename: `nerdos-1.0.0-beta.2-20261024-installer-latency-fa60e1e50ec9.iso`.
- Size: **7,120,576,512 bytes (6.63 GiB)**.
- SHA-256: `592506a365fb0437f61f4563cd40e373dacfef6f8c4fe20d4bd02e0e64b747e1`.
- Nix output: `/nix/store/4qjigppb2q7rijhnvh7z69z5mal6sl0r-nerdos-1.0.0-beta.2-x86_64-linux.iso`.
- All **39 completed-image/source parity checks** passed against the exact NAR
  above, including the installed screen binary, source identity, shared contract,
  locked inputs, updater, offline payload and UEFI/BIOS boot identities.
- The completed image booted directly in a separate 3840×2160 QEMU/KVM UEFI
  guest. No package was injected, no host store was mounted, and no guest UI unit
  override was used. Its release metadata matched the exact NAR above; the UI
  logged `Using Software renderer (cached RAM with damage copies)`.
- Direct-image runtime exercised 720 pointer events, 16 observed moves with
  old positions clearing, and ten observed typed characters. Both services stayed
  active, the UI PID's warning journal was empty, the final character was `a`,
  and the final state was `phase: setup`, `diskTouched: false`. An actual 4K
  display capture was visually inspected. No installation was started.

## Actual staged updater

The same-source lifecycle driver passed its full original test script in
**640.28 seconds** under TCG, including real software and maintenance-policy
candidate staging to `ready`. It preserved declarations, the machine lock,
personal sentinel and running maintenance policy. Nothing was applied. The
script also exercised desktop validation and the splash/password UI. This is
staged-updater evidence, not an applied update or fresh installation.

- Driver: `/nix/store/q22g5is5jnqn2wqar3is9r0v5mz21cmj-nixos-test-driver-nerdos-lifecycle`.
- Original script: `/nix/store/ia89b6ga5ks1jg6wlb6v6fp472p5zp9n-test-script`.
- Script SHA-256: `501b4cb05ce16109b557b1d8e62a9a4a112a23f3cd78e0fb28a618779be4e5c2`.
- A task wrapper verified this digest and executed the unchanged script. It
  supplied guest-only NAT/DNS immediately before the offline machine-lock
  command, after the original network-profile assertions. All original
  assertions remained intact. The software request completed in 423.86 seconds;
  the remaining policy preview and preservation assertions passed afterward.
- The driver used `QEMU_OPTS=-no-user-config -machine accel=tcg`,
  `QEMU_NET_OPTS=restrict=off` and a private `XDG_RUNTIME_DIR`. Its VM was stopped
  and its runtime directory removed after completion.

An initial invocation required creating the output directory before the driver
would accept it. A subsequent KVM attempt did not expose its backdoor test shell
and was stopped after 131.76 seconds; its cause was not determined. The full
script then passed under TCG. The separate KVM ISO boots above succeeded. A
read-only disposable disk copy was used to inspect the staging phase while TCG
was slow; it reported `building` with no error, and was removed immediately.

## PXE handoff

On **thebeast (`10.10.0.7`)**:

- ISO: `/data/pxe/iso/nerdos-1.0.0-beta.2-20261024-installer-latency-fa60e1e50ec9.iso`
  (**7,120,576,512 bytes**).
- Checksum: the same path plus `.sha256` (**130 bytes**).
- [Download ISO](http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.2-20261024-installer-latency-fa60e1e50ec9.iso).
- [Download checksum](http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.2-20261024-installer-latency-fa60e1e50ec9.iso.sha256).

The completed ISO was copied outside the served directory, synced and compared
with the original build's SHA-256 before being linked atomically into place.
Both served files have mode 0644. iVentoy 1.0.41 refresh returned
`result: success`, completed to `running`, and listed the new filename.
`iventoy.service` was active. A full streamed HTTP download matched SHA-256 and
the downloaded checksum file matched too. No service restart was used.

The preceding image was initially held because client `10.10.1.64` had NBD
connections and its SSH port was unavailable. After the user confirmed that
client was **powered off**, removed:

- `/data/pxe/iso/nerdos-1.0.0-beta.2-20261024-installer-input-9aff22041052.iso`
  (**7,120,576,512 bytes**) and its **128-byte** checksum.

The remaining image's SHA-256 was verified before removal. The first refresh
request timed out after 30 seconds; a subsequent status request reported
`running`. Retrying refresh returned `result: success`, completed to `running`
and listed **only the new ISO**. `iventoy.service` remained active without a
restart. The served directory contains only the new ISO and its checksum; the
removed image and all five older images from the preceding handoff are absent.
Physical latency on the MinisForum remains the next useful test.

## Cleanup

Removed remote staging `/data/tmp/nerdos-kms-latency-20261024-Sy0Mpo` and local
staging `/tmp/nerdos-kms-latency-20261024-6lyjxcjl`, including private vendor
copies, source archives, test harnesses, sparse VM disks, captures, logs and
intermediate evidence. Both staged-test runtime directories were removed;
process and mount checks found no task VM or host mount. Neither host has a
`~/.local/share/nerdos/images` directory. Normal shared dependency/source caches
remain; the exact frozen source above remains a historical validation identity.

After checking the independent served copy, deleted the duplicate Nix ISO output
through Nix: **one output removed, 6,790.71 MiB freed**. The output path recorded
above is historical. After the confirmed client shutdown and older-image
removal, the served directory uses **6.7 GiB** (`du -sh`), consisting only of the
new testing ISO (**7,120,576,512 bytes**) and its **130-byte** checksum. Their
paths are listed in the PXE handoff. No disposable image or unresolved diagnostic
capture is retained.
