# Hardware and security qualification

The supported target is fresh x86_64 UEFI NixOS 26.05. Current implementation
status is developmental. This document distinguishes declarations from tested
hardware support; no physical hardware was qualified during this implementation.

| Area | Native implementation | Qualification still required |
| --- | --- | --- |
| Generic desktop | Hyprland pinned by the documented compatibility overlay; Quickshell and Qt from machine Nixpkgs; PipeWire, portals, Bluetooth, Gutenprint/free HPLIP printing and scanning, Orca/AT-SPI/speech-dispatcher, IBus typing booster, firmware/microcode, NetworkManager | Installed compositor/titlebar runtime, real login, suspend/resume, external displays and peripheral matrix |
| Encryption | LUKS2 root, ext4, separate ESP, zram; runtime ancestry verification gates automatic login | Encrypted fresh install/first boot, wrong/missing unlock, every persistent storage branch and swap |
| Login/authentication | Password-only SDDM login; GNOME Keyring; fingerprint/FIDO2 alternatives for sudo, Polkit and lock with password fallback; no crash relogin | Physical readers/keys, PAM failure paths, keyring unlock and lock-before-suspend |
| Firewall | Enabled; LocalSend 53317 TCP/UDP and mDNS 5353 UDP; gaming ports explicitly opt-in | Packet-level tests, VPN routing, application/container interactions |
| NVIDIA | NixOS packaged driver, explicit open-module choice, modesetting/power options | Representative supported GPUs, hybrid graphics/PRIME choices, suspend, signing with Secure Boot |
| Dell XPS 2026 | Exact DMI/SKU 0DB9/0DBA, Panther Lake, panel EDID and sensor gates; latest Nixpkgs kernel, OLED quirks, haptics, speaker filter, adaptive thermald and Intel LPMd | Both SKUs, panel variants, audio routing/limiter, repeated suspend/hotplug, fingerprints |
| XPS processed camera | Pinned Intel HAL/bins/icamerasrc and PSYS companion; native ISYS/core/CVS stay upstream; private-layout guard before PSYS load | Current kernel BTF/private ABI, HAL paths, v4l2 relay, actual processed frames, camera privacy and suspend/resume |
| Secure Boot | Native Lanzaboote option and runtime signing-key path; firmware verification is never disabled | Signed installation media, safe enrollment, key backup/rotation/revocation, NVIDIA/camera module signing and physical boot qualification |

Secure Boot installation currently stops before erasure. It is not supported
merely because Lanzaboote evaluates. Existing firmware verification must not be
disabled to get the installer to boot. Keys belong in
`/var/lib/cybexos/secrets/secureboot` with root-only permissions, outside the
store and source. Completing signed media, enrollment and module signing is a
release blocker, not an optional post-release improvement.
The kernel must enforce the intended signing/lockdown policy, and installation
media must authenticate its external compressed system payload as well as its
boot executable. A signed UKI alone does not establish either property. No
Secure Boot or tamper-resistance qualification is claimed.

NVIDIA driver selection is independent of proprietary applications. Selecting
the driver permits only its required unfree NVIDIA packages even with the
proprietary application group disabled; the open kernel module still needs
proprietary userspace. PRIME offload keeps the integrated GPU as the desktop
renderer and exposes explicit offload for applications.

The XPS camera recipes retain the processed ISP path rather than presenting a
raw sensor node as a working camera. A sensor name or loaded driver is not
capture qualification. The guarded external companion must never shadow an
upstream core/ISYS/CVS module. An absent/unreviewed BTF layout refuses loading.
Do not extend a reviewed layout signature based only on a matching kernel
version. Compare compiled structure sizes/offsets and test actual frames.
On the selected physical camera system, explicitly run
`xps-ipu7-camera-frame-check --device /dev/video50` with the actual processed
relay device. It skips warm-up buffers and requires complete, changing frames
in memory. It never saves images or runs automatically; a static scene can
require moving an object to prove freshness. Its source fixtures do not
qualify physical capture.
On the currently selected Linux 7.3 kernel, the compiled stock BTF reports an
`ipu7_bus_device` size of 1008 bytes with `auxdrv` at offset 872. Neither
reviewed signature accepts this layout; Linux 7.2.11 has the same mismatch.
A task-local unstripped PSYS build matched the stock layout for eight inspected
structures, but the ninth could not be parsed and no processed frames were
available. That probe does not authorize extending the signature. The managed
ABI service fails closed and blocks camera initialization and update health
confirmation on this configuration. This is a concrete XPS camera release
blocker, despite the complete XPS system building successfully. Do not disable
the guard or omit the camera profile to qualify a machine that has that camera.

