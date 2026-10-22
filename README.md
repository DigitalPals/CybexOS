# CybexOS

CybexOS is a NixOS desktop built around Hyprland, a custom Quickshell interface,
keyboard-driven applications, and personal extensions that stay yours.
NixOS 26.05 on x86_64 is the current target. This is an **unreleased replacement**;
[qualification and release blockers](docs/validation.md) describe its actual status.

The same NixOS modules define the live ISO and installed product. Vendor desktop
code lives in immutable store paths. Your machine owns its configuration and lock
file; personal modules and persistent data are separate from vendor releases.

- [Fresh installation](docs/installation.md)
- [Architecture and ownership](docs/architecture/ownership.md)
- [Independent updates](docs/updates.md)
- [Personal configuration and plugin development](docs/customization.md)
- [Release publishing and signing keys](docs/releasing.md)
- [Recovery, persistence and garbage collection](docs/recovery.md)
- [Hardware and security](docs/hardware-security.md)
- [Validation status](docs/validation.md)

Upstream packages and CybexOS are independently selectable:

```console
cybex update check
cybex update stage upstream  # or cybexos, both, local
cybex update status          # review the built changes and returned ID/token
cybex update apply ID TOKEN
# Reboot when you choose, sign in, then:
cybex update confirm
```

Both the desktop Update button and CLI use the supervised, serialized lifecycle.
A failed combined preview can be retried explicitly with `stage upstream` while
retaining installed CybexOS. Personal inputs are never refreshed implicitly.

For source work, use `nix develop` and `tests/run`. Build the ISO with
`nix build .#iso`; use task-specific staging and the repository's ISO/PXE rules.
A successful build or fixture suite does not qualify installation, runtime,
physical hardware, or a different source revision. Nothing in these commands
publishes a release or changes the running workstation.
