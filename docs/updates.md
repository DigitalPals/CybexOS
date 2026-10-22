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

`cybex update check` checks upstream and CybexOS independently. An unreachable
source is unknown/unavailable, never reported current. Nixpkgs checks identify
available revisions; preview builds expose the actual package closure changes.
The Update drawer has separate Upstream, CybexOS and Both preview actions,
installed/available versions, release notes, durable progress, errors, built
changes, restart requirements and recovery status.

An upstream discovery failure keeps `upstream.state` at `unreachable` and
explains that the Nixpkgs package-source status is unknown. A confirmed GitHub
API rate-limit response or HTTP 429 suggests retrying later; HTTP 403 without
rate-limit evidence is reported as access denied. Recognized server, DNS, TLS,
connection and timeout errors have separate guidance. Other Nix failures leave
the cause unknown and suggest checking network access and Nix configuration.
Malformed metadata also leaves the status unknown. CybexOS discovery still runs
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

The separate **Device firmware…** action opens a terminal, refreshes fwupd's
signed metadata, shows the selected devices and versions, and asks before
installation. The launcher also provides **Review device firmware…**; the CLI
is `cybexos-firmware-update interactive`. fwupd supplies authentication,
signature checks and device progress. Keep external power connected and follow
device-specific instructions. Firmware changes are outside the Nix transaction
and are not reverted by a generation rollback. Reboots remain explicit.

`cybex update stage upstream|cybexos|both|local` authenticates selected release
metadata before evaluation, snapshots the entire personal configuration and
updates only the chosen inputs. CybexOS-only updates include its source-declared
vendor dependency graph while preserving root upstream/personal inputs. They
never select code from a moving branch. Failed combined previews offer the
explicit `stage upstream` retry retaining installed CybexOS; that combination
must build and pass candidate checks too.

`cybex update status` returns the built diff, transaction and review token.
`cybex update apply ID TOKEN` runs under a supervised systemd worker and rejects
stale review tokens or intervening personal edits. No widget/module is removed
to make evaluation or runtime checks pass. Actual build progress is phase-based;
private transaction logs hold build diagnostics. After a deliberate reboot and
authenticated desktop login, `cybex update confirm` validates system services,
Hyprland, exactly one managed Quickshell and its current journal.

A failed deployment is quarantined by complete system identity. Inspect the
cause before using `cybex update retry-failed ID` to explicitly allow another
preview of it. Retry permission covers prior failures of that exact system and
is consumed only after a successful preview. Recovery is separate from authenticated normal updates; a channel
cannot use a lower semantic version as a normal update.

Advancing 26.05 is routine. Changing the root stable branch is a deliberate major
upgrade and currently requires new compatibility qualification. Never change
`system.stateVersion` as part of a routine update.
