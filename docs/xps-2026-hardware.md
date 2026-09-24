# Dell XPS 2026 / Panther Lake hardware support

The `xps-2026` role is intentionally narrow. It runs only when DMI reports
Dell, XPS 14/16 or DA14260/DA16260, SKU `0DB9` or `0DBA`, and a Panther Lake
Core Ultra CPU. Camera and touchpad work have additional ACPI, PCI, and I2C
gates. It does not apply these settings to other Dell laptops.

Fedora's stock kernel remains the only kernel. This role does not build or
install a kernel, `linux-ptl`, an i915/xe/DRM patch, `fred=on`, or a global
Wi-Fi 7/EHT workaround.

## Internal OLED backlight

The LG 2880x1800 OLED panel with EDID product `30e4` accepts brightness writes
through the Xe driver's default interface without changing its luminance; only
the separate zero/off operation has an effect. The same XPS chassis can contain
an IPS panel, so the role reads the internal eDP EDID and limits the workaround
to that exact OLED product.

For the affected panel, every installed Fedora boot entry receives
`xe.enable_dpcd_backlight=1` through `grubby`. This makes Xe probe the standard
VESA DPCD path, which the panel implements correctly. The kernel log's generic
suggestion of `i915.enable_dpcd_backlight=3` is not used: Panther Lake runs the
`xe` module here, and forcing the Intel HDR path leaves this panel frozen.
`grubby --update-kernel=ALL` also updates `/etc/default/grub` and
`/etc/kernel/cmdline`, so later Fedora kernel entries inherit the argument.

The change takes effect only when Xe next loads. After applying the role,
reboot normally and verify:

```bash
grep -o 'xe.enable_dpcd_backlight=[^ ]*' /proc/cmdline
sudo cat /sys/module/xe/parameters/enable_dpcd_backlight
brightnessctl set 40%
```

The first two commands should report `xe.enable_dpcd_backlight=1` and `1`; the
last should visibly change panel luminance.

## Internal speakers

SKU `0DB9` (plus Quattro-listed XPS 16 SKU `0DBA`) gets Omarchy Quattro's current
13-biquad-per-channel profile and stereo lookahead limiter. A separate user
PipeWire process hosts the graph, so a broken optional profile cannot prevent
the normal PipeWire daemon from starting. Its output is pinned to the exact
`sof_sdw` internal-speaker sink. Headphones, Bluetooth, HDMI/DP, USB, and
network sinks bypass it. At login the manager waits for four consecutive
observations of the physical speaker, avoiding WirePlumber's initial device
enumeration churn without masking a genuinely absent sink.

The XPS 14 profile was measured on `0DB9`; `0DBA` is included on the same basis
as Quattro and has not been independently measured here. Fedora provides the
filter-chain LV2 loader and `lsp-plugins-lv2` limiter. Desktop volume keys and
the Quickshell audio UI control the physical speaker gain while the virtual
filter master stays at unity.

Useful checks:

```bash
systemctl --user status xps-speaker-tuning
/usr/local/libexec/xps-speaker-tuning check
pactl list sinks short
journalctl --user -u xps-speaker-tuning -b
```

## Optional fingerprint reader

Fingerprint setup is separately hardware-gated. The detector trusts explicit
fingerprint/biometric product descriptors and uses a conservative, unbound-USB
vendor fallback. It explicitly rejects Synaptics `06cb:0701` (SVP7500), which
is the IPU7 camera's USBIO bridge on the tested XPS 14 rather than a fingerprint
reader. The tested SKU `0DB9` exposes that bridge but no fingerprint device to
current `libfprint`, so the role makes no fingerprint package or PAM changes on
that machine.

If another precisely matched XPS build has a real reader, the role installs
Fedora's `libfprint`, `fprintd`, and `fprintd-pam` packages. It asks fprintd over
D-Bus whether the current libfprint release supports the device before enabling
Fedora's managed `authselect` feature `with-fingerprint`. It never edits PAM
files directly, does not enable the static D-Bus service manually, and keeps
`pam_unix` password authentication as the fallback. No fingerprint is enrolled
during Ansible.

Enroll and test one interactively afterward:

```bash
fprintd-enroll
fprintd-list "$USER"
fprintd-verify
authselect current --raw
/usr/local/libexec/xps-fingerprint-check "$USER"
```

SDDM recovery login retains Fedora's stock password PAM stack. Fingerprint
login through its greeter is not qualified; GDM's former dedicated fingerprint
conversation is not part of the replacement. Hyprlock continues to use the
system PAM configuration with password authentication available as the
fallback. Fedora has no stock `authselect` feature for inserting a lid-state
command into PAM, so the role does not copy Omarchy's custom clamshell helper.
This does not matter on the tested `0DB9` without a reader; on a future
reader-equipped configuration, password remains available when the reader is
inaccessible.

## OVTI08F4 / IPU7 camera

