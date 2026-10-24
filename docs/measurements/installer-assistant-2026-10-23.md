# Installer details, timezone selection and assistant setup

The reported live installer was switched off before its root-only log could
be collected. The photograph establishes `nixos-install` exit 1, without its
underlying cause. This work fixes access to diagnostics and the reported UI
problems; it does not identify or claim to fix that installation failure.

## Source and scope

The frozen development source is
`sha256-C2OV1dIgRHI47UaVIaIIt17ClWAGHK7f0fZABkVMkqM=`
(`/nix/store/iyzzhrv19cf5lbwvwd3jkqkkpnp4z580-source`). It includes the
pre-existing checkout changes. This evidence record was written afterward.
Tests ran on the Beast in isolated offscreen Qt, headless Sway and disposable
NixOS VM environments. No workstation was deployed or rebooted. No ISO was
built or changed, and the served PXE image list was left alone.

## Behavior and checks

- Installation details now stay in a selectable, scrollable dialog, with
  explicit read errors and automatic refresh. A separate live-only read of
  the fixed root log works while installation owns its operation lock and
  after its worker exits. Output is bounded to the most recent 256 KiB and
  rendered as plain text. The full log stays root-only.
- Region settings offer a searchable timezone selection. GeoIP uses HTTPS
  through ipapi.co, times out, and leaves manual or reviewed choices alone.
  Language and keyboard choices remain independent. The actual Qt network
  client successfully detected `Europe/Amsterdam` from the build host.
- Dragging uses coordinates on a stationary surface, independent of the
  character's translation, scale and rotation. The actual Quickshell engine
  under isolated headless Sway passed three repeated drags with real
  wlr-virtual-pointer motion/button input, checking the full saved distance.
- Assistant setup checks `claude auth status` / `codex login status` before
  sending a prompt. Its own sign-in action launches the provider's native
  login in the selected terminal, detects completion and preserves the draft.
  Status probes discard their output; credentials stay with the provider.
  The real QML/service integration passed against a scripted agent and a
  capture terminal, including automatic sign-in detection, approvals, Undo
  and widget creation. No real provider account or model was used.
- The native installer QML/controller test passed timezone filtering,
  successful/unavailable/late GeoIP responses, manual override, review
  preservation, failed diagnostics reads, recovery on refresh, persistent
  plain-text details, account validation and the installation close guard.
- QML lint passed 376 product files and four harnesses with the existing
  type/property warnings. The installer package built and its actual wrapper
  loaded under an empty environment. Shared ISO/installed-system contract
  evaluation/build passed; this is source parity, without a completed ISO.

## Source regression suite

`tests/run` passed on a writable copy with the same source NAR: 515 Python
discovery tests, the additional helper suites (21, 5 and 23 tests), and 1,360
JavaScript tests passed (1,377 total, 17 skipped, no failures). The remaining
standalone runtime, plugin, theme and model-usage helper checks also passed.
Password checks used the `NERDOS_LIBCRYPT` exported by this source's pinned
lifecycle derivation; an initial run without that dependency was corrected
before the complete passing run. Python parsing, catalogue validation and
`git diff --check` also passed.

## Booted staged updater

The sandboxed `checks.x86_64-linux.vm` run booted and reached the actual
supervised software staging path. It failed because the offline guest could
not resolve/fetch missing build inputs, including Python, Binutils and Bash.
The updater reported “Staging failed; working system retained”. This sandbox
check did not pass.

The online follow-up **passed in 114.39 seconds**, running the same driver and
complete original test script with temporary DHCP on the disposable guest's
NAT interface. QEMU used `-no-user-config` because the host's private
`/etc/qemu` directory blocked the first online attempt before boot. No
candidate, updater, assertion or test-script substitution was used.

The real supervised software preview reached `ready` with `hello` present in
the candidate. The subsequent maintenance preview reached `ready` with its
new policy in the candidate while the running policy stayed unchanged. The
test checked machine-owned configuration hashes, identical locks, preserved
personal content, a review token and the pinned NerdOS input. Recovery,
desktop verification and the packaged Plymouth password callback also
passed. This exercised staging and review; it did not apply a deployment.

- Driver: `/nix/store/iwzz56gagz5mvs9rl222pfwaigj7l7mx-nixos-test-driver-nerdos-lifecycle`
- Original test script SHA-256:
  `672340514b190230bf4afdded1ce95d4f4254d96230b930d9a50b14d3e4684b4`
- The runner checked the loaded test bytes and unchanged original script.
  The writable source still hashed to the frozen NAR after the tests. The
  final checkout comparison differed only by this evidence record.

## Boundaries and cleanup

The physical installation failure, physical/multiple-display dragging and
real Claude/Codex browser/account authentication still require testing.
Source fixtures, offscreen rendering and a package build do not qualify a
fresh physical installation, hardware, Secure Boot or an applied update.

Cleanup removed the Beast staging directory
`/tmp/nerdos-installer-assistant-0jeWZU` (341 MiB) and local staging directory
`/tmp/nerdos-installer-assistant-1x9jGa` (16 MiB), including source copies,
logs, screenshots and the VM disk. Checks found no remaining task processes
or mounts and confirmed both directories absent. No user Quickshell process
remained on the headless test host. Neither host had a
`~/.local/share/nerdos/images` directory. No disposable test artifacts are
retained. Shared Nix dependencies remain cached; no existing ISO or other
task's artifacts were removed.
