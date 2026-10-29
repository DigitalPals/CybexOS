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

## Software Update

**Software Update** is the one place to review and install system updates. The
menubar icon, Control Center's **Review** button, the launcher's **Software
Update** application and **Open Software Update…** action, and
`cybexos-software-update` (`cybexos-runtime ipc updates open`) all open it.
Closing the window never interrupts an update; the supervised worker owns it.
The window belongs to the shell, and activation or restoration restarts
`quickshell.service` when NixOS restarts the changed user unit. An open app
records that in `$XDG_RUNTIME_DIR/cybexos-software-update-open`, keyed to the
compositor session, so the replacement shell reopens it on the installing page
and it shows the result. Closing the app clears the marker; a new login never
reopens it. The first update that installs this behavior is applied by a shell
that lacks it, so its window still closes once.
Control Center keeps pending deployments and failures reachable even when there
is no update indicator.

The app shows one page at a time: checking, up to date, updates available,
getting the update ready, ready to install, installing, restart to finish,
finishing after the restart, and a problem page. Worker state wins over
discovery, so a prepared or restarting update is shown even when a source
cannot be checked.

Preparation downloads and builds a candidate without activating it. The ready
page then lists what people recognise first:

- **Important changes**: Cybex OS, the NixOS build (shown by date within one
  release), the Linux kernel, Mesa or NVIDIA graphics drivers, device firmware
  files and Hyprland, from old version to new. Each installed system declares
  these exact versions in `/etc/cybexos/components.json`; nothing is inferred
  from store path names. A system built before the manifest lists no
  components, and the review still works.
- **Apps**: installed packages with a visible `.desktop` entry, by their own
  name and icon.
- Release notes of a new Cybex OS version.
- A count of the remaining background components. Opening it shows programs
  without a window, the net size change, the exact `nix store diff-closures`
  output, the build log, update history, the source choice and **Discard
  Prepared Update**.

Same-version rebuilds are not shown as changes, and no store paths, hashes,
transaction IDs or tokens appear outside the technical details. The worker
publishes this grouping as `highlights` in `cybex update status`, and the
review token covers it with the package changes and closure diff. Nixpkgs does
not label security fixes, so the app does not claim them.

**Install Update** asks for authorization and is offered only after the
candidate passes its checks. A new personal configuration edit invalidates the
preview and requires preparation again. Finished failures (failed, interrupted
or rolled back) can be dismissed; dismissal, like discarding a preview,
preserves files and logs. Recovery that still needs attention cannot be
dismissed.

## Automatic preparation and confirmation

Two machine policies live in `/var/lib/cybexos/update-automatic.json`. Both
default to on. An unreadable file turns both off.

```sh
cybex update automatic prepare on|off   # download and prepare in the background
cybex update automatic confirm on|off   # keep a trial boot that passes its checks
```

Changing either asks for administrator authorization. Software Update's up to
date page and **Settings → Bar & Control Center → Updates** offer the same switches;
`cybex update status` reports both as `automatic`.

**Background preparation** is `cybexos-update-auto.service`, started by its
timer (15 minutes after boot, then every 6 hours, randomized) and by the
desktop when a check finds a new update. The desktop waits ten minutes after
sign-in unless the person checks explicitly. The unit runs only on AC power
(`ConditionACPower`) and skips metered or likely metered NetworkManager
connections. It submits an ordinary supervised `stage` request only when the
updater is idle or done and an update is available. It prepares each target
(personal configuration digest plus available source identities) once:
discarded or installed targets are not prepared again, and a failure of its own
is retried for a new target or after a day. Ready, stale, restarting,
recovering and failed changes belong to the person, so it leaves them alone.
Installing a prepared update still requires authorization.

**Automatic confirmation** is `cybexos-update-confirm.service`. Twenty seconds
after the signed-in shell sees a trial boot awaiting login, it starts the unit,
which submits the same `confirm` request as **Confirm this boot** did. Health
checks still decide: the system services, Hyprland, exactly one managed
Quickshell and its journal must pass. If confirmation fails, or the policy is
off, the app asks the person to keep the version or go back to the previous
one. Restarting without keeping it returns to the previous generation, as
before. A notification reports a completed update.

Both units take no input. They read the policy and the updater's own state as
root. A polkit rule lets an active local session of a `wheel` member start
exactly these two units without a password; every other unit start, and every
install, rollback or policy change, still requires authorization.

A missing/untrusted Cybex OS channel does not prevent selecting a confirmed
NixOS package update. Unavailable sources are explained and excluded from the
selected scope. Flatpak apps have their own update path; the system review
covers the NixOS generation and Cybex OS source.

Before the first Cybex OS release is published, HTTP 404 for the initial
channel document is neutral: the unpublished source is hidden and contributes
no error. Confirmed NixOS package updates remain selected and can be prepared
and installed independently. Missing signatures or manifests, invalid metadata
and the disappearance of a previously authenticated channel remain errors.

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

Device firmware is included in the regular **Software Update** flow. Checks
refresh fwupd's signed metadata; a firmware-only update uses the same
**Prepare Update → Install Update** actions when the OS sources are current.
The ready page lists each device and its old/new firmware versions. Preparation
never flashes hardware. The reviewed device releases are bound to the review
token, and installation rejects changed versions instead of silently adding
new releases. A failed firmware check remains unknown, rather than up to date;
it does not block a separately available OS update.

The supervised worker installs firmware after successful OS activation, or on
its own when only firmware is available. Closing the app or restarting the
shell leaves the worker running. Software Update displays device progress,
unplug/replug instructions, failures and the need for a restart or full
shutdown. Keep external power connected. Firmware changes are outside the Nix
transaction and are not reverted by a generation rollback. A device failure
does not roll back a successfully activated OS. Reboots and shutdowns remain
explicit. The optional terminal CLI is `cybexos-firmware-update interactive`;
the desktop has no separate firmware button or terminal launch.

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

`cybex update status` returns the structured `packageChanges`, `highlights`,
full built diff, transaction, review token and `automatic` policy.
`cybex update discard ID` clears an unapplied ready or stale preview, or
dismisses a finished failure; it cannot discard a pending generation or
recovery that needs attention.
`cybex update apply ID TOKEN` runs under a supervised systemd worker and rejects
stale review tokens or intervening personal edits. No widget/module is removed
to make evaluation or runtime checks pass. Actual build progress is phase-based;
private transaction logs hold build diagnostics. After a deliberate reboot and
authenticated desktop login, `cybex update confirm` validates system services,
Hyprland, exactly one managed Quickshell and its current journal.
The app distinguishes **Restart to finish** (before the trial boot) from
finishing after signing in. It never requests a second restart for
confirmation. **Go Back to Previous Version** and **Try Restoring Again**
remain explicit when confirmation fails or recovery needs attention.

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
invent a trust key or fall back to an unauthenticated branch. An unpublished
channel is quietly skipped; other delivery failures remain visible. Independent
NixOS package updates remain usable when their source check succeeds.

See [the investigation](measurements/update-system-audit-2026-10-26.md) for the
original failures and [the implementation record](measurements/update-system-fix-2026-10-26.md)
for validation scope.
