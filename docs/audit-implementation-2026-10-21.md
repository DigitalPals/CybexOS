# Audit implementation, 2026-10-21

This records the engineering changes accepted after the CybexOS repository
audit. The starting point was clean `main` at
`d668048cd95ede9fac357df8cdc42a34c24e04b1`; implementation is on
`codex/implement-audit-20261021`. No release, commit, or public distribution is
implied by this record. Implementation and independent review used GPT-6.1-SOL
agents, with focused scopes and integration in the primary checkout.

## Accepted changes

| ID | Result | Main implementation boundary |
| --- | --- | --- |
| F01 | Account-specific, ownership-aware Docker grants and revocation, including explicit legacy opt-outs | Shared `roles/base/tasks/docker-access.yml` and `image/library/cybexos_docker_access.py` |
| F02 | Backups include Steam/Proton saves and readable rootless volumes; partial snapshots are visible failures, with export guidance for inaccessible/database data | `assets/scripts/cybexos-backup`, Backup Settings, shared installation units |
| F03 | Wallpaper preferences seed only when absent; existing sparse, empty, corrupt, future, or concurrently created settings survive | Shared managed-file module and wallpaper tasks |
| F04 | Provisioning has a bounded systemd cgroup lifetime; draining precedes lock release, retry, and recovery | Installed provisioner, reconciler, durable updater |
| F05 | Publication verifies a shared, versioned inventory of completed scenario evidence | `image/qualification_contract.py`, qualification producer and release verifier |
| F06 | The existing encrypted-US upgrade guest also qualifies public-updater interruption, automatic pre-login recovery, another boot, and successful commit | `image/public_update_qualification.py` and release qualification |
| F07 | Required source CI enforces and verifies the same qualified Quickshell series as the product | Shared Fedora CI action and product versionlock policy |
| F08 | Compiler provenance records immutable builder identity, resolved packages/tool versions, and shipped binary digests, exported with SBOM binding | Shared source builder and image/release artifact collection |
| F09 | Hermes authentication returns independently of optional discovery; discovery is single-flight and session-scoped; startup offline failures recover with bounded backoff | Hermes bridge and remote authentication state |
| F10 | GitHub stats cache contains successful results; failed fetches show unavailable/retry rather than permanent zeroes | GitHub singleton and commit popover |
| F11 | Successful unchanged plugin discovery clears its own error; preference failures remain separate; registry lock acquisition expires before mutation | Plugin singleton and existing Python registry helper |
| F12 | Keyboard/touchpad drafts survive Settings search, navigation, and close/reopen; successful Apply advances the exact committed version | Session-owned input draft state and input persistence helper |
| F13 | Compositor targeting uses a stable Settings identity across languages | Settings window and shared compositor rules |
| F14 | The registered notification drawer's On/Focus choices support keyboard and accessible activation with visible focus | Existing accessible button primitive in Drawer Notifications |
| F15 | Settings search matches translated display labels and English aliases | Existing search index and translation catalog |
| F16 | Undocumented bundled wallpapers are replaced by original procedural landscapes; PUBLIC distribution fails closed until actual inventory-bound review | Asset provenance, native/web defaults, distribution inventories and release workflows |
| F17 | Recovery search navigates to the existing recovery section anchor | Settings search destinations and Recovery group |
| F18 | Welcome fits available logical screen space, scrolls, and reveals keyboard focus | Shared Welcome payload and compositor rules |
| F19 | Nonempty launcher queries retain normal text navigation; Ctrl+Tab selects providers | Launcher command-key handler and interaction documentation |

The ISO remains authoritative. Checkout installation, ISO reconfiguration, and
RPM reconciliation consume the shared policies and desktop sources. Saved
choices, ownership records, stale-write validation, personal settings, and
rollback boundaries remain part of the contract. No migration removes an
installed user's former wallpapers or resets their selection.

The requested original product artwork remains in source: seven PNGs under
`assets/wallpapers/` total 139,958 bytes; three web variants under
`web/public/wallpapers/` total 91,297 bytes. Their generator and provenance
records accompany them. These replace the undocumented bundled copies while
preserving installed personal files and saved selections.

## Review corrections

Independent review found and corrected additional transition failures:

