# Dependency and pinning policy

The repository separates reproducible inputs from channels that intentionally
track security or nightly updates. Pins live in
`inventory/group_vars/all.yml`; changing one is a review decision, not routine
playbook convergence.

## Immutable inputs

- GitHub release applications and Nerd Font archives require an exact release
  tag and SHA-256. The installer selects only that tag, checks a GitHub release
  digest when supplied, redownloads a bad cache once, stages non-RPM payloads,
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

## Intentionally moving channels

Some inputs should move, but their boundary is explicit:

- Fedora/RPM Fusion/vendor repository packages and system Flatpaks track their
  configured release channels so security fixes arrive through `./update`.
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
