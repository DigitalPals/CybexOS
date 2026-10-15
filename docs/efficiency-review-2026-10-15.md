# Efficiency review and implementation — 15 October 2026

The audit compared the working implementation with source revision
`5ce58a3ec8cfa75164f60923d640bfae5cc7227c`. Claude Fable 5.1 was asked to
verify the findings at Max effort. It confirmed the principal mechanisms,
qualified their scope, and identified the default Rust documentation as an
additional large seed cost. This independent review covered the findings;
the implementation was subsequently tested and measured as described below.

Raw observations, workloads and caveats are in
[the measurement record](measurements/efficiency-2026-10-15.json).

## Measured changes

Paired artifact measurements use the first optimized build. The final build
after installation-parity corrections is identified below and in the JSON
record; runtime and component workloads are unchanged.

| Area | Before | After | Scope |
| --- | --- | --- | --- |
| Production web Docker image | 803,746,314 B | 104,205,923 B | 87.0% smaller uncompressed image layers; standalone runtime includes its traced dependencies. |
| Web runtime `node_modules` | 498,699 KiB | 20,144 KiB | Development compiler and Cloudflare tooling stay in the build stage. |
| Browser wallpaper | 1,838,747 B | 90,336 / 250,438 / 678,532 B | 1280 / 2560 / 5120 pixel WebPs. The tested 2× browser fetched 250,438 B, 86.4% less. |
| Unrelated window renders during 20 clock ticks | 20 | 0 | Paired React test; the displayed clock crossed a minute. This measures render work, not browser CPU. |
| Quiet Sound page, four seconds after settling | 40 `pactl` probes | 0 | Real PipeWire-Pulse and QML. The 15-second safety poll remains; a real volume change still generated one five-probe snapshot. |
| Two-output widget RSS, median of three runs | 97,222,656 B | 80,986,112 B | About 15.5 MiB less in the isolated widget workload, before first popup use. |
| Two-output widget construction, median | 462 ms | 406 ms | About 12% faster. Headless Sway, software rendering and fake quota responses; not whole desktop login time. |
| Forced Wayfreeze rebuild, median of three runs | 129.39 s | 2.76 s | About 47× faster with a warm compiler/Cargo cache. Includes variable network time in the baseline. |
| Seven native JPEG wallpapers | 28,282,513 B | 27,936,923 B | 345,590 B saved through lossless optimization; decoded pixels, dimensions and filenames preserved. |
| Complete xz ISO | 8,071,483,392 B | 7,996,391,424 B | 75,091,968 B (0.93%) smaller. Every upstream RPM identity and Flatpak deployment matches between builds. |
| Build source archive | 33,331,560 B | 32,277,823 B | 1,053,737 B (3.16%) smaller; each archive records its exact source snapshot. |

The initial cached builder image took 84.73 seconds to provision in a separate
run; an unchanged application then returned in 4.4 ms without network access.
These are different paths from a forced rebuild. Network variation prevents a
reliable claim that the first ever build became faster.

All nine original findings and the additional Rust documentation finding are
addressed below. The browser container now uses the traced standalone Node
runtime; the Worker build remains available. The clock update is isolated and
aligned to minutes, while the open usage panel retains second-level updates.

## Native runtime

Sound subscriptions now accept card, sink, source, stream and server events,
and ignore client/module churn caused by the read-only probes themselves.
`LC_ALL=C` makes the filter independent of the desktop language. The measured
loop occurred only while the Sound settings page was open.

Model Usage quota and legacy activity workers are shared by connection,
credentials, provider selection and refresh policy. Reference counts retain
workers across removal of the first output, and awake consumers control
polling. Manual refresh remains available while automatic work is paused.
Local loopback proxies remain usable without external network connectivity.
The existing shared Rust live stream is retained. A single-output system does
not gain from deduplicating output subscriptions.
The actual Quickshell engine fixture starts two matching consumers and records
one quota child and one legacy-activity child for their initial fetch. Removing
the awake consumer pauses automatic work; one manual refresh adds one child
of each kind, and changing credentials starts one new child of each kind.
These are controlled helper-invocation counts, not external API traffic.

