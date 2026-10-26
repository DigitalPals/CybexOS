# Independent updates

The machine owns `/etc/nixos/flake.nix` and `flake.lock`:

```nix
inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
inputs.cybexos.url = "github:DigitalPals/CybexOS/EXACT_AUTHENTICATED_REVISION";
inputs.cybexos.inputs.nixpkgs.follows = "nixpkgs";
```

Add personal inputs explicitly and make their Nixpkgs follow the same root.
The updater rejects duplicate Nixpkgs universes and unrelated lock changes.
Upstream binaries use `cache.nixos.org`; no extra cache key is implicitly trusted.
The 26.05 package set needs a narrowly scoped Hyprland 0.56.2/hyprutils 0.14
compatibility overlay for the existing Lua desktop and native titlebars, plus a
scoped build-time Wayland protocol pin and the required Aquamarine source fix.
It uses Nixpkgs recipes and the single machine package universe. `nix/desktop-compatibility.nix`
records exact source identities; remove it after stable catches up and the
runtime qualifies. Other upstream inputs continue to advance independently.

`cybex update check` checks upstream and Cybex OS independently. An unreachable
source is unknown/unavailable, never reported current. Nixpkgs checks identify
available revisions; preview builds expose the actual package closure changes.
The menubar shows one icon only when a source has confirmed an available
update. There are no source counts, zero badges or success/error icons.
The icon and Control Center's **Review** button open the same System updates
review. Control Center keeps pending deployments and failures reachable even
when there is no update indicator.

Select the available sources, then use **Prepare update**. Preparation downloads
and builds a candidate without activating it. The review lists the exact
installed package names and before/after versions, including additions,
removals and same-version rebuilds. **Show system details** exposes the full
closure diff for dependencies and system components, plus logs and recovery
actions. Release notes appear
alongside the selected source. The single primary action becomes **Update**
only after the candidate passes its checks. A new personal configuration edit
invalidates the preview and requires preparation again. **Discard preview**
clears only an unapplied preview and preserves its files and logs.

A missing/untrusted Cybex OS channel does not prevent selecting a confirmed
NixOS package update. Unavailable sources are explained and excluded from the
selected scope. Flatpak apps have their own update path; the system review
covers the NixOS generation and Cybex OS source.

An upstream discovery failure keeps `upstream.state` at `unreachable` and
explains that the Nixpkgs package-source status is unknown. A confirmed GitHub
API rate-limit response or HTTP 429 suggests retrying later; HTTP 403 without
rate-limit evidence is reported as access denied. Recognized server, DNS, TLS,
connection and timeout errors have separate guidance. Other Nix failures leave
the cause unknown and suggest checking network access and Nix configuration.
Malformed metadata also leaves the status unknown. Cybex OS discovery still runs
after an upstream failure, so each source keeps its own result.

Discovery creates no deployment or transaction log. Its public error includes
this read-only diagnostic command, which can be run locally without elevation:

```sh
nix flake metadata --refresh --json github:NixOS/nixpkgs/nixos-26.05
```

Checks classify command diagnostics internally and publish only static guidance;
they do not log the raw discovery output. The command above may show private
URLs or configuration details: inspect its output locally and redact secrets
before sharing it. Checks do not retry automatically or require an account or
authentication token.

The launcher's **Review device firmware…** action opens a terminal, refreshes fwupd's
signed metadata, shows the selected devices and versions, and asks before
installation. The CLI is `cybexos-firmware-update interactive`. fwupd supplies authentication,
signature checks and device progress. Keep external power connected and follow
device-specific instructions. Firmware changes are outside the Nix transaction
and are not reverted by a generation rollback. Reboots remain explicit.

`cybex update stage upstream|cybexos|both|local` authenticates selected release
metadata before evaluation, snapshots the entire personal configuration and
updates only the chosen inputs. Cybex OS-only updates include its source-declared
vendor dependency graph while preserving root upstream/personal inputs. They
never select code from a moving branch. After a failed combined preview, select
only the available NixOS package source
to retain installed Cybex OS; that combination must build and pass candidate
checks too. The equivalent CLI action is `cybex update stage upstream`.

Every stage/apply/discard/rollback/confirm request returns `accepted`, a
`requestId` and its `cybexos-update@ID.service` unit. Acceptance means the request
was queued. `cybex update request ID` returns its durable queued/running/done/
failed result. `cybex update status` includes that result separately from the
current deployment, so preflight errors cannot disappear on the next poll or
shell reload. The reader detects a dead preparation worker as interrupted;
interrupted activation/recovery requires restoration. An unknown worker status
blocks duplicate requests until it can be checked. Authentication cancellation
and helper startup/timeout errors are visible in the review.

`cybex update status` returns the structured `packageChanges`, full built diff,
transaction and review token. `cybex update discard ID` clears an unapplied ready
or stale preview; it cannot discard a pending generation.
`cybex update apply ID TOKEN` runs under a supervised systemd worker and rejects
stale review tokens or intervening personal edits. No widget/module is removed
to make evaluation or runtime checks pass. Actual build progress is phase-based;
private transaction logs hold build diagnostics. After a deliberate reboot and
authenticated desktop login, `cybex update confirm` validates system services,
Hyprland, exactly one managed Quickshell and its current journal.
The review distinguishes **Restart to finish** (before the trial boot) from
**Confirm this boot** (after signing in); it never requests a second restart
for confirmation. **Restore previous generation** remains explicit when
recovery needs attention.

A failed deployment is quarantined by complete system identity. Inspect the
cause before using `cybex update retry-failed ID` to explicitly allow another
preview of it. Retry permission covers prior failures of that exact system and
is consumed only after a successful preview. Recovery is separate from
authenticated normal updates; a channel
cannot use a lower semantic version as a normal update.

Advancing 26.05 is routine. Changing the root stable branch is a deliberate major
upgrade and currently requires new compatibility qualification. Never change
`system.stateVersion` as part of a routine update.

## Release delivery prerequisite

The public audit on 2026-10-26 found that the stable and beta channel URLs
returned HTTP 404, the public GitHub release list was empty, and the repository's
publisher trust configuration contained no keys. Desktop/backend fixes cannot
publish or authenticate a vendor release by themselves. Deployment operators
must provision the real publisher public keys and publish qualified signed
release/channel metadata through the documented release procedure. Never
invent a trust key or fall back to an unauthenticated branch. Until delivery is
configured, the Cybex OS source reports unavailable; independent NixOS package
updates remain usable when their source check succeeds.

See [the investigation](measurements/update-system-audit-2026-10-26.md) for the
original failures and [the implementation record](measurements/update-system-fix-2026-10-26.md)
for validation scope.
