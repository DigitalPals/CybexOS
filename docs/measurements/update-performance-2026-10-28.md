# Software Update preparation performance — 2026-10-28

The implementation/UI observations below describe the investigated baseline.
The subsequent [progress implementation](../update-performance-plan.md) changes
reporting only; the user declined the proposed cache service.

## Findings from the implementation and binary cache

The affected machine's actual upstream preparation completed in **294.387
seconds (4m54s)**. Its Hyprland build log spans approximately **204 seconds
(3m24s), 69.3% of preparation**. Local compilation is the confirmed main
bottleneck in this transaction. The preparation page labels this work only
**Download**. The default binary cache does not contain the sampled
CybexOS-specific compositor packages.

Repository inspected: `ba12e6eb0478832f36a1b9d78b37ad23756d0750`.
No software changes or workstation update operations
were performed for these findings.

### What happens before the review

[`Engine.stage`](../../lifecycle/cybexos/engine.py) performs these operations
serially:

1. Authenticate selected vendor metadata, when the scope includes Cybex OS.
2. Snapshot and verify the personal configuration; update only selected locks.
3. Archive the candidate flake and retain its input sources with GC roots.
4. Run `nix build` on the complete machine's
   `nixosConfigurations.cybexos.config.system.build.toplevel`.
5. Retain the candidate and current systems, snapshot the previously deployed
   configuration, and archive/root its inputs too.
6. Check the candidate compositor and QML/plugin runtime, compare package and
   component manifests, and produce the review token.

Only then does the app offer **Install Update**. A complete candidate build
does not compile every package: Nix reuses exact outputs already in the store
or available from a configured cache. Cache misses are the expensive case.
[`Engine.apply`](../../lifecycle/cybexos/engine.py) activates the reviewed system
and checks health; it does not run the full build again.

### Confirmed binary-cache gap

[`nix/modules/default.nix`](../../nix/modules/default.nix) configures only
`https://cache.nixos.org` by default. The
[release workflow](../../.github/workflows/release.yml) builds/qualifies the ISO
and publishes immutable release assets, without publishing a Nix binary cache.
[The validation document](../validation.md) already records that public cache
hosting and explicit trust remain release work.

On the Beast, read-only Nix evaluation used the repository's exact committed
flake and locked Nixpkgs revision
`da6dc0e7b26060f2f71ce3ef7088fb56ee44fa36`. HTTP HEAD requests to the exact
outputs' `https://cache.nixos.org/<store-hash>.narinfo` URLs returned:

| Package | Stock version/cache | CybexOS-selected version/cache |
| --- | --- | --- |
| Hyprland | 0.55.4 / 200 | 0.56.2 / 404 |
| hypridle | 0.1.7 / 200 | 0.1.8 / 404 |
| Aquamarine | 0.11.0 / 200 | 0.11.0, patched / 404 |
| hyprcursor | 0.1.13 / 200 | 0.1.13, different dependencies / 404 |
| hyprgraphics | 0.5.1 / 200 | 0.5.1, different dependencies / 404 |
| hyprlang | 0.6.8 / 200 | 0.6.8, different dependencies / 404 |
| hyprutils | 0.13.1 / 200 | 0.14.0 / 404 |
| hyprwire | 0.3.1 / 200 | Not sampled in the customized graph |

The customized library outputs sampled were the `dev` outputs actually passed
as direct build inputs to the customized Hyprland derivation. Stock samples
were each package's default output. They are not byte-for-byte equivalent
outputs, but a missing required `dev` output still requires realizing its
customized derivation. Missing outputs were not downloaded or compiled by the
probe. Successful HEAD requests establish metadata availability, not a tested
binary substitution or NAR transfer.

The overlay deliberately scopes newer libraries to the compositor. Its
top-level `pkgs.hyprutils` remains stock; inspect
`hyprland.buildInputs` to see the actual customized libraries. See
[`nix/desktop-compatibility.nix`](../../nix/desktop-compatibility.nix).

Updating Nixpkgs can change the dependencies and therefore output identities of
these custom builds even if their displayed versions stay the same. A newly
installed ISO carries prebuilt outputs for its original lock; that does not
provide outputs for every subsequent Nixpkgs revision. Custom titlebars and,
on applicable hardware, the IPU7 camera stack also have local derivations.
The actual titlebar build interval is recorded below; the affected machine is
AMD-based and this inspection does not attribute time to IPU7.

### The interface hides the expensive operation

[`UpdateView.qml`](../../desktop/quickshell/SoftwareUpdate/UpdateView.qml)
uses **Getting the update ready** for discovery, building and validation. The
first visible step remains **Download** throughout discovery and building,
including both input archives and actual compilation. Only `validating`
advances it to **Check compatibility**. The explanatory text also omits building.