The popup's forms and delegates are constructed on first use and retained
after closing. The headless Wayland test checks synchronous settings creation,
keyboard focus, retained nonsecret drafts, and switching between limits, costs
and their settings. The memory gain concerns QML objects and bindings; it is
not a claim about GPU surfaces. The vendored integration is recorded as a
reviewed patch, checked before an upstream sync can replace the current copy.

Plugin discovery keeps its registry watcher and immediate refresh on relevant
page changes. Its two-second package scan now applies only to Bar and Plugins;
unrelated Settings pages use the existing five-minute interval. A real helper
benchmark with Appearance open measured five scans in ten settled seconds
before the change and zero afterward (one initial scan was retained).

## Application payload and update downloads

New Rust installations use the minimal profile with explicit rustfmt, Clippy
and rust-analyzer. Existing user components are preserved. The pinned
`nightly-2026-08-23` documentation contains 739,153,743 bytes in 65,926
files. Copying that tree with the existing seed function took 8.58 seconds on
the host's ZFS storage. That is a component benchmark, not installed Btrfs
first-login timing. Offline docs can be added with `rustup component add
rust-docs --toolchain nightly-2026-08-23`.

The baseline application seed alone contained 3,586,210,627 bytes across
85,475 files; the rebuilt seed contains 2,847,058,243 bytes in 19,548 files,
a 20.6% byte reduction and 77.1% fewer files. Application stores and system
fonts are additional to these figures. Its `.rustup` directory
accounted for 1,428,749,636 bytes. The ISO also duplicated 6,468,676 bytes of
pinned fonts in 20 additional files. Packaging now verifies the canonical
prepared fonts and copies only the required notices to the license directory.
Missing or corrupt prepared fonts fail packaging.

The desktop and large offline application seed now have separate RPMs. The
seed's independent version and reviewed input digest prevent shell-only
releases from forcing an application download. The desktop requires that
exact input identity. Spec ownership, signing, repository publication, SPDX
artifact bindings and offline upgrade qualification account for both RPMs.
The actual desktop RPM fell from 1,739,588,415 to 29,824,379 bytes; the
companion is 1,641,343,352 bytes. Together they are 68,420,684 bytes (3.9%)
smaller than the original monolith. A shell update that reuses the companion
needs a 98.3% smaller desktop download. The seed remains in a fresh ISO.
An actual RPM transaction from the monolith to both packages verified all
65,548 regular-file/symlink payload paths with zero duplicate regular-file
owners and a clean RPM verification. That private-root transaction excluded
scriptlets; it is not a boot or installation qualification.

Published offline RPM identities must remain
immutable: the signing workflow authenticates the previous channel manifest
and rejects changed payload contents or ownership under the same identity.
Reuse an existing artifact or advance its version when moving upstream inputs
change. See [the release policy](releasing.md).

Source builds provision a reusable compiler image per pinned base and build
recipe, mount a shared Cargo registry and separate locked target directories,
and copy only the requested executables. Cache data lives outside installed
application stores. The transactional update and healthy offline skip paths
are retained.

## Compression choice

A new `image/benchmark-compression` tool compares identical input hashes,
verifies extracted contents, alternates codecs across repeated runs, and
removes its temporary images. On the 4,457,839,657-byte baseline RPM payload
with 131,381 files and eight processors, one paired run measured:

| SquashFS codec | Image bytes | Compression | Extraction |
| --- | --- | --- | --- |
| xz | 1,496,461,312 | 55.48 s | 6.55 s |
| zstd | 1,571,086,336 | 33.24 s | 4.86 s |

Zstd was faster and 5.0% larger on this workload. A separate two-run Rust-docs
comparison was 2.9% larger without a consistent extraction advantage. These
measurements do not establish boot or installation time for the full ISO.
The qualified xz default remains, and the existing zstd build option remains
available. Binary stripping stays disabled because the payload contains
upstream binaries whose verified bytes must be retained.

The review also checked the Android SDK selection and native timer guards.
The SDK already installs only platform-tools, the selected platform and
build-tools. The native timers examined already stop when their work or view
is inactive. No pruning or timer removal was justified for either item.

