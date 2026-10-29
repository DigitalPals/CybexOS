# Firmware in Software Update and quiet boot — 2026-10-29

Device firmware uses the regular Software Update preparation, review and
installation actions. The separate firmware button/launcher action is gone.
The graphical review lists devices and versions, explains external power and
OS rollback limits, and warns about encryption measurements when applicable.
The worker streams progress, device instructions and failures; firmware-only
updates need no Nix build or OS activation. Firmware runs after successful OS
activation in a combined update, so device failures retain the successful OS
deployment. Restart and full-shutdown requirements stay explicit.

The ISO previously missed quiet settings because they were in the installed
desktop-only branch of the shared module. The shared contract now suppresses
kernel, initrd and systemd status output on both boot paths. The ISO ignores
its diagnostic serial console when choosing Plymouth's graphical splash. Its
scripted initrd remains enabled for iVentoy compatibility. The verbose boot
entry removes the quiet parameters and explicitly restores kernel/systemd
output. Encryption prompts, recovery and diagnostics remain available.

## Exercised

- Built `desktop`, `updater` and `checks.x86_64-linux.parity` successfully.
  The final build used `/nix/store/87a2cl7rvr4vyz8nl1p7mnr4z7vjqwm4-source`,
  NAR `sha256-UzQqvCLS/z32sbbtSxc8gqCU4xwWyEVeER5259QDlgU=`.
- Full Python regression run: 740 tests, 19 skipped, no failures. After adding
  an interruption regression case, the final update/firmware subset passed
  all 68 tests. These use fake hardware and isolated files.
- Full JavaScript regression run through `nix develop`: 1,511 passed,
  16 skipped, no failures. The final update/translation subset passed 30 tests.
  The initial host-only run lacked Lua; the development environment supplies it.
- QML lint: 447 files, no errors. Eight existing nonfatal warnings remain.
- `tests/update-flow.py` passed with production QML, a private Sway session
  and fake CLI/system actions. It exercised firmware-only discovery, the normal
  prepare/install controls, graphical device/version review, progress and
  instructions, restoration after a shell restart, and full-shutdown wording.
- `checks.x86_64-linux.firmware`'s built driver ran directly inside an
  `agent-resource` task. The original test script passed in 33.20 seconds.
  It exercised the real authenticated request boundary, systemd worker,
  firmware preparation/review/apply, durable progress/instructions, unchanged
  running OS, and clearing the restart requirement after a guest power cycle.
  The helper alone was replaced inside the worker's mount namespace with
  simulated firmware hardware. The VM also checked the running quiet kernel
  parameters and console log level. Driver:
  `/nix/store/0j75x88ycqvps51j9yxmnd8l4b3f9lwb-nixos-test-driver-cybexos-firmware`.
  Its source snapshot NAR was
  `sha256-EBC3T6sc70p8n4vI3sg4vl/MPgNunxNnsm3+dd6DJKo=`; the final shell
  notification wording and interruption fixture were checked afterward.
- `git diff --check` and the Dutch translation catalog check passed.

## Limits and cleanup

No new ISO was built or served, and no physical firmware was flashed. These
checks do not qualify a fresh installation, physical boot display, hardware
capsule execution or Secure Boot. The existing bootloader VM driver build
was stopped after its image builder reported filesystem-read failures and
fell back from inaccessible KVM; it is not counted as bootloader qualification.
The cancelled image output was absent afterward.

The Debian host has no deployed Cybex OS desktop/updater service. Packages
were rebuilt and private test services were restarted; no running workstation
was updated or rebooted. Temporary VM disks, sessions, source snapshots and
logs were removed. All task leases were closed with empty resource checks;
normal shared Nix package/build caches remain.
