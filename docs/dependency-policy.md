# Dependency and pinning policy

The repository separates reproducible inputs from channels that intentionally
track security or nightly updates. Pins live in
`inventory/group_vars/all.yml`; changing one is a review decision, not routine
playbook convergence.

## Immutable inputs

- GitHub release applications and Nerd Font archives require an exact release
  tag and SHA-256. Before contacting GitHub, the installer can use one regular,
  non-symlink cached asset matching the inventory regex in that tag's sanitized
  cache directory. It checks the actual SHA-256 of a private copy and installs
  that copy, so cache changes cannot substitute unchecked bytes. Symlink or
  traversal paths fail safely. Missing, corrupt or ambiguous caches use the
  normal authorized release metadata/download path, which checks a GitHub release
  digest when supplied and redownloads a bad cache once. It stages non-RPM payloads
  and atomically switches `current`. Non-RPM installs retain three version
  directories; the cache keeps the two newest releases plus the current pin if
  it is older.
- Root-installed GitHub RPMs have the same tag/checksum requirement and are
  serialized behind one DNF lock. `--nogpgcheck` does not make them
  unauthenticated: the inventory SHA-256 is the explicit authorization for the
  exact RPM bytes.
- Source-built applications use a human-readable tag plus a full commit, and
  the build container is pinned by manifest digest. The commit, not the tag,
  is authoritative.
- The LazyVim starter used for an absent `~/.config/nvim` is pinned to a full
  commit. The role never overwrites an existing Neovim configuration. This pin
  covers the starter files only; LazyVim plugin state is reproducible only
  when the user's configuration has its own `lazy-lock.json`.
- Development Distrobox launchers use fully qualified manifest digests. Each
  entry also records the source tag and review date. A changed pin affects a
  newly created box; the role deliberately does not destroy an existing box.
- Rust uses a dated nightly (`nightly-YYYY-MM-DD`), not the moving `nightly`
  channel. The role installs `rustfmt` and `rust-analyzer`, retains an installed
  toolchain on a transient download failure, and fails an incomplete first
  install.
- Claude Code and OpenCode versions are explicit inventory pins.
  Claude's native installer accepts the exact target and keeps versioned
  binaries. Claude Code's pin is the version an install receives and a
  minimum afterwards: Claude Code updates itself, and a newer install is not
  downgraded. Codex CLI tracks npm's `latest` stable release, resolved on each
  installer/user-tool update run. OpenCode and Codex are installed from resolved npm package versions
  into separate staged, versioned user directories and exposed only after each
  binary reports the requested version. Neither package policy changes agent
  permissions or adds unattended-launch flags.
- Vendor repository keys, standalone font files/archives, source inputs, and
  XPS camera inputs carry the checksums or commits next to their configuration.
  See the relevant inventory and role defaults for their update points.
- The RPM Fusion signing keys are vendored in-tree as the copies that the
  `rpmfusion-*-release` packages ship (`roles/apps/files/rpmfusion-*.asc`), so
  an already-imported key is recognized without a download; each is still
  imported only after its full fingerprint matches. Rotating them means
  replacing both files and updating the fingerprints in
  `roles/apps/tasks/repos.yml` and the SHA-256 digests in
  `tests/quickshell/converge-efficiency.test.cjs`.

`tests/repository-policy.py` rejects an unpinned GitHub release, a floating
Distrobox image, malformed toolchain pins, drift in the CLI installer
template, or a changed YOLO alias. It runs inside the Python stage of
`tests/run`.

