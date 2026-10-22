# Rename to NerdOS

NerdOS is the Opinionated System at **nerdos.org**, formerly CybexOS.
This work targets fresh NixOS 26.05 installations. The Fedora/RPM/Ansible
bridge-release and installed-system migration instructions in the supplied
older rename kit do not apply to this repository's lifecycle contract.

## Implementation plan

Baseline: commit `0cf9be2`, clean `main`; implementation branch `rename/nerdos`.
The regenerated inventory has 2,260 old-name occurrences in text, compared with
the kit's 6,250-reference Fedora-era snapshot at `4f31668`. The current tree
uses NixOS modules, systemd-boot/Lanzaboote and Ed25519 release metadata.

1. Rename the NixOS module/input namespace, lifecycle Python package, CLI,
   installer, system/user units, desktop helpers, state paths and fixtures in
   reviewed groups. Preserve machine-owned inputs and personal ownership rules.
2. Rename Quickshell/native module identifiers, themes, widgets, translations,
   browser demo, documentation and the bundled skill. Preserve external source
   names and historical attribution; no command aliases or installation shims.
3. Import the supplied brand masters unchanged. Integrate the glasses, icons,
   fastfetch and favicons; package/select Plymouth through the shared NixOS
   module, including initrd assets and LUKS unlock. Keep theme colours unchanged
   outside brand surfaces.
4. Update release identity and infrastructure instructions without publishing,
   changing owner settings or touching signing material. Check source/ISO
   contract parity, staged lifecycle, authenticated delivery, web and leftovers.

## Result and scope

- Product spelling is **NerdOS**, machine/module/input namespace `nerdos`,
  uppercase/environment prefix `NERDOS_`, and user command `nerd`.
  `OS` means **Opinionated System**. Helpers use `nerdos-*`.
- Nix modules, installer, lifecycle Python package, services, policy/PAM names,
  disk labels, GC roots, personal skill discovery, default theme and state
  paths use the new namespace. `quickshell.service`, native upstream services,
  NixOS `ID=nixos`, the stable branch and `system.stateVersion` are preserved.
- The supplied package lives in `assets/brand/`. Deployment copies, their
  original SHA-256 identities and font notices are included. Both menubar
  icons, native application icons, README, web welcome/lock/about screens,
  favicons, ASCII output and terminal installer use the new identity.
- The shared NixOS module packages/selects the `nerdos` Plymouth script theme,
  allowing NixOS to include its script/images/plugins in the initrd. The script
  retains its display-geometry recentering and password handling; positioning
  uses the new logo's measured dimensions. The ISO gets a GRUB theme and an
  ISOLINUX background made from the unchanged supplied Plymouth logo.
- Brand red becomes lime, with charcoal text/icons on lime controls. The
  wallpaper-derived desktop palette and all fastfetch modules are preserved.
- Source archives, ISO names, release tooling, CI, documentation and issue
  links use NerdOS. Ed25519 authentication, immutable exact revision/NAR
  selection, replay/downgrade rejection and the staged update lifecycle remain.

There is no Fedora/RPM/DNF/Ansible packaging or Cockpit/new-owner/welcome QML
application in the current tree. Those surfaces are retired, so they were not
reintroduced. The existing NixOS terminal installer is the fresh-install UI.
The native NerdOS launcher opens the existing desktop settings through the
runtime's IPC helper. The browser welcome remains an interactive demo.

## Fresh-install policy

The former Fedora bridge release, RPM Obsoletes/Provides, firewalld-zone
migration, old-name environment fallbacks, unit aliases and deprecated `cybex`
forwarder are deliberately omitted under the current `AGENTS.md` contract.
There is no supported one-line in-place conversion from an older CybexOS
installation. Back up personal data and perform a fresh qualified NixOS
installation. Do not run a rename script over existing personal configuration.

Normal future NerdOS updates continue to preserve `/etc/nixos`, its unrelated
inputs, personal packages/services/VPNs, widget code and preferences, skills and
persistent data. Installer seeding remains absent-only; updates never repair a
build by deleting personal content.

## Maintainer runbook

These are **John's actions**. No external setting, key, release, tag, running
workstation or PXE image is changed by this branch.

