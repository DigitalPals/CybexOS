# Fedora major-upgrade runbook

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
   kernel. The rollback for a failed major upgrade is restore/reinstall, not an
   attempted mass package downgrade.
5. Ensure the prepared target-release branch and recovery media are available
   without relying on this machine's graphical session.

## 2. Prepare repository support

Create an upgrade branch and audit every release-coupled input. At minimum:

- change `fedora_release`, the play name in `site.yml`, README support text,
  and the Fedora container/assertion in `.github/workflows/tests.yml`;
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
- inspect hard-coded release strings with:

  ```bash
  rg -n 'Fedora 44|fedora:44|fc44|nodejs24|releasever|fedora_release' \
    README.md docs inventory roles site.yml tests .github
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
