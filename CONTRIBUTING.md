# Contributing to CybexOS

CybexOS is an opinionated Fedora 44 desktop built on Hyprland and Quickshell.
It has two installation paths: the bootable ISO (the `cybexos-desktop` RPM and
the image tooling under `image/`) and the source checkout (`./install`, which
applies the Ansible roles in `site.yml`). The ISO defines the product.

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
Contributions are accepted under the repository's [MIT License](LICENSE).
Report security problems privately as described in [SECURITY.md](SECURITY.md).

## Before you start

- Search existing issues. For a new feature or a larger change, open a feature
  request first so the approach can be agreed before you write it.
- CybexOS prefers a strong automatic default over a new setting, and an
  existing surface (a keybinding, the launcher, a row in an existing Settings
  page) over a new panel or menubar module.
- Do not add third-party code, artwork, fonts, wallpapers, or logos unless
  their license permits redistribution and you record their provenance. See
  [licensing and asset provenance](docs/licensing.md) and the
  [redistribution audit](docs/licensing-audit.md).

## Development setup

Develop on Fedora 44 x86_64:

```bash
sudo dnf install -y git
git clone https://github.com/DigitalPals/CybexOS.git
cd CybexOS
```

The CI workflow, [`.github/workflows/tests.yml`](.github/workflows/tests.yml),
prepares the Fedora packages the source gate needs (Ansible, ansible-lint,
ShellCheck, yamllint, Ruff, Node.js 24, Qt 6 declarative tools, and others)
and configures the fingerprint-verified Hyprland COPR. The image fixtures'
dependencies are listed in [image/README.md](image/README.md#source-checks-no-iso-or-vm).

On a CybexOS machine, `cybex dev enable "$PWD"` runs live Quickshell and static
Hyprland modules from your validated checkout without modifying it;
`cybex dev disable` returns to the verified runtime. Keep exactly one live
menubar: test through `quickshell.service` and never leave a source-tree `qs`
process running beside it. See [Quickshell development notes](docs/quickshell-notes.md).

## Source gates

Run both gates before you open a pull request. Neither builds an ISO or boots
a VM.

```bash
./tests/run                    # strict source gate
python3 -B image/check-source  # image tooling and installer fixtures
```

`./tests/run --list` shows the stages and `--only STAGE` runs one; see
[the strict source gate](docs/operations.md#the-strict-source-gate). If you do
not develop on Fedora 44, run the image fixtures in the Fedora 44 test
container:

```bash
docker build -f image/Containerfile.tests -t cybexos-image-tests:44 image
docker run --rm -v "$PWD:/source:ro" cybexos-image-tests:44
```

Pull requests must pass the required checks `Fedora 44 source contract` and
`Image tooling, installer fixtures and account isolation`. Fixture suites check
the installation contract; they are not evidence that a real ISO or checkout
installation was performed, so do not describe them that way. Slower gates,
such as `./tests/fedora-vm-convergence` and ISO qualification, are described in
[the release process](docs/releasing.md).

## Installation parity

The rules are summarized from [AGENTS.md](AGENTS.md) and
[installation parity](docs/installation-parity.md):

- The current ISO installation is authoritative. `./install`, `./bootstrap`,
  and the ISO must produce the same installed product for the same release,
  hardware, and explicit choices. Resolve a difference by bringing the
  checkout path in line with the ISO.
- Every change to the installed product (applications, desktop and personal
  defaults, authentication, services, firewall policy, hardware support,
  recovery) covers both paths in the same change, reusing the shared policy,
  task files, templates, and package selections. Do not add installer-specific
  defaults.
- Add or extend regression coverage that compares both paths' outcomes, such
  as `image/test_installation_parity.py`, `image/test_desktop_payload.py`,
  `image/test_installed_policy.py`, and `image/test_user_parity.py`.
- Preserve explicit saved choices and user-owned data during installs,
  reconfiguration, and updates. Parity never justifies repartitioning an
  existing system or resetting personal settings. Automatic login keeps the
  verified-encryption requirement.
- Release comparisons use artifacts built from the same source revision.

## Dependencies and pinning

Follow the [dependency and pinning policy](docs/dependency-policy.md). Pins live
in `inventory/group_vars/all.yml`: GitHub release applications and fonts need an
exact tag and SHA-256, source builds a full commit, container images a manifest
digest, and vendor repository keys a checksum plus full fingerprint. Changing a
pin is a review decision; explain the upstream reason in the pull request.
A new moving input must document why currency matters more than reproducibility.

## Code style

- Match the surrounding code. Comments explain why, not what.
- Quickshell: theme values come from `Common/Theme.qml`; register new QML types
  in their directory's `qmldir`; do not run `qmlformat`. Pure logic belongs in a
  Qt-free `.js` helper with a Node test in `tests/quickshell/*.test.cjs`.
- Shell scripts pass ShellCheck. Python passes Ruff (`pyproject.toml`) and new
  helpers get tests registered in `tests/run`. YAML passes yamllint
  (`.yamllint`) and Ansible passes ansible-lint.
- New user helper scripts go in `assets/scripts/` and are listed in
  `assets/desktop-contract.json`, which installs them on both paths. New `cybex`
  subcommands go in both dispatchers: `roles/dotfiles/templates/cybex.j2` and
  `image/rootfs/usr/bin/cybex`.
- Privileged actions use the existing Polkit-authorized systemd units or
  `pkexec`. Never add passwordless sudo or Polkit rules. Treat external input
  (URLs, files, Git repositories, themes) as data, never as code.
- User-facing copy is short, in sentence case, without exclamation marks.

## Commits and pull requests

- Branch from `main` and keep each pull request focused on one change.
- Write commit subjects in the imperative, describing the outcome, for example
  "Keep mDNS open so network printers and scanners are found". Use the body to
  explain why.
- Update the documentation that describes the behavior you changed: the
  README, `docs/`, `image/README.md`, and
  `agent-skills/cybexos/references/` for commands the agent skill should know.
- Fill in the pull request template, including both gate results.
- Never commit secrets, tokens, personal data, build artifacts, or unredacted
  logs. Remove disposable ISOs, VM disks, and logs you created while testing.

## Reporting bugs

Run `cybex report` on the affected machine. It writes a redacted diagnostic
bundle, `cybexos-report-<timestamp>.tar.gz`, locally and opens a prefilled
GitHub bug report. Review the bundle before attaching it; the redaction is a
safeguard, not a guarantee. Never attach unredacted logs, and never report a
security problem in a public issue: follow [SECURITY.md](SECURITY.md).

If you cannot run `cybex report`, use the **Bug report** form and include the
output of `cybex version`, the installation path (ISO or source checkout), and
steps to reproduce.

## Where the documentation lives

- [README.md](README.md): overview, installation, updates, and common commands
- [image/README.md](image/README.md): the ISO, its installer, first boot, and repair
- [docs/operations.md](docs/operations.md): commands, Ansible tags, updates, and recovery
- [docs/installation-parity.md](docs/installation-parity.md): the shared installation contract
- [docs/releasing.md](docs/releasing.md) and [docs/iso-releases.md](docs/iso-releases.md): release process
- [docs/architecture/ownership.md](docs/architecture/ownership.md): runtime and user-owned paths
- [docs/quickshell-notes.md](docs/quickshell-notes.md): working on the shell
- [docs/keyboard-shortcuts.md](docs/keyboard-shortcuts.md): keybinding groups
- [docs/licensing.md](docs/licensing.md): licensing and asset provenance
- [AGENTS.md](AGENTS.md): rules for coding agents, including ISO testing and artifact cleanup