- Automatic Docker convergence must not grant secondary accounts the primary
  account's consent. Installed repair also needs an account-specific intent
  boundary; it is not a new installation choice.
- Restic can create a partial snapshot while reporting unreadable subUID-owned
  volume contents. Partial backups retain the snapshot and previous successful
  timestamp, skip retention, return nonzero for manual runs, and expose bounded
  error details. The unreadable count is reported read errors, not an invented
  count of omitted child files.
- Input Apply must settle its submitted baseline and exact committed version
  together, regardless of snapshot/completion ordering. Cached pre-write
  snapshots cannot replace that baseline on reopening or Discard; later
  external writes still conflict normally.
- Hermes discovery must restart the selected-session observer when it learns
  a different stream path, including after an early default-path 404. Stale
  sessions cannot restart old observers.
- An automatically restored baseline has SSH disabled and its firewall closed.
  Recovery qualification reuses the authenticated console bootstrap after
  recovery's restart; the temporary SSH/firewall changes remain runtime-only.

## Validation and limits

The full source runner passed all 17 groups in a disposable Fedora 44 container:
syntax, ShellCheck/Ansible/YAML/Ruff lint, 1,481 JavaScript tests across 152
files, compositor policy, 357 QML files and four test harnesses, native QML
lifecycle/runtime checks, Quickshell migration, 47 Python helper/repository
fixture suites, hardware/Plymouth/skills/updater/screenshot/brightness/snapshot
and legacy migration checks. Existing qmllint warnings remain: three property
overrides, three missing types, and two incompatible types; no qmllint errors.

The final refreshed image source gate passed its 30 tooling tests, 649 Python fixtures, and 14
installer JavaScript checks. Two Python cases skipped as container root were
rerun successfully as UID 1000: writable-ancestor PXE staging and regular-user
installer account seeding. Source/image fixture parity is not an end-to-end
installation result. Final account-intent corrections passed 30 wrapper/module
fixtures, eight application-default checks, and independent caller review;
the refreshed full image gate includes these corrections.

The pinned Fedora 44 cloud guest, with systemd 259.5 and SELinux enforcing,
executed the real provisioning timeout fixture: a detached writer ran, the
two-second limit drained the complete cgroup, no writes occurred afterward,
and retry retained serialization. Real guest account checks also verified
Docker grant/revoke, explicit legacy opt-out, and unrelated/administrator group
preservation. This checks those mechanisms; it does not qualify a CybexOS ISO.

That guest exposed a launch failure when `systemd-run --pipe` was used on the
tested Fedora environment. Journal identifiers and bounded finite journal
snapshots replace descriptor forwarding and orphan journal followers. This
alone does not remove the public-bus dependency: systemd 259 also routes
`--wait` through that bus. The verified installer chroot remains the sole
explicit exception to live systemd containment. The regression timeout remains
two seconds.

Two additional real-build/convergence failures prompted focused corrections.
The candidate build `20261021T200121Z-4cda2099` stopped before producing an ISO:
GitHub's anonymous API allowance was exhausted even though pinned application
payloads were cached. The installer now accepts only a unique, regular cached
asset for an inventory-pinned tag/checksum, verifies a private copy, and installs
from that copy without metadata access. Missing, corrupt, or ambiguous cache
entries retain the existing metadata path; unsafe paths fail closed.

The first complete checkout VM run made 158 changes, then one change on its
second pass, at `/etc/grub.d`; later assertions and uninstall were not reached.
Fedora's `grub2-common-1:2.12-66.fc44` owns that directory as `0700 root:root`.
Recovery setup now creates only missing hook directories and preserves existing
upstream/admin attributes while managing CybexOS hook files. The later writer
in that failed guest was not identified; the inspected `grub2-mkconfig` did not
contain a permission change. Regression fixtures cover RPM assembly and actual
Ansible second-pass convergence. The refreshed gates and successful build and
convergence runs below include these corrections; the failed attempts are not
qualification.
The retry `20261021T201607Z-ab05186b` passed pinned application installation and
source compilation, then encountered the same exhausted anonymous API allowance
in the intentionally moving T3 Code download. No artifact was produced. Its
response advertised a reset at 2026-10-21 20:34:16 UTC; that external failure did
not justify replacing the moving-input policy or introducing credentials.
After the reset, `20261021T202930Z-ae513a9e` completed both RPMs and reached ISO
composition. Composition failed because the official Fedora OpenH264 repository
returned 404 for the primary metadata referenced by its own `repomd.xml`.
A subsequent direct read of that exact URL returned 200; no repository policy
or dependency was changed in response. No completed ISO or qualification was
produced by that attempt.

