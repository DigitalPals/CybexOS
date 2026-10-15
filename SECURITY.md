# Security policy

CybexOS configures privileged parts of a Fedora system: sudo and Polkit
policy, systemd units, the firewall, login and disk-encryption handling, signed
update channels, and pinned downloads. We take reports about these seriously
and handle them privately until a fix is available.

## Supported versions

| Version | Supported |
| --- | --- |
| Latest CybexOS release on Fedora 44, x86_64 (ISO and source-checkout installations) | Yes |
| Older CybexOS releases | No; update with `cybex update` first |
| Other Fedora releases or architectures | No |

Until the first public release is published, reports against the current
`main` branch are accepted. Fedora packages, the kernel, and vendor
applications receive security updates through their own channels; `cybex
update` applies them.

## Reporting a vulnerability

Do not report security problems in public issues, discussions, or pull
requests.

Report them privately through GitHub's private vulnerability reporting: open
the repository's **Security** tab, choose **Advisories**, then **Report a
vulnerability**, or go directly to
<https://github.com/DigitalPals/CybexOS/security/advisories/new>.

If that button is not available, open a public issue that asks for a private
security contact and contains no technical details. A maintainer will arrange
a private channel.

### What to include

- the CybexOS version (`cybex version`) and installation path (ISO or source
  checkout);
- the affected component, file, or command;
- the impact: what an attacker gains, and from which starting position (local
  user, another account, the local network, a malicious download or update);
- reproduction steps or a proof of concept, and any non-default settings
  involved, such as passwordless sudo or sudoless Docker;
- whether the problem is already public or known to others.

`cybex report` writes a redacted diagnostic bundle,
`cybexos-report-<timestamp>.tar.gz`, on your machine. Review its contents before
sharing it, and attach it only to the private advisory, never to a public
issue. Never attach unredacted logs, credentials, tokens, SSH or GPG keys,
recovery keys, or browser profiles.

## What to expect

Response times depend on maintainer availability. These are goals, not
guarantees:

- acknowledge a report within 7 days;
- share an initial assessment within 14 days;
- agree on a fix and disclosure timeline with the reporter, prioritising by
  severity.

Fixes ship as new releases. Published releases are immutable, so a
correction is always a new version rather than an edited release.

## Scope

In scope is CybexOS's own code and configuration:

- the source-checkout installer, Ansible roles, and saved configuration
  handling;
- the ISO image, its installer, the `cybexos-desktop` RPM, provisioning,
  repair, and reconciliation;
- the `cybex` command, helper scripts, Quickshell shell, and agent skill;
- update, release, signing, and provenance verification, including pinned
  download checks;
- privilege boundaries: sudo, Polkit, systemd units, firewall policy, login,
  and automatic-login encryption checks;
- insecure defaults, or CybexOS configuration that makes an upstream weakness
  exploitable.

Report problems in the upstream software itself to its maintainers: Fedora
(kernel and packages), RPM Fusion, Hyprland, Quickshell, Flatpak applications,
and vendor applications such as Brave, 1Password, ChatGPT, Tailscale, Steam,
Spotify, Claude Code, Codex, OpenCode, and T3 Code. If you are unsure, report
privately here and we will help route it.

Documented, explicit opt-ins, such as passwordless sudo, passwordless local
Polkit, sudoless Docker, or additional local-network firewall ports, are
accepted trade-offs rather than vulnerabilities. A default that enables one
of them without the documented choice is in scope.

## Disclosure

We follow coordinated disclosure. Please keep details private until a fixed
release is available and a GitHub Security Advisory has been published, or
until 90 days after your report, whichever comes first, unless we agree on
another timeline. Advisories credit reporters who want to be credited.
