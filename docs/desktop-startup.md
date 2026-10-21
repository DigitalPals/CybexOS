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

Source checks pass in a disposable Fedora 44 container with the qualified
Hyprland/Quickshell builds. The Debian host has no CybexOS user session
(`quickshell.service` inactive); container startup is not a boot sample.

Actual baseline 3b310d1 installed boots and superseded candidate 63f7785
installation scenarios were exercised. The original three baseline probes
failed inventory collection and retained no usable UI frames. Their earlier
offline upgrade also failed because the pristine baseline lacked the newly
required native SDK dependencies. Those failures are preserved. A supported,
artifact-bound offline dependency transport now exists; its installation gate
is independent of startup comparison.

One superseded 63f7785 first encrypted login reported systemd startup of 27.949s
(kernel 0.626s, initrd 18.853s, userspace 8.469s; graphical.target at 8.442s of
userspace). This is a diagnostic observation with human authentication,
first-login work and console test-access bootstrap. It is not desktop-ready
time, a normal-login series or evidence of improvement. A long ldconfig unit
alone did not establish a recurring critical-path cost.

That run's initial bar frame was black; typing in the launcher rendered a
responsive bar. A single Escape cleared the query without dismissing the
launcher, obscuring the real file picker; the picker and ScreenCast probes did
not complete. No readiness sample or UI attestation was accepted. External
observer corrections now verify two-step dismissal, preserve partial failures,
gate subsequent probes on cleanup and avoid input after terminal portal events.
Fresh independent review passed 61 inert cases, 18 additional race fixtures and
exact baseline/candidate guards. Fixtures do not qualify actual portal pixels.

The final b4dfdf6 encrypted installation ran the observer before settings tests. Inventory and fixed-path root hashes succeeded, the launcher was dismissed, and the normal shell audit passed. The file chooser rendered, but Escape returned portal error code 2; it was correctly rejected. ScreenCast reached CreateSession=0, then SelectSources remained pending and cleanup was not confirmed. No readiness sample or UI attestation was accepted.

Version-pinned source inspection explains two observer assumptions: Hyprland portal 1.4.1 opens its source picker during SelectSources, whereas the observer only captured/interacted during Start. GTK portal 1.15.3 maps Escape/dialog-close to code 2, while explicit Cancel maps to code 1. These explain the observation gap and file-close result; they do not prove that the actual screen picker rendered or that session cleanup succeeded. The failed evidence remains preserved. A corrected observer must exercise SelectSources, successful Start with streams and confirmed session cleanup, and use deliberate file selection or explicit Cancel. No portal/backend product change is justified by this observer failure alone.
The 82 additional SDK packages still make the original baseline/candidate
inventories nonequivalent for performance comparison. Neither a single-candidate
observation nor a passed offline-upgrade gate waives that mismatch. A controlled
equivalent fixture, three independent observed boots per revision, actual
picker/screen-selection review and representative hardware remain required.
No startup optimization or speedup is claimed; GRUB, binfmt and the portal grace
were left unchanged. Installed lifecycle and native compositor/QML evidence are
tracked separately in the [validation report](desktop-validation.md).
