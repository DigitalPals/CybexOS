# Stack optimization audit — 28 October 2026

The audit covered the native desktop and helpers, browser desktop, lifecycle
engine, installer daemon/kiosk, Nix packaging and modules, hardware integration,
release tooling, assets and validation paths. Three implementation agents worked
on separate components; changes were also reviewed across component boundaries.
The baseline was `643d71ce0543943bd08077fc4b3f15b66f06a202`.

## Implemented changes

| Area | Change | Benefit and behavioral limits |
| --- | --- | --- |
| Desktop updater | Poll status every 30 seconds while idle and closed; retain 2 seconds for visible/active/pending work and login confirmation. | 2,880 instead of 43,200 periodic CLI launches per idle day. Opening the app refreshes immediately; externally initiated work can take 30 seconds to appear while closed. |
| Dock defaults | Query only effective browser/terminal IDs on periodic ticks. | Avoids up to 2,880 full application-catalog scans per idle day. Application-entry changes and visible Applications Settings still refresh full catalogs; newer Settings choices supersede older dock queries. |
| Process drawer | Retain a bounded set of top processes instead of sorting the entire snapshot. | Less copying, allocation and comparison work for the six visible rows. Existing CPU/memory/PID ordering and stable ties are preserved; larger requests use native sorting. |
| Emoji launcher | Retain bounded relevance buckets and construct only visible rows. | Avoid building and sorting the entire emoji catalogue on each keystroke. Ranking and source-order ties remain unchanged. |
| Browser quota state | Dispatch quota refreshes only at reset deadlines or when returning to the page. | An idle window tree no longer rerenders every 30 seconds. Foreground clock corrections are checked within 30 seconds without dispatching unchanged state; hidden tabs suspend checks. |
| Browser usage panel | Update clocks at displayed reset/age boundaries; stop the timer in Proxy. | Removes the full panel's one-second update cadence while preserving sub-second reset deadlines. |
| Browser terminal | Memoize immutable scrollback and entries. | Typing, history and completion leave prior output and ASCII artwork alone; new entries still announce through the existing live log. |
| Updater configuration | Prune `.git` directories before traversal; stream file hashing in 1 MiB blocks. | Avoid traversing ignored object databases and allocating entire payloads. Existing digest format, executable bits, empty directories and link/special-file rejection remain intact. Unreadable directories and size changes during hashing fail closed. |
| Installer daemon | Persist only changed drafts; encode each broadcast once. | Network/progress updates do not rewrite an unchanged draft. Nested changes invalidate the cache; failed writes retry; a restarted daemon persists its loaded draft. |
| Nix packages | Select only installation inputs for desktop, installer wrapper and password dialog. | Unrelated web/docs/tests edits no longer invalidate independent package sources. Full authenticated release source remains available through the updater; version metadata and kiosk/native-image source selection are preserved. |

## Measurements

These are controlled helper measurements, not boot-time, hardware, battery-life
or end-to-end desktop latency claims. Numbers are medians; run-to-run variance
and different JavaScript engines can change their magnitude.
Daily polling counts above are derived from timer intervals, not daylong traces.

| Workload | Baseline | Optimized | Method |
| --- | ---: | ---: | --- |
| Configuration digest | 63.803 ms | 3.147 ms | Seven warm-cache runs; 20 modules, 6 MiB payload and 6,400 ignored Git objects; identical digest. |
| Digest peak Python allocation | 12,600,231 bytes | 2,117,654 bytes | Same fixture, `tracemalloc`; Python 3.13.5. |
| Top six of 4,096 processes, CPU | 0.3963 ms | 0.01559 ms | Node 22.22.3; seven batches of 200 calls after warmup. |
| Top six of 4,096 processes, memory | 0.3692 ms | 0.01447 ms | Same setup. |
| Eight emoji rows from 4,000, empty query | 0.1864 ms | 0.001649 ms | Same setup. |
| Eight emoji rows from 4,000, broad `face` query | 0.5216 ms | 0.2198 ms | Same setup. |

Additional emoji queries improved by about 1.3–1.5 times in that fixture.
Full-sort regression comparisons cover thousands of entries, ties and limits.
Browser render-count tests cover idle windows, hidden-tab recovery, quota
deadlines, clock corrections and terminal typing; they do not measure CPU time.

The Nix source-selection check exercised the real desktop derivation in a
disposable source copy: an unrelated README edit kept both its source store path
and derivation unchanged; changing a runtime input changed both. A separate
selection fixture checked exact files and parent-directory inclusion.

## Validation

The tested code snapshot was
`sha256-sU71snePJGnNLIi+gIXFdz6MeIwDPwwhVPTEET22LT4=`
(`/nix/store/539jswp1lx8q8qix8vpn3wl6ld3kijll-source`), excluding this report.
The following checks completed on the Beast:

- `nix develop -c tests/run`: passed, including 721 NixOS source tests and
  1,494 passing desktop Node tests (16 explicitly skipped), bridge/helpers,
  settings, plugin/theme and Model Usage checks.
  All 15 dock tests were rerun after the final Settings visibility guard.
- `tests/qml-lint`: 438 QML files and four harnesses passed; eight existing
  warnings across property override, missing type and incompatible type categories.
- `tests/nixos-native`: real Nix/Git input changes, exact NAR fetching,
  authenticated HTTPS, source transfer and retention/GC in private stores passed.
  Child commands required enabling `nix-command flakes` through `NIX_CONFIG`.
- Browser desktop: lint, typecheck, 121 tests, production build, two rendered
  HTML/packaging tests and production HTTP/wallpaper smoke checks passed under
  Node 24.21.0.
- Built the lifecycle VM driver and installer package, including package checks.
- `nix flake check --no-build` and the shared installation-contract parity check
  passed. This parity check compares Nix module contracts, not ISO contents.
- The actual lifecycle VM passed in 156 seconds from the identified source:
  supervised software, maintenance and local-update staging; preservation of
  personal configuration/locks; stale-review rejection; discard; interrupted
  worker recovery; desktop package checks; greeter/Plymouth and SSH restart
  checks. The test used a managed task workspace and a CI capacity reservation.
  `QEMU_OPTS=-no-user-config` kept host-specific QEMU configuration out of it.
  It does not activate a newly staged candidate or exercise a fresh installation.
- Rebuilt and restarted the existing `cybexos-web` Compose service; its health
  check, desktop response and bundled wallpaper passed on port 5174.

No ISO was produced; ISO/source parity, fresh installation and representative
physical hardware qualification are separate requirements.

Task dependency/source snapshots, output links, logs, screenshots and VM disks
were removed. All ten managed task leases closed with no remaining owned
resources or cleanup errors; the CI capacity reservation also ended. No
temporary diagnostic artifacts were retained.

## Further work that needs evidence

Hardware polling is already event driven where appropriate. Security, hardware
support, power policy and authentication were left intact. Release downloads
already stream verification; the kiosk already caches state/models and enables
release optimization. No framework/runtime replacement was justified.

Browser drag/resize batching and wider window memoization need profiling with
representative workloads. Debouncing note saves changes durability and needs
explicit close/unload handling. Wallpaper assets are already small (about
92 KiB), and fonts are local. Bridge execution is already bounded/coalesced.
Those areas should be measured before adding more caching or changing behavior.