1. Review the **NerdOS trademark** and project-artwork licensing. Set the
   product website/description to **nerdos.org** when ready.
2. Rename the existing GitHub repository to **DigitalPals/NerdOS** before the
   first authenticated NerdOS NixOS release. Preserve GitHub's existing
   redirects; do not create a replacement repository under the old name.
   Review external links and integrations independently. The code's production
   identity is the exact new repository; development source paths continue to
   work locally before this infrastructure step.
3. Relabel isolated CI runners **nerdos-isolated**, and provision protected
   environments **nerdos-release** and **nerdos-channel** with the existing
   publisher isolation/review rules. Secrets retain their unbranded names:
   `RELEASE_ED25519_PRIVATE_KEY`, `CHANNEL_ED25519_PRIVATE_KEY`, and the
   `IMMUTABILITY_CHECK_TOKEN`; variables retain `RELEASE_KEY_ID` and
   `CHANNEL_KEY_ID`. Check the workflows and [release guide](releasing.md)
   before setting permissions. Do not expose these secrets to untrusted PRs.
4. Production trust is still empty. Supply owner-controlled public Ed25519
   keys, validity dates and purposes in `release/keys/trust.json` through the
   reviewed first-release process. This rename does not generate, rotate,
   relabel or replace signing keys. No RPM/GPG key or package repository exists
   in the supported product.
5. Configure the repository's Pages channel publication so the updater can
   reach `https://digitalpals.github.io/NerdOS/channels/{beta,stable}.json`
   and detached `.sig` documents. The channel base is derived centrally from
   `REPO` in `lifecycle/nerdos/trust.py`. GitHub Pages project URLs do not follow
   repository redirects. There is no old-channel fallback or old installed
   population to bridge in this unreleased, fresh-install NixOS product.
   A future custom channel domain requires explicit source/host-allowlist and
   authenticated-delivery review; setting a website CNAME alone is insufficient.
6. Qualify the **same final source revision and NAR** used for release artifacts:
   source checks, both fresh ISO installations, password/LUKS login, real staged
   upstream/vendor/combined/local update and recovery, personal persistence,
   plugins, hardware and security. Preserve the existing blockers in
   [validation status](validation.md), including Secure Boot installation.
   Never treat this rename's build/fixture results as physical qualification.
7. After those gates pass, follow `docs/releasing.md`: create a new semantic
   tag, publish an immutable signed release with its complete qualification
   report, verify public assets, then promote a signed channel with a strictly
   increasing sequence. Do not edit historical tags or published release assets.

There is no Fedora package-domain switch, bridge release, compatibility expiry
release or tested straggler command for this fresh-install architecture.

## Status

Implementation and development verification are complete on local branch
`rename/nerdos`. Nothing has been pushed or published.

Topic commits:

- `8bd21d3`: record the current NixOS scope and reviewed rename batches.
- `9fb8d7f`: import the supplied masters, deployment artwork and licensing.
- `e08cd56`: browser identity, supplied marks, fastfetch, favicons and accents.
- `8e2c873`: NixOS namespaces, lifecycle, installer, desktop, release tooling,
  tests and CI, including Plymouth packaging and staged-update coverage.
- `cb8b2e2`: README, contributor/agent guidance and NixOS operating documentation.
- `ab1506d`: supervise the real Plymouth daemon and verify masked keyboard input
  and its password callback.

These are development checks. No release artifacts or physical qualification
report were produced. The owner must repeat the release gates on one final
committed source revision and NAR identity before publishing.

### Baseline and final checks

The baseline is `0cf9be2`. Baseline host `tests/run` reached 420 Python tests
with one failure, one error and 15 skips; the failures were fingerprint D-Bus
enrolment tests. Supplementary host checks also lacked WebSockets and Lua.
The **entire baseline `nix develop -c tests/run` passed** in a disposable
rootless Nix container, including 420 Python tests, 1,360 Node tests (1,341
passes and 19 environment/optional skips), native helpers, plugin/theme suites
and Model Usage. The final renamed source suite passed with 424 Python tests
(including four new artwork tests) and the same 1,360 Node tests, 1,341 passes
and 19 optional/environment skips. The remaining helper/plugin/theme/Model
Usage groups also passed.