The camera role additionally requires the `OVTI08F4` ACPI device and Intel PCI
ID `8086:b05d`. Fedora 44 supplies the stock IPU7 base/ISYS modules, IPU bridge,
OV08X40 sensor driver, and `intel/ipu/ipu7ptl_fw.bin`. Those remain owned by the
normal Fedora kernel and `intel-vsc-firmware` packages. Verification rejects an
out-of-tree replacement for either `intel_ipu7` or `intel_ipu7_isys`.

Two missing hardware companions use DKMS:

- Intel IPU7 PSYS, compiled in PSYS-only mode against Fedora's stock core ABI.
- Intel CVS, which acquires Panther Lake's camera power/ownership path before
  the OV08X40 sensor probes.

RPM Fusion's `akmod-v4l2loopback` supplies the third out-of-tree module. Intel's
HAL, redistributable IPU75XA libraries, and `icamerasrc` are built into the
local `xps-ipu7-camera-stack` RPM. `v4l2-relayd` publishes their processed NV12
stream as `/dev/video50`; WirePlumber hides raw Bayer ISYS nodes and the
duplicate generic libcamera endpoint, then exposes only **Hardware ISP
Camera** to PipeWire. Brave is launched with `PipeWireCamera` enabled.

The source inputs are immutable archives with SHA-256 checksums in
[`roles/xps-2026/defaults/main.yml`](../roles/xps-2026/defaults/main.yml):

