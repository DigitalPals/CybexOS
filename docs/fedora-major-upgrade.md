# Fedora major-upgrade runbook

## Guided upgrade workflow

`cybex upgrade-system` now coordinates preflight, a durable background DNF5
**download**, an explicit offline reboot, target convergence and rollback. It
requires a separately reviewed target release; the current source manifest
supports **Fedora 44 only**. This workflow does not qualify or advertise Fedora
45. Incrementing a release number is insufficient.

Select either a clean reviewed target checkout/release directory whose
`release-manifest.json` **and** inventory declare the target, or a signed
`cybexos-desktop` RPM for that release and architecture which provides
`cybexos-supported-fedora = <next>`. The RPM signature must verify against the
installed trusted keyring. Selecting local source is an explicit administrator
trust decision, as with bootstrap; the workflow verifies compatibility and
freezes the selected bytes, but does not claim a local checkout hash proves its
author. A Git checkout must be clean and only tracked files enter the frozen
payload. No branch is pulled, reset or switched.

Make and test an external backup first. Supply a JSON receipt beside its tar
archives, with paths relative to the receipt:

```json
{
  "v": 1,
  "createdAt": "2030-01-01T12:00:00Z",
  "archives": [{
    "path": "workstation.tar.zst",
    "sha256": "REPLACE_WITH_THE_ARCHIVE_SHA256",
    "covers": ["/home/john", "/etc", "/var/lib/xps-hardware", "/etc/pki/akmods"]
  }]
}
```

Use the actual backup timestamp, account home and checksum. The validator
requires a backup from the last seven days on another filesystem UUID, hashes
each archive, reads it completely through tar and verifies its declared
coverage. The account home and `/etc` are mandatory, plus the hardware/signing
paths when present. Archive members should be root-relative (`home/john/…`,
`etc/…`). This verifies integrity and coverage; the independent restore test
remains part of preparing the backup.

```sh
cybex upgrade-system check --target <next> --source /path/to/reviewed-release --backup /mnt/backup/receipt.json
cybex upgrade-system prepare --target <next> --source /path/to/reviewed-release --backup /mnt/backup/receipt.json
# On an RPM installation, use --rpm /path/to/signed-target.rpm instead.
cybex upgrade-system status
# Once status is ready, close applications and explicitly start the offline upgrade:
cybex upgrade-system reboot
```

`prepare` returns after starting a durable root service. It does not reboot or
install packages into the running OS. Status becomes `ready` only after the
DNF download succeeds and the rollback checkpoint is armed. Closing the terminal
does not cancel the service. Its journal is under the `downloadUnit` named by
status. The helper never adds `--allowerasing` or disables signatures.

Preflight requires the normal managed Btrfs root, free space on root/var/boot,
a clean RPM database, completed current-release updates, the default current
kernel, no pending hardware reboot, usable signed repositories, and healthy
installed camera ABI/userspace checks. Enabled repository URLs must follow
`$releasever` or be release independent; a URL pinned to the old Fedora release
must be reviewed first. Do not point the running system at target-only package
repositories. For an RPM target, the old CybexOS channel is omitted from the
offline download and the explicitly signed target RPM is applied after boot.

`cybex upgrade-system cancel` is available after a completed or failed download,
before reboot is scheduled. It checks the saved metadata fingerprint before
cleaning DNF's offline state. It refuses to interrupt active DNF work or delete
an offline transaction that another operation replaced. An interrupted worker
retains diagnostic state rather than guessing which cached transaction to erase.
A normal reboot before scheduling the upgrade does not strand the download:
cancel or schedule it afterwards if the installed Fedora release and the saved
offline metadata are unchanged and no offline reboot is already scheduled.

The first target boot converges the frozen source with the saved installation
choices, or installs/reconciles the staged RPM. RPM convergence requires the
current package's durable reconciliation status and every account to be ready;
a successful command exit alone is insufficient. Recovery waits for mounts,
the system bus and network availability, with login ordered after recovery.
Failed convergence, root health,
kernel or signing checks select the previous root and vendor desktop checkpoint
and reboot before allowing login. Successful root checks produce
`awaiting-desktop`, not success: the validation timer waits for an actual
Hyprland session, then verifies the managed shell through the transaction health
checks. A recovery bar does not count as a healthy desktop. A failed desktop
check selects rollback and records `restartRequired`; the active session is not
abruptly rebooted. Use `cybex upgrade-system reboot` to enter that restored root.

Status is private under `/var/lib/cybexos/major-upgrade/`. Frozen release payloads
are under `/var/lib/cybexos/major-upgrade-payloads/<id>/`; source is retained for
reproducibility, while a committed RPM payload or explicitly cancelled payload
is removed. The transaction journal and checkpoint are independently stored in
the Btrfs recovery store. Personal files and settings are never reverted by the
vendor checkpoint. The backup covers data outside that checkpoint.