The engine reports `progress: null` and a broad building phase. Nix output goes
to the private transaction log, without structured download/build activity or
per-command start/finish timings. The status reader already computes
`elapsedSeconds` and `phaseElapsedSeconds`, but this preparation page does not
display them. The ordinary preparation page does not offer the log button;
that button is in the ready review's technical details and problem details.

[`Runner`](../../lifecycle/cybexos/common.py) permits each ordinary command to
run for up to 7,200 seconds. The update worker's systemd startup timeout is
infinite. This permits legitimate slow builds, but the page cannot tell someone
whether it is downloading, compiling, waiting for a daemon job, or stalled.
These limits are not deliberate two-hour sleeps.

### Secondary overhead and background scheduling

Candidate and previous-configuration input archives, per-input GC-root commands,
configuration copying/hashing, and the built manifest/diff review all run
serially. They preserve recovery and personal configuration integrity; do not
remove them without an equivalent guarantee. Their time contribution is not
established by reading the code.

Warm, offline, read-only evaluation on the Beast took 1.59 seconds for the
desktop derivation and 7.928 seconds for the small test system derivation.
These measurements used existing source/build caches, performed no system
build, and are not an installed-machine or upstream-update benchmark.

Background preparation waits ten minutes after desktop sign-in unless an
explicit check enables it sooner. The system timer starts after 15 minutes
with up to 30 minutes random delay, then every six hours. Its service requires
AC power and skips metered connections. The automatic unit independently
checks sources again before submitting an ordinary stage worker.

These policies can explain why work has not finished before a person opens the
app. They do not impose those waits on an already running manual stage request.
The two-second UI status timer only reads status; it does not rebuild every
two seconds. Preparation is serialized and requests are guarded against
duplicates.

## Recommendations from the investigation (before scope selection)

1. Publish signed prebuilt CybexOS-specific package outputs and required build
   outputs for supported machine Nixpkgs revisions. Add an explicitly trusted
   cache through the release contract. Because machine Nixpkgs advances
   independently, publishing only one vendor release's original lock is
   insufficient. Preserve hardware support, exact release identity and
   personal inputs; do not remove the compositor compatibility overlay just
   to reduce build time.
2. Expose meaningful phases and elapsed time immediately. Add a preparation log
   action and translate Nix's structured activities into public-safe download
   and build progress, retaining private raw diagnostics. A phase-only rename
   would improve honesty but would not make compilation faster.
3. Record command/phase timings and cache hit/miss/build counts so future
   regressions can be located. Then optimize measured archive/evaluation or
   redundant discovery work, retaining source roots and recovery boundaries.
4. Validate changes through the real staged updater, including an upstream
   revision change, cold missing custom outputs, and a warm cache. Compare
   preparation and apply separately. UI fixtures or a successful Nix build
   alone do not establish an improved update experience.

## Affected-machine inspection

The user authorized read-only SSH inspection of `10.10.1.64` and explicitly
confirmed its changed host key before authentication. A private task-local
known-hosts file pinned that exact key; the existing SSH trust file was not
replaced. No update, activation, configuration edit, service restart or reboot
was initiated on the machine. Its existing candidate was preserved ready for
review.

### Installation and transaction identity

- Host: `john-cybexos`, AMD Ryzen AI 9 HX 370, 12 cores/24 threads, 60 GiB RAM.
- Installed vendor version: `1.0.0-beta.14`, development path source
  `/nix/store/cw692r7a1rb9jbj64j7x3sc864m5kabf-source`, NAR
  `sha256-xuhzYE9g9/9cRWQ1Y+tpJ24d3n2gwtTaw0cLei4fHJE=`.
- SHA-256 of the installed vendor's `engine.py`, `common.py`,
  `SoftwareUpdate/UpdateView.qml` and `desktop-compatibility.nix` matched the
  inspected checkout byte-for-byte. The installed vendor version is newer
  than the checkout version, but the relevant code is identical.
- Transaction: `48c84397789b431ab5b1c5ccde54eee0`, scope `upstream`.
- Worker: `cybexos-update@fd734486e92b4f2c980b0f5980d4d26d.service`.
- Nixpkgs: `da6dc0e7b26060f2f71ce3ef7088fb56ee44fa36` →
  `718f670e845328e9c2cecdd832835712b2cbd065`.
- Worker journal: started `2026-10-28 19:20:31.008907 +01:00`, finished
  `19:25:25.528535 +01:00`, successfully.
- Durable engine start-to-ready: 294.387 seconds; request created-to-finished:
  294.546 seconds. The status API's `elapsedSeconds` continues increasing after
  the candidate is ready, so it must not be used as a finished preparation
  duration.
- At inspection: `ready`, request `done`, no pending activation and no compiler
  processes remaining. The update had not been installed.

### Actual work and resource use