The corrected complete `tests/fedora-vm-convergence` run passed in 12m41s:
157 first-pass changes (`ok 301`), zero second-pass changes (`ok 261`), rendered
configuration/service assertions, uninstall (27 changes, `ok 50`), restoration,
and project-state removal. It used the pinned Fedora 44 base, all tags, and the
unchanged 100-minute bound. Its pre-launch tracked diff SHA-256 was
`da1680a76e45488faef00885d2bc85978d6398fac8aadedeb088b8106fdd507a`.
Existing generic-guest exclusions remained: Docker/optional features, hardware
roles, and live Quickshell. The separate real guest Docker checks above cover
that policy mechanism. This is checkout convergence evidence, not ISO parity or
physical hardware qualification. Its lease, capacity reservation, and artifacts
were released and verified absent.

Candidate build `20261021T203819Z-03404dcc` completed ISO/RPM assembly and
post-install validation. The ISO SHA-256 is
`8fc6c8f4559aa8d671c4946896efa6240a9ba7636cd44bfb418c30d51e540482`;
its installed source-content identity is
`32291346be09d24db6dfebbb9640de78f5a7e63c0e1fbad6b8f9e44524c5ee09`.
All delivered checksums passed. The independently copied desktop/offline RPMs
under guest qualification matched the final artifacts byte for byte. Compiler
provenance was exported for both source applications, including 193 resolved
builder RPMs, immutable image identity, and the shipped binary digests.
The temporary testing ISO was published through checksum-first PXE staging;
iVentoy refresh, list presence, running PXE status, and service checks passed.
After the fresh-install check completed, that task-owned served ISO and checksum
were removed. The subsequent refresh succeeded, its entry was absent, PXE
remained running, and `iventoy.service` remained active. Prior images were
preserved.

The candidate's real UEFI `plain-nl` qualification passed all 12 mandatory
fresh-install checks with outbound networking blocked: installer-only session,
graphical installation, plain Btrfs, unchanged guard disk, installed boot
without ISO, password login, desktop/application contract, selected Dutch
locale/timezone/keyboard, live-state cleanup, SELinux enforcing, and
password-required sudo. The report passed the shared evidence validator and
bound the exact ISO and source-content digests above. This run did not request
outcome capture, saved-choice reapplication, or the native Settings lifecycle
extension; those are not established by this guest report. Its guest, disks,
capacity reservation, and temporary browser-path alias were removed, and the
lease was verified closed without remaining resources or cleanup errors.

The host browser runner used a short task-owned `TMPDIR` symlink into its
managed workspace: Chromium's Unix socket exceeded the pathname limit under
the long lease path. The alias is removed during teardown. Qualification
startup and diagnostic attempts that stopped before the public-updater checks
provide no automatic-recovery evidence. The clean retry records the loaded
module path, SHA-256, and actual launcher command before executing the public
updater phase.

The encrypted upgrade qualification exposed a host-harness authentication error:
combining `sudo -k` and `-v` validates without retaining a ticket. The launcher
now invalidates separately, then validates through the existing password policy
before executing the ordinary updater. Actual password-required, non-TTY sudo
checks in the disposable Fedora environment confirmed both behaviors. Exit,
timeout, and invalid-JSON diagnostics are bounded and redact the password.
Twelve focused launcher tests, independent review, and both refreshed full
source/image gates passed. This correction
changes the host qualification harness only; the candidate updater, RPMs, and
ISO remain unchanged.

The upgrade guest uses the retained baseline ISO
`CybexOS-Live-44-20261021T121337Z-87cc6b87.iso`, SHA-256
`28603ac50e9167f1896d5f0657d171eb8bd3ac429d1a54dbc37540a98b275552`.
The candidate desktop RPM is 2,263,927 bytes, SHA-256
`25c3fd93c745296893a4da217cc24b6ccaa52aeace92337838bd014024b3795c`;
the offline-apps 1.5.2 RPM is 1,639,393,555 bytes, SHA-256
`1530c5052112319c856cca17c175f8cdc4fe73360902641c5b313a16a3672366`.
The corrected public-update host helper SHA-256 is
`12b69686b8abd978c0830368e193a355b9241d6795bcad74b6f73855cf333a64`.