Baseline browser CI passed: 10 files / 116 tests, lint, TypeScript, production
build and production render/asset checks. Baseline `nix flake check --no-build`
also passed. The isolated environment uses the existing locked Nixpkgs and Nix
2.35.3; no host Nix installation or workstation activation is involved.

| Check actually run | Baseline | Final |
| --- | --- | --- |
| `nix flake check --no-build` | Passed | Passed |
| `nix develop -c tests/run` | Passed in Nix environment | Passed; 424 primary Python tests |
| Browser: `npm run lint`, `npm run typecheck`, `npm test`, `npm run build`, `npm run test:render` | All passed | All passed; 116 component tests and 2 production checks |
| `nix develop -c tests/qml-lint` | Not separately run | Passed: 355 files, 4 harnesses, no errors; 8 warnings |
| `nix build .#plymouth .#checks.x86_64-linux.lifecycle .#checks.x86_64-linux.parity --no-link -L` | Not separately run | Passed; shared live/installed module contract includes boot branding |
| `nix build .#checks.x86_64-linux.vm --no-link -L` | Not separately run | Passed; combined boot, graphical Plymouth/password callback and actual local staging, 321 seconds under software emulation |
| `nix develop -c python3 -B tests/nixos-native` | Not separately run | Passed: real lock/prefetch, unrelated-input preservation, isolated HTTPS/ETags, signature rejection, unavailable channel and installation-source transfer |
| `nix develop -c python3 -B tests/user-plugins.py` | Storage/portable coverage in source suite | Passed with actual isolated Quickshell/Sway: N, N+1, rollback and all six supported Omarchy kinds |
| Bundled skill `quick_validate.py agent-skills/nerdos` | Not separately run | Passed |
| Supplied artwork hash/PNG/SVG/contrast checks | Absent | Four regression tests passed |

The VM exercises the packaged `nerd` command, NerdOS paths/PAM/skill/icon and
fastfetch discovery, personal initialization, real compositor configuration
validation, the supervised local stage/archive/build/checker/closure-diff path,
and unchanged hashes for the machine flake, lock and personal sentinel. A local
stage reached `ready` with its NerdOS input identity and review token. The
Plymouth fixture uses a supervised unit, ignores the VM's serial console to
select the graphical theme, and uses an absolute password-callback executable
because Plymouth sanitizes its environment. An initial direct daemon launch
held the driver's shell open. An earlier fixture also used an absolute module
path rejected by pure evaluation; it now uses the machine's `local/` module.
These initial fixture issues are distinct from a product update or installation.

The combined boot/staging VM used development source NAR
`sha256-gwTFPpjTxp5P1XGdIE7+iNepKMDbmSoGVdoR9OUviME=`. The code matches the
implementation/test commits above; the final handoff commit adds this report
and review images. This working-tree run does not qualify an authenticated
release revision.

**Not exercised in this task:** a fresh ISO installation, actual LUKS disk
unlock, update application/reboot/confirmation/rollback on the renamed source,
upstream/vendor/combined installed update paths, final full proprietary-app/XPS
closure builds, physical 1×/2× displays, Secure Boot, camera/NVIDIA or other
hardware qualification. No ISO was built and no workstation service was changed.
The existing installation/hardware qualification tools and release blockers
remain in place. The signing trust store remains empty.

### Fresh-install and ownership coverage

| Contract | Evidence |
| --- | --- |
| Old installations are not converted | Current installer is live-only and fresh-only; VM rejects invocation on the installed profile; no migration/forwarder/unit aliases were added |
| ISO and installed profiles select the same product | `nix/tests/parity.nix` evaluates the public module contract, including boot theme/package/logo/label, services, PAM, firewall, fonts and hardware declarations |
| Saved personal choices and unrelated inputs remain machine-owned | Existing lifecycle/configuration/personal-init tests; real native lock-delta checks; local-stage VM hashes |
| User widgets, skills and data remain outside vendor replacement | Existing source tests plus actual N/N+1/rollback Quickshell plugin tests and absent-only personal initialization |
| Release authentication stays strict | Existing signature/source-NAR/replay/downgrade and owner/URL rejection regressions, real isolated native transport tests |
| Boot artwork reaches initrd and runtime | Built Plymouth package; shared NixOS selection; installed VM theme/asset discovery and splash/password UI checks |