`tests/major-upgrade.py` exercises artifact compatibility, signature gates,
staging, the download/reboot boundary, cancellation ownership, backup checks,
boot failure/rollback, deferred desktop validation and process-group cleanup
using fixtures. It is not an end-to-end Fedora major-upgrade qualification.

## Release engineer preparation

The playbook supports exactly the release named by `fedora_release`; this is a
safety boundary, not a default. Prepare and test repository support for the
next Fedora release before upgrading the workstation. Do not change the value
on the current-release branch and then continue applying that branch to the old
OS: the `always` preflight correctly refuses that mismatch.

Replace `<next>` below with the reviewed numeric release and use a dedicated
branch for all compatibility changes.

## 1. Establish a recoverable baseline

1. Finish or cancel any updater run. `cybexos-update-run status` must be terminal,
   not `queued` or `running`.
2. Fast-forward the current-release branch, run `./update`, reboot into the
   newest current-release kernel, and run `./verify --require-hyprland`.
3. Confirm that Secure Boot and the signed camera modules are healthy with the
   checks in `docs/xps-2026-hardware.md`. Do not begin a release upgrade while
   `/var/lib/xps-hardware/ipu7/reboot-required` describes the current boot.
4. Make and test a backup that covers the user's home, repository checkout,
   `/etc`, `/var/lib/xps-hardware`, and `/etc/pki/akmods`. Also record
   `rpm -qa`, `flatpak list --system`, enabled repositories, and the current
   kernel. The guided workflow restores its pre-upgrade root/vendor checkpoint on
   failure; the external backup and recovery media cover unsupported layouts
   and personal data. Never attempt a mass package downgrade.
5. Ensure the prepared target-release branch and recovery media are available
   without relying on this machine's graphical session.

## 2. Prepare repository support

Create an upgrade branch and audit every release-coupled input. At minimum:

