# Startup investigation and measurement

Reference inspection uses Omarchy `v4.5.0-rc1` at
`03ff1eff3812933f7088484533784d2f63eaf19a`, specifically its Limine configuration
and the two binfmt unit overrides. CybexOS retains GRUB, Plymouth, authentication,
encryption, recovery and Docker socket activation.

The one-second Omarchy Limine setting is a menu timeout. It is not a complete
boot measurement. CybexOS's live-media kickstart has a five-second boot menu;
that does not establish an installed system's effective GRUB delay. Installed
Fedora's saved environment, failed-boot handling, detected operating systems and
recovery entries must be observed before changing their timeout policy. No GRUB
or binfmt policy is changed on an unmeasured hypothesis.

In the actual Fedora 44 test package, systemd-binfmt orders after both the mount
and automount but does not pull in the mount. Omarchy's eager-mount hypothesis
is structurally relevant; a container cannot show whether it shortens this
machine's critical path. It is not applied without repeatable boot evidence.
Binfmt support for containers and emulation remains enabled.

`hyprland-session-start` publishes the complete session environment, starts the
session target, then sleeps one second before restarting portals. Quickshell
starts through the target before that sleep. Removing it cannot be described as
a one-second improvement to the first usable desktop. A socket existing alone
also does not prove portal/screen-sharing readiness. The fixed grace remains
until a bounded replacement is qualified with actual portals.

## Reproducible evidence

Run `python3 scripts/startup-evidence.py capture --help` on an authorized CybexOS
test installation. Capture performs read-only diagnostics; it never reboots,
stops services or changes boot configuration. It records system/user
systemd-analyze time, blame and critical-chain, selected monotonic unit
milestones, the selected session journals, GRUB environment, binfmt unit text
and exact desktop packages. Firmware/loader timings may be unavailable on some
firmware; unavailable diagnostics are retained as failures, not invented zeros.

A desktop-ready observation must establish a rendered bar and a successful
launcher interaction with a responsive compositor. A portal-ready observation
must separately exercise a file picker and a screen-sharing selection. Record
the observer log and monotonic boot-relative times; a unit becoming active or a
long blame entry alone is insufficient. Disk unlock/login time is recorded
separately. Do not silently subtract human delays from a different milestone.

Collect at least three independent boots for the baseline and candidate on the
same hardware and configuration. Label cold/warm boot and first/normal login
explicitly. Keep seeding and normal login separate. Use the exact source
revision and record kernel, packages, monitor setup, encryption, power source
and bootloader state. `startup-evidence.py compare --before ... --after ...`
reports median/minimum/maximum, refusing mixed hosts/configurations, repeated
captures of one boot, missing observed milestones and fewer than three boots.
It also requires a captured kernel and successful dependency inventory, rejecting
different kernels or desktop package versions even when configuration labels
match. The accepted comparison includes those exact versions for review.
The comparison cannot prove the observation supplied by its caller; retain the
referenced observer evidence for review.

## Qualification status

Baseline source checks run on a disposable Fedora 44 container with the
qualified Hyprland/Quickshell builds. The Debian host has no CybexOS user
session (`quickshell.service` inactive). Container startup is not a boot sample.
Full boot, unlock, login, portal/screen-sharing, shutdown and recovery timings
remain unmeasured until an isolated installed VM or authorized representative
hardware completes the protocol above. No speedup is claimed and no ineffective
performance patch is retained. Native compositor and QML qualification are
tracked separately in the desktop validation report.
