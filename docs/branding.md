# Cybex OS branding

The NerdOS rename is reverted. Interface text says **Cybex OS**. Repository,
NixOS module/input, Python package, service, path and protocol identifiers use
`cybexos`; the environment prefix is `CYBEXOS_` and the user command is `cybex`.
The upstream repository and authenticated channel identity are restored to
`DigitalPals/CybexOS`. No external repository settings, signing keys, channels
or published releases are changed by this source update.

The owner-supplied `cybex_white.svg` is preserved byte-for-byte under
`assets/brand/source/`. Deployment variants use its outlined wordmark with
the original red `#DC1E37`; small icons use the two X paths from that same
drawing. The installer, desktop, assistant, fastfetch, browser demo,
application icons and favicons share these assets. `scripts/export-brand.py`
regenerates them and their SHA-256 manifest using Pillow and librsvg from the
locked Nixpkgs.

Plymouth is packaged and selected by the shared NixOS installation module for
the ISO and installed system. Its wordmark is 189×44 (378×88 at double
density), approximately 66% of the 286-pixel password field width and retaining
the source aspect ratio. Password masking, callback, display recentering and boot
progress behavior are preserved. The GRUB and ISOLINUX artwork uses the same
wordmark; the menu layout accommodates its height. Progress and selected items
are blue.

The graphical and terminal installers, timezone map, password dialog and
brand controls use blue with charcoal text. New desktop preferences, the
Cybex OS theme, terminal fallback, window borders and lock screen default to
blue. Existing personal preferences and selectable wallpaper palettes remain
user owned; this source update never rewrites them.

This targets fresh installations under the repository lifecycle contract.
There are no old-name aliases or in-place conversion scripts. The previous
rename report, screenshots and measurements remain explicitly historical;
upstream Nerd Font family/package names retain their original spelling.

## Verification

The initial rename was validated on thebeast on 2026-10-24 using the locked
Nix development environment. The later logo refinement is recorded separately.

- `nix flake check --no-build` passed, including evaluation of the retained
  NVIDIA and XPS hardware configurations. The installation-contract parity,
  lifecycle checks, Plymouth package, installer and VM driver built successfully.
- The Nix lifecycle check passed 551 Python tests (including six artwork
  integrity/geometry/contrast tests), the Hermes/agent/camera fixtures and
  21 system-settings tests. `tests/nixos-native` passed its real Nix/Git,
  authenticated HTTPS, exact-input preservation, private-store source-transfer
  and retention checks.
- The native installer passed 20 unit, six UI interaction and four presentation
  tests. Its actual Slint software renderer produced welcome, account, timezone
  and installation-progress fixtures for visual review. The longer hostname
  suffix is bounded to the existing 31-character limit in both UI and daemon.
- The booted NixOS lifecycle VM passed in 100 seconds under `agent-resource`.
  It exercised the renamed services/CLI, networking defaults, personal setup,
  desktop checker, real supervised software and maintenance staging, and
  unchanged personal files/locks. The packaged Plymouth script rendered the
  supplied wordmark and masked password entry, accepted its real password
  callback, and reported no theme load/parse errors. The host invocation used
  `QEMU_OPTS=-no-user-config`; all guest disks and processes were disposable.
- QML lint passed 376 files and four harnesses, with no errors and eight
  existing warnings. The Quickshell Node suite passed 1,360 tests with 17
  skipped; the affected theme checks were rerun after updating the blue
  fallback palettes (43 passed, six skipped). Theme-pack canonicalization,
  plugin transactions and Model Usage integration checks passed too.
- The browser demo passed lint, TypeScript, all 116 component tests, production
  build and two production Worker tests. Its existing `cybexos-web` development
  service was rebuilt/restarted and is healthy on port 5174.

Both managed VM leases closed with no remaining resources. Temporary renders,
VM disks, test logs and local web build/dependency outputs were removed after
review; the existing development service remains running.

The subsequent logo refinement restored the source SVG's red `#DC1E37` in
coloured logos, terminal art and hover variants while retaining blue interface
controls/progress. That pass matched the logo to its 286-pixel input width.
All six artwork checks and three brand-registry checks passed, as did the
30 native installer tests and the package/parity builds. The full lifecycle
VM was rerun successfully in 110 seconds, including the real Plymouth password
callback and staged software/maintenance updates. New native installer and
Plymouth VM screenshots were reviewed and embedded in the conversation.
The browser development service was rebuilt and its served logo colours
verified. The managed VM lease closed with no remaining resources; temporary
captures and logs were removed after review.

The final sizing pass reduced the Plymouth wordmark to 189×44 pixels,
approximately 66% of the previous 286×67 size (378×88 at double density).
Only the two Plymouth logo rasters changed among the deployed artwork.
All six artwork checks and the package/parity builds passed; the full lifecycle
VM passed again in 119 seconds, including password submission and staged
updates. Its new screenshot was embedded in the conversation. The managed
lease closed without remaining resources, and temporary captures/logs were
removed after review.

These checks do not establish fresh ISO installation, encrypted-disk boot or
physical hardware qualification for this revision. No new ISO, published
release or host OS activation was performed. `flake.lock` and the dependency
versions in the Cargo/npm locks were retained. Release qualification continues
to require the same committed revision/NAR for artifacts and tests.

Committed development media carries its Git revision in the live release
metadata. The development installer locks the exact bundled directory as a
path input; Nix retains its NAR hash but gives that flake no Git revision, so
the installed release reports `uncommitted`. Installation qualification checks
the ISO, installed release and installed input lock against the same NAR and
records both release identities. Git-backed inputs still require the exact
revision as well as the NAR. This does not authenticate an unpublished build.