- change `fedora_release` and `supportedFedora` together, the README support
  text, and the required job's container and name in
  `.github/workflows/tests.yml` (its release assertion and the image tooling
  read `fedora_release`); see [Flipping the release](#flipping-the-release);
- review required and optional RPM names (including the explicit `nodejs24`
  packages), RPM Fusion release packages, vendor repositories, COPR output,
  Flatpak behavior, and SELinux policy on the target release;
- publish and checksum a target-release `mdview` RPM instead of weakening its
  `fc44` asset selector; review every other root RPM against the new DNF/RPM
  stack;
- resolve and record a new digest for `source_build_container_image`; the
  image must match the Fedora release used to build source applications;
- refresh the Fedora Distrobox source tag/digest if that box should follow the
  host release. Existing boxes are not automatically recreated;
- rebuild and validate the XPS camera RPM/DKMS bundle against the target stock
  kernel. Review the Fedora 44-specific BTF ABI baseline, spec description,
  package names, patches, and hardware documentation rather than merely
  changing comments;
- review the dated Rust nightly and all other immutable dependency pins for
  compatibility, upgrading only those with a concrete reason; and
- run `python3 tests/fedora-release.py`, which names every remaining
  release literal that disagrees with `fedora_release`, and inspect the rest
  with:

  ```bash
  rg -n 'Fedora 44|fedora:44|fc44|nodejs24|releasever|fedora_release' \
    README.md docs inventory roles site.yml tests image .github
  ```

Parser fixtures containing `fc44` transaction examples do not need mechanical
replacement if they remain valid cross-release inputs. Change tests when the
contract changes, not for cosmetic consistency.

Run `./tests/run` on the branch and require its target-release CI job to pass.
Exercise a disposable target-release VM or equivalent hardware-safe test host
for package resolution and Ansible check mode. A container can validate source
contracts, but it cannot validate SDDM, user systemd, Secure Boot, DKMS, camera,
audio, haptics, or the live Hyprland session.

## 3. Download and perform Fedora's offline upgrade

On the still-supported current release, commit or stash local work and verify
the DNF5 plugin exposes the expected commands:

```bash
dnf system-upgrade --help
sudo dnf upgrade --refresh
sudo dnf system-upgrade download --releasever=<next>
```

Read the proposed transaction. Stop and resolve repository, dependency,
package-removal, disk-space, or signature problems; do not reflexively add
`--allowerasing` or disable GPG checks. Once the download succeeds, recheck
that no repository updater is active, close applications, and start the
offline transaction:

```bash
sudo dnf system-upgrade reboot
```

Do not interrupt power during the offline transaction.

## 4. Converge the upgraded system

1. After the first boot, confirm `/etc/os-release`, network access, storage,
   Secure Boot state, and the running kernel from a console if the graphical
   session is unhealthy.
2. Switch the checkout to the already-tested target-release branch. The old
   branch should now fail its OS preflight, which prevents accidental use.
3. Inspect convergence first, then apply it:

   ```bash
   ./tests/run
   ./bootstrap --check --diff
   ./bootstrap
   ```

4. Let package, DKMS, and initramfs handlers finish. If the play or camera
   diagnostics request a normal reboot, do it only after Ansible has reached a
   terminal result.
5. Run `./verify --require-hyprland`, inspect the current boot and
   `quickshell.service` journals, and manually verify camera, audio, haptics,
   fingerprint, external displays, suspend/resume, Flatpaks, Distroboxes, and
   the fallback GNOME session.
6. Run `sudo dnf system-upgrade log` if the offline transaction needs diagnosis.
   Keep the old kernel and retained application/tool versions until the new
   release has survived normal work and at least one suspend/resume cycle.

Only merge the target-release branch and update the public support statement
after the installed-system checks pass. Record hardware gaps in
`docs/xps-2026-hardware.md` rather than hiding them with ignored failures.

## Fedora 45 qualification

**Fedora 45 is not qualified.** `fedora_release` remains `"44"` and
`release-manifest.json` lists only `"44"` in `supportedFedora`. Neither changes
until every item below has passed on a dedicated target branch, recorded with
dates, versions and run links. The `Fedora preview` CI job is an early warning
at source level; a passing fixture suite is not an installation result.

### Repositories and COPR availability

- [ ] Fedora 45 `fedora`, `updates` and `fedora-cisco-openh264` metalinks
  resolve for x86_64, and the builder's `fedora-gpg-keys` ships
  `RPM-GPG-KEY-fedora-45-x86_64`. `image/build.repo` uses `$releasever`, so it
  needs no edit if the repository IDs keep their `fedora-N`,
  `updates-released-fN` and `fedora-cisco-openh264-N` forms.
- [ ] RPM Fusion publishes `rpmfusion-free-release-45` and
  `rpmfusion-nonfree-release-45` at the URLs `roles/apps` derives from
  `fedora_release`, signed by the pinned key fingerprints, and every codec and
  akmod package the roles request from it resolves.
- [ ] The Brave, 1Password, ChatGPT and Tailscale repositories only use
  `$basearch`. Install each vendor RPM on Fedora 45 anyway: dependencies,
  signatures under the new RPM, and scriptlets (the ChatGPT `%pretrans` that
  `image/compose` installs in a second transaction) can still break.
- [ ] The `sdegler/hyprland` COPR has a `fedora-45-x86_64` chroot with
  successful builds of every package the desktop requires: `hyprland`,
  `hyprland-guiutils`, `quickshell`, `hypridle`, `hyprlock`, `hyprsunset` and
  `xdg-desktop-portal-hyprland` (`image/cybexos-desktop.spec`). Its signing
  key must still match the pinned fingerprint.
- [ ] Flathub has no Fedora release, but install every `apps_flatpaks` entry
  on Fedora 45 to cover its Flatpak and OSTree versions.
- [ ] Required and optional RPM names resolve, including `nodejs24` and
  `nodejs24-npm`, `base_required_packages`, and the CI dependency list in
  `.github/actions/fedora-source-environment/action.yml`.

### Hyprland and Quickshell

- [ ] Record the Hyprland and Quickshell versions the COPR builds for Fedora
  45 and read the upstream changes since the last verified Fedora 44 versions
  (Hyprland 0.56.2 and Quickshell 0.2.1 in this documentation).
- [ ] The compositor configuration is Hyprland Lua
  (`roles/desktop/files/*.lua`, `roles/desktop/templates/*.lua.j2`). Confirm
  that the API it calls keeps its semantics: `hl.bind`, `hl.unbind`,
  `hl.dispatch`, `hl.exec_cmd`, the `hl.dsp` dispatchers (`exec_cmd`,
  `window`, `focus`, `layout`, `global`, `exit`, `send_key_state`),
  `hl.config`, `hl.get_config`, `hl.env`, `hl.monitor`, `hl.get_monitors`,
  `hl.on`, `hl.window_rule`, `hl.layer_rule`, `hl.workspace_rule`,
  `hl.animation` and `hl.curve`. The luajit fixtures in `tests/hyprland-*`
  stub this API, so only a live session with no configuration errors proves
  it.
- [ ] Run `tests/qml-lint` and the QML runtime stages with Fedora 45's Qt and
  the COPR's `qs`, then run the shell through `quickshell.service` and check
  its journal for QML errors. Check hypridle, hyprlock, the portals, screen
  sharing and the authentication agent in the same session.

### Anaconda and the custom installer

- [ ] Diff the Fedora 45 Anaconda and anaconda-webui against the reviewed
  reference, Anaconda 44.30 and anaconda-webui 68 (`image/INSTALLER.md`).
  Review every interface `image/live-rootfs/usr/libexec/cybexos-installer-backend`
  calls (storage scan, automatic partitioning with Btrfs and LUKS2, disk
  initialization, tasks, users, localization and `InstallWithTasks`). Update
  the strict proxy member sets in `image/test_installer.py` from the new
  source rather than loosening them.
- [ ] Re-check `image/live-rootfs/etc/anaconda/conf.d/20-cybexos.conf`: the
  `webui_web_engine` hook, hidden pages and spokes, the Btrfs default scheme
  and the network default. Re-check the liveinst launcher's authorization and
  its refusal of Kickstart-based live installations.
- [ ] Confirm that Anaconda still runs the post-scripts that
  `usr/share/anaconda/interactive-defaults.ks` includes from
  `post-scripts/90-cybexos.ks` through the Runtime DBus module, and validate
  both kickstarts with pykickstart's `F45` handler.

### Image build

- [ ] `image/live.ks` and `image/build.repo` name no release, and
  `image/compose`, `image/build-in-guest` and `image/build` read
  `fedora_release` through `image/fedora_target.py`.
- [ ] Review the builder's livecd-tools/imgcreate. `image/compose` adds the
  signature verification livecd-tools 31 skips, loads RPM 6's SQLite database,
  installs `Requires(pretrans)` packages in a second transaction and hooks
  `_configure_bootloader`. Re-read each workaround against the new version and
  never drop signature verification.
- [ ] Pin the official Fedora Cloud 45 image name and SHA-256 together, from
  Fedora's signed CHECKSUM file, in `image/build`, `image/qualify-checkout`
  and `tests/fedora-vm-convergence` (and the literal in
  `tests/repository-policy.py`). The builder runs the target release; the
  source contract rejects a builder image for another release.
- [ ] Check the live initramfs that compose regenerates with
  `image/dracut-live.conf`, the Plymouth `cybex` theme, GRUB and syslinux
  branding on UEFI and BIOS, and the kernel, firmware and Mesa packages
  compose requires.
- [ ] Sign the desktop RPM in a Fedora 45 container
  (`.github/workflows/desktop-release.yml`) and publish a separate update
  channel: `image/channels/stable.json` and `image/github_release.py` use the
  `/44/x86_64` path.

### CI preview job

- [ ] The `Fedora preview` workflow (`.github/workflows/fedora-preview.yml`)
  runs `./tests/run` in `fedora:45` on pull requests, pushes to `main`,
  weekly and on demand. It shares the required job's dependency and COPR
  setup, installs what Fedora 45 provides, runs every check it can, and then
  fails the job if anything was unavailable. The job may fail without failing
  its run; it is not a required check and `release.yml` never calls it.
  Require a run with every stage passing and no `Unavailable` report before
  flipping; even a clean preview qualifies nothing.

### VM qualification

- [ ] `./tests/fedora-vm-convergence` on the pinned Fedora Cloud 45 image:
  a zero-change second pass and uninstall restoration.
- [ ] Build a Fedora 45 ISO from the target revision and run `image/test-live`
  and `image/qualify` for every scenario in `image/qualification.py`
  (`encrypted-us`, `plain-us`, `encrypted-nl`, `plain-nl`, `encrypted-de`,
  `plain-de`), then `image/qualify-checkout` and `image/release-gate`, which
  also requires the prior-release RPM upgrade and recovery check.
- [ ] Upgrade lifecycle: install the current Fedora 44 release, then run
  `cybex upgrade-system` to 45 once with a signed target RPM and once with a
  reviewed target checkout, plus a deliberately failed convergence that must
  roll back. Use encrypted and plain installations.
- [ ] Hardware: the XPS camera bundle and BTF ABI baseline, Secure Boot,
  audio, haptics, fingerprint, external displays and suspend/resume, as in
  [section 4](#4-converge-the-upgraded-system).

### Flipping the release

Only after every item above passes, on the target branch and in one change:

1. Set `fedora_release: "45"` in `inventory/group_vars/all.yml` and
   `"supportedFedora": ["45"]` in `release-manifest.json`. The playbook
   targets exactly one release, so the manifest names only that one.
2. Run `python3 tests/fedora-release.py`. It fails with each remaining
   literal to review: the required job's container and name, the Fedora Cloud
   pins, the signing container, the update channel path, the `fc45` mdview
   asset and the source-build image comment.
3. Rename the required check to `Fedora 45 source contract` in branch
   protection and `docs/releasing.md`; the `fedora-44` job id can stay.
4. Move the preview matrix to the following release. The source contract
   rejects a preview of a supported release.
5. Rebuild and qualify the ISO and RPM from that revision. Earlier reports do
   not carry over.
