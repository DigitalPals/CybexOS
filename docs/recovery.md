# Recovery, persistence and garbage collection

The updater serializes operations with a machine lock and publishes status and
pending records with fsync and atomic rename. Downloads use atomic cached files.
Evaluation/build happens in a private staged configuration; neither changes the
working system. Each transaction retains its full configuration, lock file,
input archive identities, candidate and previous system, and actual diff.
Indirect Nix GC roots protect these inputs and known-good systems.

Activation tests the candidate before selecting its boot configuration. It saves
a durable pending record first. Failure restores the previous system and its
configuration. Before rollback, working personal edits are copied into the
transaction's `personal-before-rollback` directory; they are not discarded.
NixOS service-warning exit 4 is checked through the declared health services;
unrelated failed units do not prevent restoration. Genuine activation errors
still fail closed. A busy recovery unit defers to the supervised operation that
holds the lock, and rollback disarms a rejected trial before updating boot files.
An interruption at application boundaries is recovered by `cybexos-recover`,
which stays completed for the rest of that boot so activation cannot start a
second recovery worker. Interrupted staging is reported and can be staged again.

`cybex update status` reports `recovery-failed` if restoration itself fails.
The durable pending record remains, and further previews are blocked. Inspect
`cybex update log ID` for private build, activation and restoration output;
correct the reported cause, then run `cybex update rollback ID` to retry the
retained restoration. The desktop keeps its Rollback and private-log controls
available. Rebooting into the retained known-good boot entry also resumes
recovery. A failed restoration never reports the previous generation as
restored, and its transaction retains both the original activation error and
the restoration error. These steps preserve personal configuration and state;
they do not promise application-data rollback.

The previous generation stays the persistent systemd-boot default. The candidate
is a one-shot trial, selected once. A failed boot requires a user-selected reset
or reboot; the next boot returns to the previous default. There is no unattended
reboot or hardware watchdog reset. A successful fresh boot and authenticated
Hyprland/Quickshell login must pass `cybex update confirm` before the candidate
becomes the persistent default. Failed systems are quarantined against normal
reapplication. `cybex update history` and `cybex update rollback [ID]` expose the
retained identities and restore coherent system/updater configuration.

System health requires the boot target, NetworkManager and login manager to be
active. When Libreswan is enabled, its managed `ipsec.service` must also be
active so Cisco IPsec connections have their required daemon. Add critical
personal services in `/etc/nixos/local/*.nix`, for example
`cybexos.updates.additionalHealthServices = [ "personal.service" ];`.
The shared modules generate `/etc/cybexos/health-services.json` for the updater;
disabled optional services are not required. Failed checks identify the unit
and retain the pending recovery record instead of accepting the deployment.
Selected XPS hardware also requires its haptic daemon and, in an authenticated
desktop, speaker tuning. The selected processed camera requires a separate
booted-kernel ABI check and the relay; an ABI failure blocks relay startup and
trial acceptance. These service checks do not prove processed frames, privacy,
image quality or suspend/resume; those still require physical qualification.

From live media, unlock/mount the target filesystem and ESP, inspect
`/var/lib/cybexos/transactions` and its deployment records, and select the
retained previous system using its `switch-to-configuration boot` inside
`nixos-enter`. Restore `/etc/nixos` to that record's retained configuration as
well. This is an offline repair requiring explicit administrator intent, not a
routine update shortcut. Keep backups of ESP contents and enrolled Secure Boot
public certificates.

Regular configuration Git metadata remains persistent outside source snapshots;
selected writable trees reference the retained metadata directory. Follow the
`.git` target before deleting any old working directory. Repeated rollback makes
a fresh working selection and preserves edits in earlier selections instead of
reusing them as the retained deployment configuration.

System generations are not filesystem snapshots. Home files, credentials,
NetworkManager profiles, VPN keys, plugin data and service databases remain
persistent through activation and rollback. Personal backups remain separate.
Future data/schema migrations require an application-aware backup, explicit
migration metadata, tested rollback policy and compatible old readers. Never
silently downgrade a newer database or unknown preference schema.

Open **Settings → Storage & cleanup** to inspect store filesystem capacity,
review cleanup, set retention, and pin confirmed recovery points. Manual cleanup
requires authentication and a current review token. Pin/configuration/history
changes invalidate an earlier review. Estimates count uncompressed NAR bytes;
shared paths and filesystem compression can make reclaimed disk space differ.

Retention keeps at least five confirmed deployments and 30 days of history,
plus pins, the running system and its fallback, selected personal configurations,
and unresolved or failed transactions. A failed build without pending activation
can still be cleaned up, while its input roots and diagnostics are retained.
Before the first confirmed deployment,
manual cleanup collects garbage while retaining every recovery reference;
automatic cleanup skips that boot. Another kept transaction's input and
fallback roots remain protected. Cleanup removes only managed GC references
and matching obsolete system-profile generations. Other Nix profiles and roots
remain authoritative. Documents, downloads, application data, logs, transaction
records, lock files and saved personal edits are not deleted. Retired records
remain visible in history and cannot be rolled back after their store roots
have been released.

A durable cleanup journal and the updater's operation lock serialize profile
pruning, boot-entry regeneration, root release and Nix garbage collection.
Boot entries are regenerated from the confirmed running system before old
kernels can be collected; its confirmed boot selection is restored. Secure Boot
configuration is unchanged. An interruption keeps the journal and blocks new
deployments. **Resume cleanup**, `cybex maintenance resume`, or boot recovery
continues idempotently from the initiating confirmed system. Inspect the private
`/var/lib/cybexos/maintenance.log` and the supervised system service on failure.
Settings detects a stopped worker and offers recovery from the durable journal,
including after reopening the desktop.

Weekly cleanup is enabled by default on fresh installations. Disable it or
change retention in **Settings → Storage & cleanup**; preferences change the
machine-owned `local/maintenance.json` through a staged preview and apply. An
explicit personal opt-out remains respected. The persistent weekly timer runs
with idle I/O priority and randomized delay. It
obeys retention/pins and skips active updates, an unconfirmed boot or unresolved
recovery. Generic Nix automatic GC remains disabled by default so the Cybex OS
retention policy owns automatic cleanup. Physical boot/recovery qualification
is a separate launch requirement.

For scripting, use `cybex maintenance status`, `preview`, `clean REVIEW TOKEN`,
`pin DEPLOYMENT true|false`, `policy JSON`, `request ID`, and `resume`.