## Validation and deployment

The full source contract passes: 1,369 unit tests, QML lint and actual engine
lifecycle checks, 43 Python isolation/policy fixtures, installer convergence,
updater, snapshot and migration checks. Image checks pass 27 primary tests,
518 Python tests (two environment-specific skips) and 14 installer JavaScript
tests. The web passes lint, TypeScript, 116 component tests and two production
Worker/asset tests. Its Compose service was rebuilt/restarted on `thebeast`
and is healthy; desktop/mobile browser checks passed.

Real qualification exposed checkout defaults that differed from the ISO.
Checkout now reads the ISO package selections, groups, exclusions and desktop
runtime requirements after shared repository setup. Prerequisite commands,
upstream RPM installation and Ansible disable weak dependencies. Both paths
use the complete locale and firmware baseline. Checkout prepares the shared
codec repositories and selects the ISO providers before base/desktop package
transactions, avoiding nine dependencies left by replacing interim codecs. It
also selects the ISO's `ocl-icd` OpenCL dispatch library in that transaction.
Shared policy selects graphical boot without interrupting the running session;
the test asserts that result.
Saved choices and user-owned data remain protected.

The final ISO passed a complete plain-US graphical installation with outbound
networking blocked, boot without the ISO, application/toolchain checks,
password login and sudo, enforcing SELinux and managed Settings lifecycle
checks. Offline reconfiguration preserved explicit saved choices and personal
settings. A separate actual public checkout installation used the exact
archived source on disposable Fedora Cloud, rebooted into SDDM and repeated
the lifecycle/reconfiguration checks. The delivered source archive records
the installed product snapshot; subsequent changes are limited to documentation
and qualification comparison tooling. Fresh and saved installed outcomes pass
the strict same-source comparison, including package versions, effective user
unit activation, boot target, authentication and firewall policy.

Cloud fixture preparation updates only its owned OS baseline, removes named
preexisting Cloud packages, selects the current generic Fedora identity and
boots the current kernel before installation.
The public installer does not prune user package inventories or old kernels.
Only the UTC spelling alias and equivalent session-target activation are
normalized; masks, missing units and inactive services remain differences.
The signed Brave keyring's background importer adds three prerelease keys on
running Fedora. The initial ISO chroot lacks `timeout` during that transaction;
both paths retain the identical keyring package and pinned stable repository.
Those three exact fingerprint/release identities are documented exceptions;
unknown keys and family-wide key exceptions fail. No trust records were deleted.
Every allowed package difference retains an explicit reason. See
[the installation contract](installation-parity.md).

A new encrypted-US installation from the supported October 14 ISO passed,
followed by installation of these exact final split RPMs, reboot and recovery
boot/restore. It also verified the unused disk, encrypted Btrfs, login policy,
desktop parity, selected regional settings and live-system cleanup. These are
actual QEMU installations, not fixture-only evidence. Physical hardware,
Secure Boot and the full public-release matrix are outside these runs.

Final build: `20261015T183818Z-25fb4f79`. Its ISO is `7,996,391,424` bytes;
the desktop RPM is `29,830,738` bytes and the offline companion
is `1,641,308,348` bytes. All artifact checksums and the SPDX ISO/RPM
bindings pass. The assembled payload also passed an exact credential-byte audit.

The ISO is served at `/data/pxe/iso/CybexOS-Live-44-20261015T183818Z-25fb4f79.iso`.
The complete artifact bundle is `/data/cybexos-efficiency-20261015-yCv5AF/optimized-build-qualified-r6/artifacts`
(10,057,712,493 logical bytes), retained with compact qualification
reports for review. iVentoy refresh, image-list, running PXE status and service
checks passed. The JSON record contains final hashes and qualification reports.

Disposable builds, test VMs, download/compiler caches, temporary logs and the
test container image were removed. The final ISO shares storage with the
retained artifact bundle. Preexisting PXE images were preserved, and the final
iVentoy refresh/list/service checks passed. No task-owned processes or mounts
remain. Compact cleanup and service checks are retained with the evidence.