The private transaction log recorded **101 planned derivation builds** and
**114 planned fetched paths**, **189.6 MiB compressed / 578.3 MiB unpacked**.
These counts include configuration generation, source fetching and packaging;
they are not 101 application compilations. Builds actually logged include
hyprutils, Aquamarine, hyprgraphics, hyprlang, hyprcursor, Hyprland, the native
titlebar plugin, desktop/updater packages and the portal.

The worker journal reports 1h17m17.605s aggregate CPU time over 4m54.519s wall
time, 14.6G peak memory, 1.4G disk reads, 19.9G disk writes and 240.9M incoming IP
traffic. Those are systemd's reported accounting units, not additional measured
download sizes. The machine had about 57 GiB RAM available, no swap use and
848 GiB free disk at inspection; this snapshot does not reconstruct resource
pressure during the completed build.

The machine configures only `https://cache.nixos.org/`, `max-jobs = 24`, and
`cores = 0` (all available cores per build). The actual C++ build logs show
`-j24`. A low single-thread build setting is not the explanation. No timeout,
retry or download-error markers appeared in the 41,798-byte transaction log.

### Timing reconstruction

Nix's compressed derivation logs expose filesystem birth and last-modification
timestamps. These bound their logged activity with approximately one-second
precision, rather than providing instrumented phase durations. Files were
created during this transaction. The following intervals overlap where builds
ran concurrently and must not be summed:

| Build log | Birth → last write, local time | Approximate interval |
| --- | --- | ---: |
| hyprutils 0.14.0 | 19:20:47 → 19:20:55 | 8 s |
| Aquamarine 0.11.0 | 19:20:55 → 19:21:21 | 26 s |
| hyprgraphics 0.5.1 | 19:20:55 → 19:21:14 | 19 s |
| hyprlang 0.6.8 | 19:20:55 → 19:21:16 | 21 s |
| hyprcursor 0.1.13 | 19:21:16 → 19:21:32 | 16 s |
| **Hyprland 0.56.2** | **19:21:32 → 19:24:56** | **204 s** |
| CybexOS desktop | 19:24:56 → 19:25:04 | 8 s |
| CybexOS titlebars | 19:24:56 → 19:25:10 | 14 s |
| CybexOS updater | 19:25:04 → 19:25:05 | 1 s |

Candidate lock publication was at +7.023 seconds and candidate input archive
publication at +7.398 seconds. The previous-input archive was published at
+292.791 seconds, and the final review/deployment at +294.384 seconds. Thus
about 61 seconds precede the main Hyprland build log, 204 seconds fall inside
it, and 29 seconds follow it. Downloads and early library builds overlap;
their individual contributions cannot be separated from these records.

### Why an unchanged Hyprland version was rebuilt

The reviewed version changes were GitHub CLI 2.102.0 → 2.103.2 and yt-dlp
2026.08.19 → 2026.10.21. Hyprland remained 0.56.2 but changed output identity:
`7bwsvyawzq3bqpdch06vw7rdgwa1sgmf` →
`b4bvlj4a58ihzalv4wvy6lpm30pnpgmn`.

The installed original Hyprland has `unknown-deriver` locally, so its exact
original derivation was read from the Beast's existing Nix store. Its output
identity matches the installed original exactly. This avoided evaluating or
building anything on the workstation. Comparing its environment with the new
machine derivation shows one changed direct build input: the customized
Aquamarine development output. The hyprutils/hyprlang/hyprgraphics/hyprcursor
development output identities are unchanged.

Comparing the original and candidate Aquamarine derivations identifies the
change: Nixpkgs added
`ff9b933d5559ca88289f8d2521dda39640b5aaab.patch`. That patch changes the DRM
backend. It changes Aquamarine's build identity and consequently Hyprland's,
its plugin's and dependent desktop packages' identities. This is normal Nix
dependency invalidation; removing the patch or hardware support to suppress
the rebuild would be the wrong fix.

The original runtime library outputs are still present in the current system's
closure, but the transaction also built the unchanged customized library
derivations needed as development inputs. The logs and identical required
development output identities are consistent with missing build outputs after
fresh installation: having runtime libraries does not supply their headers and
other build outputs. No before-update inventory of those development outputs
was captured, so their prior absence is inferred rather than directly observed.
The prebuilt-cache work must include required development outputs, not only
runtime outputs.

## Inspection limits and cleanup

This is one completed real upstream preparation, inspected after it finished.
No before/after optimization benchmark or apply/reboot/confirmation test was
performed. No speedup is claimed. The machine's existing transaction and Nix
build logs remain in their original locations for its operator; none were
deleted or copied into the repository. The report contains selected findings,
not credentials, raw personal configuration or a review token.

The authenticated SSH shell/control connection was closed after inspection.
The task-local known-hosts file and its temporary directory were removed;
there are no retained task processes or diagnostic files outside this report.