### Leftovers

`scripts/check_leftovers.py` is the supplied checker, with its default pointing
at [`scripts/rename-leftovers-allowlist.txt`](../scripts/rename-leftovers-allowlist.txt). CI runs it. The inventory tool is
retained as `scripts/rename-inventory.py`.

Every allowlist rule is confined to a named file and reason: README name history;
this runbook; the verbatim supplied usage guide; the original wallpaper creator,
generator and its recorded digest; two historical camera-patch author lines;
three pinned Model Usage design-reference attribution lines; and the checker,
inventory and allowlist's own retired-name patterns. There are no broad runtime,
workflow, migration, package or old-repository exceptions.

Final scanner command (also checked with `--untracked`):

```console
python3 scripts/check_leftovers.py --repo . --allowlist scripts/rename-leftovers-allowlist.txt
OK: no unexpected 'cybex' references (62 allowlisted).
```

Case-insensitive searches for the four retired brand-red hex values and the
retired wordmark filename found only the inventory tool's detection patterns;
no product references remain. The provenance manifest,
original wallpaper generator and pinned Model Usage notice are byte-identical
to baseline. `git diff --check` passes.

### Review artifacts

Artwork masters and required deployment assets are product source. Retained
review images live in [rename-artifacts/](rename-artifacts/):

| File | Bytes | Exercised surface |
| --- | ---: | --- |
| `web-welcome.png` | 132578 | Production browser welcome, outlined logo and charcoal/lime controls |
| `web-fastfetch.png` | 72170 | Production browser ASCII, lime tape, unchanged system-detail modules |
| `web-control-center.png` | 97757 | Glasses button and NixOS 26.05 base identity |
| `web-about.png` | 111598 | Supplied outlined logo in browser settings |
| `web-lock.png` | 131929 | Browser lock screen and supplied identity |
| `menubar-1x.png` | 2030 | Actual Qt/Quickshell component, 320×160 pixels at `QT_SCALE_FACTOR=1` |
| `menubar-2x.png` | 4527 | Actual Qt/Quickshell component, 640×320 pixels at `QT_SCALE_FACTOR=2` |
| `grub-menu.png` | 11416 | Actual packaged theme in standalone GRUB 2.12 UEFI at 1024×768, with fixture menu entries |
| `plymouth-splash.png` | 5502 | Packaged NerdOS script rendered by Plymouth in the booted VM |
| `plymouth-unlock.png` | 6083 | Actual password field below the supplied logo |
| `plymouth-password.png` | 6168 | Masked input before submission; callback returned the fixed test password |

The native renders show canonical, resting and hovered marks left to right.
They use the actual `Theme.barIconSize` (15 logical pixels at default type
scale), isolated headless Sway with Mesa software OpenGL and the actual
`BrandIcon`/`BarBrandIcon` components. Qt's basic software scenegraph cannot
render the tint effect; the retained renders use its working RHI/OpenGL path.
They are component checks, not a physical display/session qualification.
The Plymouth images are 1280×800 software-emulated VM screenshots. Its real
password callback passed; no encrypted block device was opened by this UI test.
Browser captures use a 1280×800 viewport. The boot-menu background is retained
as product source at `desktop/boot/splash.png`. The GRUB capture boots a small
disposable FAT/UEFI VM with the built ISO theme, supplied logo and packaged
font; it does not boot an ISO or exercise installation. The generated ISO
menu entries, ISOLINUX menu and terminal installer were not visually exercised.
Retired Cockpit/new-owner/QML welcome surfaces have no render because they do not
exist in the current tree.

Cleanup is complete. The task's rootless validation container and downloaded
Nix image were removed, including their Nix store and VM disks. The task staging
directory, temporary logs, render processes, preview server and browser tab,
dependency installation and generated browser outputs were removed. Checks
confirmed no task processes or mounts remain and no generated ignored outputs
remain in the checkout. Existing unrelated outputs and container images were
preserved. No ISO was built or left on PXE. The 11 review images listed above
are the only retained test artifacts: **581,758 bytes** in
`docs/rename-artifacts/`, retained for review of the requested brand surfaces.
