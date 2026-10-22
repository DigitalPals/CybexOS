# Security

NerdOS configures a NixOS workstation's login, authorization, firewall and
privileged update lifecycle. The NixOS port is unreleased and is not yet
production-qualified. Report security issues privately through the repository's
GitHub security advisories; do not include credentials or personal archives.

Nixpkgs supplies upstream packages. NerdOS releases and stable/beta channel
manifests use explicit Ed25519 publisher trust. Source revision and NAR identity
must match authenticated metadata. Invalid signatures, expiry, replay, API
incompatibility and normal-update downgrades are rejected. No production trust
key has been supplied; the checked-in trust set is empty and fails closed.

Secrets never belong in Nix expressions or source archives. Use root-owned
runtime paths and service credentials. The Nix store is publicly readable.
Personal plugins execute trusted local code and are not sandboxed.

Password-only first login unlocks the keyring. Fingerprint/FIDO authorization
retains password fallback; automatic login requires a declaration and runtime
verification of encryption. Secure Boot must never be silently disabled.
AppArmor and explicit kernel hardening replace distribution-specific policy;
policy equivalence and physical authentication still require qualification.

[Hardware/security](docs/hardware-security.md), [update trust](docs/releasing.md)
and [recovery limits](docs/recovery.md) document the concrete boundaries.