The clean encrypted-US run passed baseline installation, candidate signature
and transaction checks, explicit recovery boot/restore, public-updater
interruption after package application, automatic pre-login rollback/restart,
preservation checks, and a subsequent cold boot. It then failed the second
public update before commit: Fedora's systemd RPM triggers reported transport
disconnects, and the contained reconciliation launch timed out before its unit
started. The updater restored its checkpoint and reported failure. This is a
failed qualification; successful public commit and the final two-second
provisioning check remain unverified in this run.

PID 1 logged API-bus disconnects at boot seconds 98.211 and 98.582, followed by
a roughly 25-second gap around the failed launch. PID 1 and dbus-broker did not
restart. Full-boot AVC/USER_AVC/SELINUX_ERR searches found no relevant denial.
Later bounded harmless transient-unit probes passed through both the private
manager socket and public system bus, including the updater's `initrc_t`
domain and an outer system-service cgroup. Those probes establish that the
settled manager recovered; they neither reproduce the earlier failure nor
qualify a successful update. The exact disconnect cause remains unresolved;
no security policy was weakened and no update was retried inside the
diagnostic guest. Its lease, capacity reservation, six recorded QMP runtime
directories, processes, temporary path alias, and diagnostic guard were
removed and verified absent.

Source review supports a bounded synchronization point after the package
transaction. The shared updater now performs one root-private manager reload,
then requires a valid public-manager reply, and checks public readiness again
before commit. Failures use the existing protected rollback path. Reload does
not replay missed RPM-trigger actions. The host qualification therefore also
checks system and user pending service markers, required service states, the
actual public manager bus, and ordinary password-authenticated sudo before
awarding commit evidence. These changes require a rebuilt candidate and a new
complete qualification; the failed report above cannot establish their result.

The subsequent manager-synchronization build `20261021T215356Z-9bea00da`
completed. Its ISO SHA-256 is
`bdf569e3c72031f8fd7ec0ef0b986837524368c3c582f05eff5f0742267a77f2`,
with source-content identity
`cbfcad17dea46969fb9bcc045fc865cbaf0954bb31fbccd5e32235c5d642ec65`.
The new plain-NL guest passed all 12 standard checks and the report validator.
The wrapper's final whole-checkout guard detected announced subsequent
host-only changes; this does not invalidate the frozen guest artifact result,
but it is not a passing wrapper invocation or qualification of the newer tree.

An encrypted attempt then exposed another host observation dependency: fresh
SSH/PAM sessions stalled while logind waited for the manager bus during DNF.
The interruption adapter had already written its applied sentinels, but the
host timed out before delivering interruption. The adapter intentionally holds
before returning to the updater, so the product's post-DNF synchronization had
not yet run. Qualification now establishes one ordinary SSH and
password-authenticated root control process before each normal user launch.
Polling, interruption, drain, staging cleanup, and shutdown reuse that process;
EOF or protocol failure fails without reconnecting or relaunching. Final health
still uses fresh ordinary SSH after the controls close. Independent review also
required passive worker verification immediately after commit, before any
timeout test or active cleanup could hide a surviving worker. All 35 public
harness and 25 offline-input fixtures passed, including mutation checks for
the passive leak regression, followed by clean independent review.

That corrected full run reached 20 of 23 checks. It passed actual after-apply
interruption, automatic pre-login recovery, preservation, and the subsequent
cold boot. The second public update failed reconciliation and rolled back.
Both explicit provisioning bodies completed successfully, including invocation
`dd703fcf90254ec9bdd31c61383d03de`. A later, implicit transient bridge from
`systemctl --user --machine=qualification@.host daemon-reload` is the supported
failing call: the paired transient-launch and daemon-reload errors follow the
successful bodies. At boot second 102.150554, SELinux denied PID 1 write access
to an `initrc_t` pipe; its API bus disconnected immediately afterward. Descriptor
receipt can itself trigger this permission check. The exact pipe endpoint and
kernel error path were not captured, so this is not proof of a PID 1 write
system call or of a provisioning-result collection race.

