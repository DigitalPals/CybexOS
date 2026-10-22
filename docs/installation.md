# Fresh installation

Boot a completed NerdOS x86_64 ISO in UEFI mode. The live desktop opens a
terminal installer with disk identities, machine/user/regional choices,
encryption and automatic login. `nerd install`, `./install` and `./bootstrap`
enter the same implementation and refuse to run outside the live environment.
Connect to the internet before installing: input sources, hardware-specific
components and selected applications may need downloads from upstream caches.
The installed machine uses its flake and lock file; legacy Nix channels are
disabled by default and are not copied from the live environment.

The ISO retains its tested flake input sources. A fresh machine's first lock
starts with that exact Nixpkgs revision and content hash, retaining the selected
stable branch as its upstream update source. Installation never resolves a newer
branch head implicitly. Later upstream-only updates advance this machine-owned
input independently of NerdOS. This does not make installation fully offline:
release authentication and packages not bundled on the medium require internet.

Use a backed-up target disk of at least 32 GiB. Installation erases only the
explicitly selected whole disk after its serial is confirmed. Mounted disks,
active swap and changed identities are rejected. Passwords use private input,
not arguments or configuration source. The installer creates a 1 GiB ESP and
an ext4 root, optionally under LUKS2, with zram rather than persistent plaintext
swap. Root stays locked; the chosen wheel user authorizes administration.

`nixos-generate-config` records actual hardware and filesystems. DMI/PCI/ACPI/
EDID detection selects narrowly scoped XPS/NVIDIA declarations. The machine
flake follows the stable Nixpkgs input and pins the authenticated NerdOS exact
revision/NAR identity. The complete target is built and installed through the
shared modules. First login installs missing vendor-skill discovery symlinks
and never overwrites a pre-existing personal skill.

Production media install only their own exact tested source. Before asking for
choices, the installer fetches the immutable signed manifest for the medium's
`/etc/nerdos/release.json` version (`releases/download/vVERSION/manifest.json`)
over public HTTPS, verifies its Ed25519 signature and supported metadata, and
requires its version, exact revision and NAR to equal the medium's. A channel is
never consulted to select a newer release; the medium's channel policy still
applies (stable rejects a prerelease medium). Any mismatch stops before disk
erasure and vendor evaluation. The medium's channel is written to `machine.nix`
as an explicit `nerdos.updates.channel`, so a later stable vendor release does
not move a beta machine; the vendor default is `beta` for prerelease versions and
`stable` otherwise, and the administrator may change it.

Production installation is blocked until owner-controlled trust keys and an
authenticated published release exist. For isolated development qualification,
`nerdos-install --development-source /path/to/source` explicitly selects an
unreleased content-addressed test source. Such a result is not an authenticated
release qualification.

Secure Boot is not disabled. Native Lanzaboote configuration is provided, but
fresh enrollment/signed installation media and out-of-tree-module signing have
not yet been qualified; the installer currently refuses Secure Boot installation
before erasure. See [hardware blockers](hardware-security.md).

Automated isolated installation accepts a non-secret JSON plan with `disk`,
`serial`, `hostname`, `username`, `timezone`, `locale`, `keyboard`, `encrypted`,
`autoLogin`, `secureBoot`, `nvidiaOpen`, plus password/passphrase JSON through
`--secrets-fd`. The same validation and disk-erasure guard run in both modes.
No installer reboots automatically.
