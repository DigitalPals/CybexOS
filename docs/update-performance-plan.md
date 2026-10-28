# Update preparation progress

The user chose progress reporting without adding a binary cache service. The
previous Cachix proposal was cancelled; no cache endpoints, trusted keys,
publisher credentials or release publication changes are part of this work.

## Why preparation sometimes builds packages

Nixpkgs supplies recipes. Nix normally substitutes their exact outputs from
`cache.nixos.org`, with signature verification. Packages already in the store
need neither download nor rebuild. A custom recipe, patch or dependency produces
a different store identity; an upstream binary cannot replace that identity.
Cybex OS requires its matched Hyprland/graphics/plugin stack. Dropping that
compatibility overlay would remove required desktop functionality.

The affected-machine investigation measured 294.387 seconds of preparation,
including about 204 seconds in Hyprland's build. This UI change does not reduce
that compilation time. See [the measurements](measurements/update-performance-2026-10-28.md).

## Implemented behavior

The staged updater observes Nix's `internal-json` stderr activities while keeping
`--json` build results on stdout unchanged. This applies to selected source
prefetch, selected lock updates, source archiving and the complete system build.
It preserves authentication ordering, immutable vendor sources, personal inputs,
GC roots, review tokens, compatibility checks and supervised activation.

Public status contains a versioned `progress` object with fixed activity labels,
compressed transfer bytes, known transfer totals, aggregate build counters and
active component categories. It never copies Nix messages, store paths, cache
URLs, compiler output or personal derivation names into public status. The
parser limits both buffered line size and retained concurrent activities, ignores
unknown/malformed events, and coalesces status publications to at most once per
second, with initial/final snapshots at command boundaries. Observer failures
do not terminate the underlying command.

Software Update shows:

- **Prepare Update** and **Download and build**, with explanatory copy that
  includes building.
- Current activity such as **Downloading packages**, **Compiling window manager**,
  **Building system components** or **Checking compatibility**.
- Transferred bytes, reported build counts and elapsed time.
- A measured download bar when downloads have known totals and no concurrent
  builds; an indeterminate activity bar during compilation and other work.
- A **Build Log** action during preparation, using the existing administrator
  authorization and private log reader. Structured log records are rendered as
  readable diagnostics there. Closing the window leaves the worker running.

Download totals and build counts may grow as Nix discovers dependencies. They
are never presented as an overall update percentage or an estimated finish
time. Stopped individual build activities do not count as successful builds;
Nix's aggregate counters report completion/failure. Some builds only generate
configuration files, so build counts do not mean application compilation counts.
Reduced motion and accessible progress labels are supported, with Dutch copy.

`operationStartedAt` and `finishedAt` bound elapsed time to the current operation.
The ready duration freezes; later activation starts its own clock. Read-only
worker-death reconciliation clears stale progress and freezes at the last
observed update when no completion timestamp is available.

## Validation

See the final validation record below. Tests cover actual subprocess stream
separation, protocol parsing and bounded inputs, safe public labels, concurrent
build/download behavior, throttling, observer restoration, duration freezing,
helper fallbacks and the real Quickshell app in an isolated headless compositor.
The app test uses scripted backend responses; it is UI coverage, not an
installed-system qualification. NixOS VM checks separately exercise the real
packaged staged updater and an interrupted real build.

No ISO or release is published and no user's workstation is changed by this
work. Build support and cache configuration remain as before.

## Validation results — 2026-10-28

- All 706 Python source regression tests pass after the final Runner change.
  The remaining `tests/run` Python helpers also pass.
- JavaScript: 1,468 pass, 16 skipped, zero failures. Translation coverage and
  placeholder checks pass.
- QML: 434 production files and four test harnesses pass lint, including the
  native module tests. Existing nonfatal lint warnings remain.
- `tests/update-flow.py` passes in a private headless Sway session. It exercises
  compilation labels, elapsed time, reopening during preparation, measured
  transfer progress, log-button availability and the existing recovery flow.
- Disposable real builds with Nix 2.26.3 and 2.34.9 verify stdout/stderr
  separation, aggregate counters, completion and published activity during a
  silent build. Probe outputs and derivations are removed afterward.
- An initial staged VM run exposed missing publication of throttled trailing
  events during silent builds. Runner now ticks the observer during quiet
  periods; a real subprocess regression test covers that failure.

The final staged VM uses isolated source revision
`eb3f27b07f2271842612823424e5ab5940d966aa`, containing the exact runtime code
in this change. The host CI controller has no CybexOS adapter, so VM execution
uses `agent-resource` leases. QEMU is started with `-no-user-config`, and its
runtime directory and disks live in the lease workspace. This avoids the
host's restricted QEMU configuration and leaves existing services untouched.
The complete lifecycle VM script passed in 164.23 seconds. It prepared real
software, maintenance and local update candidates, verified frozen preparation
time, observed an active real build within 12.02 seconds, killed its supervised
worker and verified interruption with cleared progress within 0.20 seconds.
Personal configuration/review safety and the existing desktop, recovery, network
and SSH checks also passed. This is staged-updater VM coverage; no fresh ISO installation, physical hardware or release qualification
is claimed.

All task leases were closed and checked for remaining resources. Their VM
disks, screenshots and runtime directories were removed. Disposable source
copies, diagnostic logs and probe scripts were removed after recording these
results. Existing Nix build-cache outputs are retained as normal store content;
no ISO or large review artifact is retained.
