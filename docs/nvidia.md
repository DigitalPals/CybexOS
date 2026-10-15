# NVIDIA graphics

CybexOS installs NVIDIA's proprietary driver from RPM Fusion automatically
when it finds an NVIDIA GPU. Machines without one are left alone. The driver
is never bundled in the ISO: it is built for the installed kernel after
installation, so the open-source `nouveau` driver runs the desktop until the
first restart with the NVIDIA driver.

## What happens

Both installation paths run the same `nvidia` role:

- a source checkout runs it from `site.yml` (after the applications role,
  `--tags nvidia` or `--tags hardware`);
- an ISO installation runs it from `cybexos-hardware-setup.timer` once the
  network is up after boot, and again after every kernel change, through
  `/usr/libexec/cybexos-configure-installed --hardware`.

The role:

1. detects display controllers (PCI class `03xx`) with vendor `10de` from
   sysfs. A laptop that also has an Intel or AMD GPU is treated as hybrid;
2. installs `akmods` and `mokutil`, and creates the akmods signing key before
   anything is built, so the module is signed for Secure Boot;
3. enables RPM Fusion free and nonfree with the applications role's
   fingerprint-checked keys (`roles/apps/tasks/rpmfusion.yml`);
4. installs `akmod-nvidia`, `xorg-x11-drv-nvidia-cuda-libs` (NVDEC/NVENC for
   FFmpeg and OBS) and `libva-nvidia-driver` (Fedora's name for
   `nvidia-vaapi-driver`, VA-API decoding for browsers and mpv), plus the
   running kernel's `kernel-devel` when it is still available;
5. builds the module for the running kernel with `akmods` and verifies it with
   `modinfo`. `akmods` waits for the package's own background build;
6. with Secure Boot enabled, queues the akmods key for enrollment (below);
7. records the outcome in `/var/lib/cybexos/nvidia-status.json`.

A failure in any step is recorded, shown, and never fails the rest of the
installation. RPM Fusion's `nvidia-fallback.service` loads `nouveau` whenever
the NVIDIA module is missing at boot, so a failed build, an unenrolled key or
a new kernel without a module still starts the desktop.

Kernel mode setting: driver 560 and later enable `nvidia-drm.modeset` and
`nvidia-drm.fbdev` by default (the current RPM Fusion driver for Fedora 44 is
615). When the loaded driver reports either as off, the role adds
`nvidia-drm.modeset=1 nvidia-drm.fbdev=1` with `grubby` and asks for a
restart. An explicit `nvidia-drm.modeset=0` on the kernel command line is left
as it is.

## Secure Boot

CybexOS never disables Secure Boot. When it is enabled and the akmods key
(`/etc/pki/akmods/certs/public_key.der`) is not enrolled yet, the role runs
`mokutil --import` with a one-time password of eight digits (the MOK manager
uses a US keymap; digits are typed the same on every common layout). The
password is kept in `/var/lib/cybexos/nvidia-mok.json`, readable by root and
the `wheel` group only, and removed once the key is enrolled.

To finish, restart. At the blue **MOK management** screen choose
**Enroll MOK**, **Continue**, **Yes**, type the password, then **Reboot**.
The password is shown

- in a desktop notification, once per boot, until the driver runs;
- in the welcome window's setup list on ISO installations;
- by `sudo cat /var/lib/cybexos/nvidia-mok.json`.

If the MOK screen times out, the request lapses and the open-source driver
stays in use. The boot-time setup does not ask again on every restart; request
it again with `cybex repair --hardware` (ISO) or
`cybex install -- --tags nvidia` (source checkout). The same key signs the
XPS camera modules, so one enrollment covers both.

## Hybrid laptops

The integrated GPU (the firmware's boot display device) stays the renderer
for Hyprland and applications. `switcheroo-control` is enabled, so launchers
can start an application on the NVIDIA GPU. Only `NVD_BACKEND=direct` is set
for the session; the NVIDIA-only variables below would move rendering to the
dGPU and break VA-API on the integrated GPU.

## Session variables

The role writes `/etc/cybexos/nvidia-session.env`. Both session wrappers
(`hyprland-quickshell`) read it as data, accept only the names below, and
apply it only while `nvidia_drm` is loaded, so a boot that fell back to
`nouveau` never inherits NVIDIA settings. The variables are exported to
Hyprland and imported into the user manager for the shell and its launches.

| Variable | NVIDIA-only desktop | Hybrid laptop |
| --- | --- | --- |
| `LIBVA_DRIVER_NAME` | `nvidia` | not set |
| `__GLX_VENDOR_LIBRARY_NAME` | `nvidia` | not set |
| `NVD_BACKEND` | `direct` | `direct` |

`GBM_BACKEND` is not set: Mesa selects the NVIDIA GBM backend from the DRM
driver name, and forcing it is a known cause of browser crashes.

## Status and troubleshooting

| State | Meaning |
| --- | --- |
| `ready` | The NVIDIA driver is loaded for the running kernel. |
| `reboot` | The driver is built; restart to switch from `nouveau`. |
| `enroll` | Secure Boot key enrollment is pending (or was skipped). |
| `failed` | Packages, the build or the key request failed; `reason` says why. |

- `cybex doctor` reports an `nvidia` check on ISO installations;
  `cybex verify` does on source checkouts. Neither prints the password.
- `/usr/local/libexec/cybexos-nvidia status` prints the recorded outcome,
  corrected for a restart since it was written.
- Build logs: `/var/cache/akmods/nvidia/*-for-$(uname -r).failed.log`.
- Boot logs: `journalctl -b -u akmods.service -u nvidia-fallback.service`
  and, on ISO installations, `journalctl -b -u cybexos-hardware-setup.service`.
- `cybex report` collects these into a redacted bundle for a bug report.

Uninstalling a source checkout removes the helper and the session variables
but keeps the driver and the akmods key: the machine's graphics depend on
them. Remove `akmod-nvidia` with `dnf` if you no longer want the driver.

Physical NVIDIA hardware, hybrid switching and the MOK enrollment screen are
not covered by the VM qualification; verify them on real machines.