Installed reconciliation and feature changes now use the account's local user
bus through `runuser`, with explicit home/runtime/bus environment, a 30-second
deadline, five-second group-kill grace, and an existing-bus guard. Review caught
that killing only `runuser` could leave its client holding the updater's output
pipe; a real stalled-child fixture verifies the external timeout drains that
process group and closes the pipe. Failed reloads remain failures. Checkout
configuration already uses local account user-manager scope. Containment and
post-RPM manager synchronization remain intact. This product correction was
rebuilt and qualified in the final runs below. The failed 20/23 report supplies
no successful-commit, passive post-commit worker, or actual two-second timeout
credit. RPM-trigger bridge errors remain separate: manager reload does not
replay missed trigger work, and final service/marker health remains mandatory.
All failed-run resources were released and verified absent.

The final product build `20261021T230819Z-ff4d1c80` completed ISO/RPM assembly
and all 18 delivered checksum checks. Its ISO is
`CybexOS-Live-44-20261021T230819Z-ff4d1c80.iso`, 8,059,355,136 bytes, SHA-256
`a9ac9b820a0c694519085750df77babdc8973368e530c167be06fb505f177c59`.
The built source-content identity is
`6921f61669e9f90fb951af4e2790cb5771ff8b8f9623544399dbcb110a53160c`
across 1,452 files. Its desktop RPM SHA-256 is
`4c9e86666dee64a5b174a8f2eb30355d9f781f052eb2056ee224204cb922515f`;
the offline-apps 1.5.2 RPM SHA-256 is
`df9ce5a556c4717c785e1058f9384cc17b7e94eec664e98fb2d7f1e4901c80f5`.
Candidate copies matched the final delivery. Compiler provenance and shipped
binary/source binding were verified again for this build.

The final ISO passed all 12 standard UEFI plain-NL fresh-install checks in one
attempt, with outbound networking blocked. Shared validation and both exact
source guards passed without exceptions. The wrapper subsequently exited 1
because a PXE cleanup API request timed out. Bounded follow-up verification
obtained refresh `success`, confirmed the task's ISO entry absent, PXE running,
and `iventoy.service` active; no guest was rerun or service restarted. All owned
resources were released and independently verified absent. This fresh report
does not include outcome capture, Settings/reapplication extensions, physical
hardware, or Secure Boot.

Two later encrypted attempts exposed host qualification assertions after the
product had committed. Both remain failed 20/23 reports. First, a raw-source
comparison rejected the RPM's intentional snapshot-helper path rewrite from
`/usr/local/libexec` to `/usr/libexec`. The installed helper matched the canonical
package. Qualification now verifies the exact protected candidate RPM's size
and SHA-256, unique SHA256-manifest entry, installed ownership and content, and
exact installed NEVRA. The packaged helper digest is
`dc9b9d779ca5b634794622bf25df869a0c46b859ac5f26f37c0d696ebb815dba`;
the separately retained raw-source digest is
`1cc456440c28c44bbb012d7a58292b97a06b3d6d3a1842f877c994f5e63d2022`.

The next attempt completed commit, passive worker observation, and the actual
two-second timeout, but its final fresh health collector passed `-.mount` and
`-.slice` to `systemctl show` without an option terminator. The host collector
now inserts `--` before unit names in both scopes. Nested diagnostics retain
complete stderr up to 2,000 characters; larger stderr is omitted with explicit
size/limit metadata so truncation cannot expose a password suffix before outer
redaction. Literal escaped unit names remain unchanged. Independent review
and mutation regressions cover these corrections. All 43 public-harness and
25 offline-input fixtures passed, followed by the full Fedora gates described
above. Neither correction changes the installed product or weakens health
requirements.

The final encrypted-US upgrade qualification passed all 23 executed checks,
exit 0, on 2026-10-22. It booted the retained baseline ISO identified above and
used the exact final candidate RPMs plus 82 bound dependency RPMs. It exercised
real after-apply interruption, automatic pre-login rollback/restart, root,
package, vendor and personal-data preservation, and a separate settled cold
boot. Public run `20261022-003645-4061-18130` committed at 00:37:18 UTC. Passive
worker verification followed immediately, before the timeout test or cleanup.
The real two-second detached-writer test verified complete cgroup draining,
no later writes, and retained serialization for retry.