| Component | Pinned commit | Why it is needed |
| --- | --- | --- |
| [intel/ipu7-drivers](https://github.com/intel/ipu7-drivers) | `a88b19096a738d0708742a78d6540d6d4a3021ff` | PSYS companion absent from Fedora's stock module set |
| [intel/vision-drivers](https://github.com/intel/vision-drivers) | `a8d772f261bc90376944956b7bfd49b325ffa2f2` | Panther Lake CVS ownership driver |
| [intel/ipu7-camera-bins](https://github.com/intel/ipu7-camera-bins) | `403c67db6b279dd02752f11db6a34552f31a3ac5` | Intel's redistributable IPU75XA userspace interface |
| [intel/ipu7-camera-hal](https://github.com/intel/ipu7-camera-hal) | `b1f6ebef12111fb5da0133b144d69dd9b001836c` | Hardware ISP HAL and sensor configuration |
| [intel/icamerasrc](https://github.com/intel/icamerasrc) | `4fb31db76b618aae72184c59314b839dedb42689` | GStreamer source consumed by `v4l2-relayd` |

The PSYS patch is deliberately limited to the companion module: it removes an
out-of-tree debugfs structure member that is not present in Linux 7.1's stock
IPU7 core and prevents DKMS from compiling or installing base/ISYS. Before each
DKMS build and camera start, `xps-ipu7-abi-check` reads Fedora's in-tree module
BTF with `pahole` and compares the private `ipu7_device`, `ipu7_bus_device`, and
`ipu7_psys_pdata` layouts that PSYS dereferences. This structural guard is not
tied to an exact kernel version. If Fedora changes that internal ABI, it emits
`IPU7_STOCK_ABI_CHANGED` and refuses the optional camera build/start while
leaving the stock modules and normal kernel update path untouched.
It also refuses DKMS if a future Fedora kernel starts shipping PSYS or CVS
itself, preventing the optional bundle from shadowing a new native companion.

The complete build-input hash is embedded in the RPM release, its installed
manifest, and both DKMS package versions. Consequently, changing a source pin,
patch, ABI guard, spec, or build recipe while retaining the human bundle
version still creates fresh PSYS/CVS registrations and forces real module
builds. Before replacing a healthy stack, the builder retains one checksum-
verified copy of the exact installed RPM. Immediately before any DNF operation
that would change NEVRA, the role re-verifies that snapshot against the healthy
installed identity. This is a hard precondition: an interrupted rerun with a new
cached RPM and an old installed RPM may use the already durable snapshot, but it
cannot proceed when that snapshot is absent or mismatched.

The role then writes and syncs `/var/lib/xps-hardware/ipu7/transaction.in-progress`
before removing the relay trigger and stopping/disabling camera exposure. Both
the init unit and relay refuse to run while that marker exists. A successful new
stack is validated against its exact manifest before the committed identity is
written and synced; only then is the in-progress marker removed. If older IPU
modules are already loaded, the target remains uncommitted, hidden, and disabled
through one normal reboot. Rerunning the camera tag after that reboot proves the
new on-disk modules are now the boot boundary, then commits and exposes them. A
failed userspace, akmods, or DKMS refresh reinstalls the snapshot, force-builds
both prior DKMS modules, and performs the same exact validation before clearing
the marker. The init helper also compares the installed identity with
`committed-identity`, so interruption, marker corruption, or an unprovable
rollback leaves the relay hidden and camera service stopped rather than exposing
a mixed stack.

On a later Ansible invocation, the role recovers the prior identity, target
identity, target NEVRA, and exact prior NEVRA from the checksummed marker and
rollback snapshot; it does not infer them from whether systemd remains enabled.
The builder refuses changed input hashes while that transaction is unresolved
and never rotates its recorded rollback RPM. This permits an exact rollback
after interruption at the exposure, DNF, or DKMS boundary without letting a
missing snapshot reopen package installation. Historic target NEVRAs are
validated against the role-owned package/release shape and their recorded
manifest prefix, not the repository's current bundle version, so a legitimate
bundle bump cannot make an interrupted prior transaction unrecoverable.

The local RPM is also validated before packaging. Every staged `libcamhal`, HAL
plugin, `libgsticamerasrc`, private icamerasrc interface, and included IPU75XA
binary library is inspected with `readelf` and `ldd`. Missing dependencies fail
the build, and private dependencies must resolve inside the new stage rather
than through an older installed camera RPM. The validator also requires the
OV08X40 AIQB, graph binary, sensor JSON, and common HAL configuration under
`/etc/camera/ipu75xa`. Runtime checks repeat the closure validation. Camera
source, ABI, dependency, or build failures remain non-fatal to the rest of
Ansible and are recorded in `/var/lib/xps-hardware/ipu7/build-failed.log` or
`/var/lib/xps-hardware/ipu7/abi-failed.log` or
`/var/lib/xps-hardware/ipu7/dkms-failed.log`. The ABI preflight runs before the
role prunes or upgrades any previously installed camera DKMS bundle.

### Secure Boot and kernel updates

DKMS and RPM Fusion akmods share `/etc/pki/akmods`. With Secure Boot enabled,
enroll that public key once:

```bash
sudo mokutil --import /etc/pki/akmods/certs/public_key.der
```

Choose a temporary password, reboot, and use the firmware MOK manager to enroll
the key. Then rerun the role from the active release:

```bash
ansible-playbook site.yml -e @/etc/cybexos/config.yml --tags xps-2026
```

The role does not disable Secure Boot. A DKMS update made while old camera
modules are loaded is not force-unloaded: the camera and relay stay disabled
behind the transaction marker. Reboot normally, then rerun the same command;
that post-reboot pass validates, commits, and starts the new signed modules.

`kernel-devel-matched` keeps builds tied to Fedora's installed kernel. Diagnose
the complete path with:

```bash
dkms status
modinfo -n intel_ipu7 intel_ipu7_isys intel_ipu7_psys intel_cvs
systemctl status xps-ipu7-camera xps-ipu7-camera-init v4l2-relayd@ipu7
journalctl -k -b | grep -Ei 'ipu7|intel_cvs|ov08x40'
/usr/local/libexec/xps-ipu7-abi-check "$(uname -r)"
/usr/local/libexec/xps-ipu7-userspace-check
/usr/local/libexec/xps-ipu7-camera-check
```

The normal check does not turn on the camera. To request a short three-frame
smoke test explicitly:

```bash
XPS_CAMERA_FRAME_TEST=1 /usr/local/libexec/xps-ipu7-camera-check
```

The Fedora package's unused generic `icamerasrc` generator trigger is removed
on this hardware; the role's `ipu7` relay is the only camera relay instance.
The suspend hook stops only the userspace relay before sleep and restarts it
through a managed, restartable oneshot service after resume. A pending resume
job is cancelled before another sleep transition, so rapid suspend cycles and
suspend-then-hibernate cannot collide on a transient unit name. The hook avoids
fragile module unload/reprobe operations.

## Haptic touchpad

The existing Fedora controller power rules are retained. The hardware-specific
daemon now pairs the matching 06CB input and hidraw devices, applies both the
surface/physical-button feature and a configurable intensity, retries across
device disappearance/re-enumeration, and reapplies after physical clicks. It
rereads its configuration on SIGHUP (`systemctl reload xps-haptic-touchpad`)
or a restart; a converge that changes the configuration restarts it. It reads
HID features back when the transport supports that operation; this XPS
firmware may expose them as write-only.

Set `xps_2026_haptic_intensity` to `low`, `mid`, or `high` in inventory. These
map to the controller's values 10, 50, and 100. Check it with:

```bash
systemctl status xps-haptic-touchpad
sudo /usr/local/libexec/xps-haptic-touchpad --check
journalctl -u xps-haptic-touchpad -b
```

## Media, firmware, and wireless regulation

The role explicitly installs SOF/audio, Intel GPU/VSC/Wi-Fi firmware, the Intel
media driver, oneVPL's `libvpl` dispatcher and `intel-vpl-gpu-rt`, and
`wireless-regdb`. It does not add `libvpl-devel` solely for runtime support;
source-build dependencies for the hardware-gated camera RPM are installed only
when that camera is detected.

Fedora's `setregdomain` (resolved through `PATH`, currently packaged under
`/usr/bin`) derives the regulatory country from the configured
`Europe/Amsterdam` timezone; no Arch-style override is installed.
`./verify` requires the effective global and self-managed phy domains to be
`NL`. Wi-Fi 7/EHT remains enabled.

```bash
command -v setregdomain
iw reg get
```

## Intentional stock-kernel gap

Omarchy Quattro's Panther Lake kernel and its three display patches are not
ported. Until equivalent code reaches Fedora's normal kernel, Panel Replay and
VRR behavior may lag Quattro. Closing that display-only gap would require the
custom kernel work explicitly excluded by this repository; speaker, camera,
touchpad, media firmware, and regulatory support do not require it.