The relay retains the `ov08x40-uf` sensor, 180-degree rotation and 1920x1080
NV12 output. Initialization acquires CVS before probing the sensor; suspend
quiesces the relay and resume reruns initialization without unloading upstream
core, ISYS or CVS. Raw ISYS nodes lose the desktop uaccess grant before seat
ACL processing. These declarations still require privacy and capture tests.

Pinned vendor camera sources need requalification at every relevant kernel/HAL
change and should be removed when Nixpkgs supplies the full processed stack.

The exact XPS profile enables adaptive thermald alongside Power Profiles
Daemon. Intel LPMd 0.1.0 is a narrowly pinned native package because the selected
Nixpkgs lacks it; remove the recipe when Nixpkgs supplies a maintained package.
Its upstream Panther Lake policy and platform checks remain intact: the M204
profile does not restrict CPUs under PPD, but supplies the SoC power slider.
Do not infer measured power savings from the daemon being installed. LPMd,
thermald and camera initialization participate in system health checks when
applicable; power, thermal safety and repeated sleep require physical tests.

AppArmor, restricted kernel inspection/ptrace, sudo authentication and Polkit
remain enabled. The replaced system qualified SELinux in enforcing mode.
Enabling AppArmor on NixOS does not reproduce that broad mandatory access
control policy: the current explicit application exception supports Chromium
user namespaces and is not equivalent service/application confinement. A
reviewed native confinement policy, enforced-profile/process coverage and
negative access tests are still required before release. Do not report the
AppArmor enable flag as security parity. This is a separate security release
blocker alongside Secure Boot. Login passwords are initialized through stdin in the target;
subsequent `passwd` changes persist across rebuilds. No login password/hash is
embedded in Nix source. Runtime VPN/credential files use root-private paths or
NetworkManager's persistent secret storage. Nix evaluation/build logs can contain
administrator-supplied module text: keep secrets out of declarations as well as
out of Git. The updater only exposes private logs after administrator authentication.

Settings enrolls/removes fingerprints and security-key credentials through their
persistent APIs. Authentication policy belongs to personal NixOS modules:
set `cybexos.authentication.fingerprint = true;` or `false`, then preview with
`cybex update stage local` and apply the reviewed transaction. Settings displays
the active policy without offering a switch that bypasses the staged lifecycle.
Firmware has a separate explicit action in the Update drawer; its device writes
are outside Nix generations and cannot be undone by a system rollback.

NetworkManager's OpenVPN, OpenConnect, SSH and maintained Libreswan plugins are
included. Libreswan supplies Cisco-compatible IKEv1/IPsec, as recommended by
[GNOME's security notice](https://blogs.gnome.org/mcatanzaro/2026/09/15/privilege-escalation-vulnerabilities-in-networkmanager-plugins/).
The archived networkmanager-vpnc 1.4.0 remains vulnerable to
CVE-2026-91840/91841 and is excluded; insecure packages are not globally
permitted. Real Cisco gateway authentication, routing, DNS and reconnect still
require qualification. The native wrapped T3 Code AppImage builds but needs runtime
qualification; native titlebar/compositor integration is still being completed.
Connected account services and the Hermes bridge have native declarations;
their real account/credential flows remain unqualified. Installing a related
command is not proof of product parity. See the current
[validation record](validation.md).