Both control SSH processes were closed and reaped before final fresh ordinary
SSH health inspection. Public `Manager.Version` returned `259.10-1.fc44`;
432 system and 171 user units had no pending restart/reload markers. All 18
required system and three user service requirements passed, as did
password-required and password-authenticated sudo. The installed helper matched
the candidate-bound packaged digest. Shared validation and independent root
validation accepted the exact 20 shared checks plus the three additional
executed checks. No retry, extra routine guest probe, security-policy change,
or enlarged timeout was used.

During that run, host source-content identity
`01cac1bb5713fcb0ca2138acd9814e852fc9ee11d212342d9eccfc6670febfb2`
differed from the built source only in the reviewed public qualification helper
and its tests; all paths and modes matched. All 30 loaded callables, imported
modules, both generated control/health strings, six task scripts, artifact
inputs, and start/end source guards passed unchanged. Documentation and staging
were finalized only after those guards completed. The upgrade report identifies
the baseline ISO it actually booted; final ISO linkage is not a second final-ISO
boot claim. The encrypted task's lease, capacity reservation, six QMP runtime
directories, 12 recorded processes, workspace, cgroup, path alias and mounts
were released and independently verified absent, with no cleanup errors.

Real local Restic fixtures cover restoring synthetic saves, readable volumes,
and a SQLite export, plus unreadable-volume partial-result handling. Backing up
a live database directory is still not a consistent database export; stopping
a process does not itself make subordinate-UID-owned files readable.

The qualified-series policy also selected Quickshell 0.2.1 from a disposable
DNF repository containing both 0.2.1 and 0.3. Native offscreen Welcome checks
exercise small logical screens and focus reveal; 640×480 expanded-error and
bottom-action views were inspected. These do not replace physical display or
assistive-technology checks.

The browser simulation passed 116 tests, lint, type checking, production build,
and two rendered-output tests. The existing web development service was rebuilt
and restarted; HTTP and health checks passed. Browser inspection confirmed the
new wallpapers load and Settings opens without console errors. This remains a
simulation, not compositor validation.

No startup or memory speedup is claimed. Existing shared state, lazy views,
guarded polling, source/Cargo caches, portal grace, ownership ledgers, and
deferred reconciliation were retained. The accepted fixes address demonstrated
failure transitions and provenance; compiler provenance alone does not promise
byte-identical rebuilds from moving Fedora packages.

## Release responsibilities

Installed payload changes require newly built, same-source ISO and RPM artifacts
and regenerated qualification reports before release. The offline payload
version advances once to 1.5.2. The complete four-scenario installation matrix,
two same-source checkout comparisons, additional prior-image upgrade paths,
physical hardware, and Secure Boot remain distinct release evidence. The final
encrypted run covers only the baseline/candidate pair recorded above; fixture
success must never substitute for those reports. The new public-updater guest
scenario is mandatory in the shared evidence contract.

Public distribution additionally requires real owner/legal decisions and the
documented protected review environment. `assets/distribution-review.json`
intentionally contains no invented approvals. Proprietary/SDK redistribution,
Steam, codecs/OpenH264, corresponding-source obligations, fonts, firmware,
application notices, artwork/wordmark rights, and trademarks need the recorded
decisions described in [licensing](licensing.md) and the
[redistribution audit](licensing-audit.md). Original replacement wallpapers do
not establish rights to unrelated components or to historical releases.

Task-owned temporary workers, VM media, screenshots, dependency fixtures, and
failed build attempts were removed through their recorded leases. The final
main validation lease is closed with no remaining resources or cleanup errors;
its Fedora container, network, and approximately 33 GiB workspace are absent.
Bounded review reports, logs, scripts, provenance and cleanup receipts are
retained under `~/.local/state/cybexos/audit-20261021-d668048/`, with a checksum
index and explicit evidence scopes. The source artwork remains a requested
deliverable. Existing operator-owned services, prior ISOs, and unrelated
worktrees are preserved. The web development service remains healthy and
returns HTTP 200.