Each ISO build lists the pinned downloads it bundles, with their URLs and
SHA-256 digests or commits, in its SPDX SBOM; see
[ISO releases](iso-releases.md#software-bill-of-materials). `image/test_sbom.py`
fails when a pin lacks a checksum or commit, or when its `enabled` condition is
not a plain boolean or `{{ features.NAME }}` reference.

## Updating a pin

1. Read the upstream release notes and identify the concrete compatibility or
   security reason for the change.
2. Resolve the exact release tag/commit or container manifest digest. Download
   artifacts from the configured upstream and calculate SHA-256 locally; when
   GitHub publishes an asset digest, make sure it agrees.
3. Change the inventory pin and checksum together. For a Distrobox, keep the
   reviewed source tag beside the digest and update the review-date comment.
4. Run `./tests/run`, then use
   `ansible-playbook site.yml -e @/etc/cybexos/config.yml --check --diff`
   or an appropriately scoped direct Ansible check.
5. Apply the change and validate the installed version. Do not delete retained
   versions or an existing Distrobox until the replacement is proven and any
   data inside the box is accounted for.

The baseline pins were taken from working installed versions and locally
cached artifacts on 2026-08-27; subsequent pin changes follow the review
procedure above. This keeps clean installations reproducible without silently
authorizing speculative upgrades.

## Qualified compositor and shell series

Hyprland (from the `sdegler/hyprland` COPR) and Quickshell (from Fedora) shape
every part of the desktop: the Lua configuration API, IPC, and the QML the
shell is written against. A release is qualified on one series of each,
recorded in `qualified_package_series` in `inventory/group_vars/all.yml`:

```yaml
qualified_package_series:
  - { name: hyprland, minimum: "0.56.2", below: "0.57~" }
  - { name: quickshell, minimum: "0.2.1", below: "0.3~" }
```

Both installation paths turn each entry into a dnf versionlock entry in
`/etc/dnf/versionlock.toml` that admits `minimum <= version < below`.
`roles/base/tasks/versionlock.yml` does this for a checkout install (before
any role installs either package), an image installation and upgrade
reconciliation, all with `image/library/cybexos_versionlock.py`. Patch
releases inside the series still install and update through `cybex update`;
the next minor or major release is held back. The bounds compare like RPM
versions with an empty release, so `>= 0.56.2` admits `0.56.2-2.fc44`, and a
trailing `~` (`< 0.57~`) also excludes every `0.57` pre-release.

CybexOS writes only entries whose comment starts with `CybexOS qualified
series`, and replaces edits to them on the next converge. Every other entry is
kept as written. dnf combines the entries for one name with OR, so an
administrator who has qualified another build can admit it with an entry of
their own, for example `sudo dnf versionlock add hyprland-0.57.0-1.fc44`,
without touching ours. Uninstall removes only the CybexOS entries. A file that
cannot be read safely (invalid TOML, an unknown version, values the converge
could not write back) is left untouched and the converge warns that the series
is not enforced. A converge also warns when an installed package is already
outside its series; dnf keeps it but holds it there.

The image build verifies the series as well: `image/compose` fails when the
resolved `hyprland` or `quickshell` is missing or outside its series, so an
ISO is never published on an unqualified compositor or shell.

The shared Fedora source-test action installs the same versionlock policy
before selecting Quickshell, then rejects a missing or out-of-series installed
runtime. Required checks therefore exercise the product's supported series;
the next-Fedora preview reports an unavailable qualified build explicitly.

Because the COPR publishes only its newest build, a fresh install fails with
"matches only packages excluded by versionlock" once upstream has moved to an
unqualified series and the old build has been withdrawn; the same is true of
an image build. That failure is deliberate: it is the point at which the next
series must be reviewed. Installed systems are unaffected. The durable
updater runs `dnf upgrade --no-best` (dnf's default, stated so a local
`best=True` cannot override it), so a library upgrade that only the held-back
compositor could use is skipped instead of failing the whole update. A Fedora
major upgrade honors the lock too, so the target release's COPR must still
carry a build in the series.

### Qualifying a new series

1. Read the upstream release notes, and for Hyprland the Lua configuration
   changes (`/usr/share/hypr/stubs/hl.meta.lua` and the shipped
   `/usr/share/hypr/hyprland.lua`), for anything the CybexOS Lua or the shell
   relies on: `hl.*` calls, dispatchers, config keys, events and IPC output.
2. Raise `minimum` and `below` in `qualified_package_series` together, run
   `./tests/run` and `image/check-source`, then converge a test machine with
   `./install` and confirm `rpm -q hyprland quickshell` reports the new
   series and `hyprctl configerrors` is empty.
3. Rebuild and qualify the ISO from the same revision (`image/build`,
   `image/qualify`). The compose check fails if the resolved packages are
   outside the new series.
4. Release. Installed systems adopt the new lock when the release reconciles
   (`cybex update`), and the packages move on the following update.

To pull in only a reviewed patch release, nothing changes: it is inside the
series already.

## Intentionally moving channels

Some inputs should move, but their boundary is explicit:

- Fedora/RPM Fusion/vendor repository packages and system Flatpaks track their
  configured release channels so security fixes arrive through `./update`.
  Hyprland and Quickshell move only within their qualified series (above).
- T3 Code is deliberately the Nightly application. Its updater verifies the
  selected release asset but tracking a prerelease is part of that feature's
  contract.
- Android repository metadata selects the current command-line tools, platform,
  and build-tools. Downloads are integrity-checked against Google's metadata
  and installed transactionally, but the metadata itself is a moving input.
- The forced Firefox 1Password extension URL tracks Mozilla's current signed
  extension release.
- Anthropic's small HTTPS bootstrap script is not byte-pinned. It receives the
  exact `claude_code_version`, and the bootstrap validates the native payload
  against Anthropic's manifest. Pinning the bootstrap itself would require an
  owner-maintained checksum and rotation process that the repository does not
  currently have. After that install, Claude Code's own updater moves it past
  the pin.

These are not interchangeable with source-build or root-RPM pins. Adding a new
moving installer requires documenting why currency is more important than
byte-for-byte convergence and how a failed update preserves the working
installation.

## Source build caches

Source applications reuse a compiler image keyed by the pinned base and build
recipe. The derived image still installs current Fedora RPMs: the base digest
and requested recipe are not a complete description of the resolved toolchain.
The helper captures the derived image's immutable `sha256:` ID under the
builder lock, then runs compilation by that ID. It records all resolved RPM
NEVRAs, `rustc`, Cargo, GCC and C++ compiler versions, authorized source/base/
recipe inputs, and output binary SHA-256 digests in each deployment's
`.cybexos-build-provenance.json`. `.cybexos-builder` remains the short image ID.

Cargo's registry and per-application target caches live under
`/var/cache/cybexos-source-builds/`, outside installed application stores and
the ISO payload. Compiled targets are additionally keyed by the actual derived
image ID, so a recreated compiler image does not reuse another toolchain's
object cache; the Cargo registry remains shared. These caches trade local disk space for faster rebuilds; they
are not automatically expired. When no source build is running, an operator
can remove an obsolete recipe directory and its matching
`localhost/cybexos-source-builder:<recipe-hash>` Podman image. The next required
build recreates them. An unchanged, healthy installed binary still works
offline without either cache.

The requested inputs and healthy installed deployment allow an unchanged
converge to return without Git, Podman or network access. They do not promise
identical output after deleting and recreating a builder: Fedora security
updates may change the resolved packages. To refresh a toolchain, remove only
an unused builder image as above and perform a required build (a reviewed
source/recipe change or repair); routine convergence does not silently rebuild
intact installations. This retains normal Fedora package currency without
creating a separate compiler pin registry.

The image assembler exports these records in `applications.json` and the
checksum-covered `source-build-provenance.json` artifact, and retains them in
the offline application RPM. The ISO's SPDX root binds the exported file's
SHA-256 in `sourceInfo`; public assets carry it alongside the current raw RPM,
Flatpak, package-file and build inventories. This describes the actual derived
builder used, rather than only the requested container base. Missing compiler
metadata fails staging before activation and preserves the previous build.

## Rust toolchain documentation

New developer-tool installations use rustup's minimal profile plus explicit
rustfmt, Clippy and rust-analyzer components. The shared applications role
applies this to both checkout and ISO installs. Existing components are retained.
Offline Rust documentation is optional: install it with
`rustup component add rust-docs --toolchain nightly-2026-08-23` (use the current
inventory-pinned toolchain after a version change). `rustup doc` then opens the
local documentation. This keeps the compiler and daily development tools in the
default seed without copying the large documentation tree into every home.
