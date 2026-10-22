# Ownership and installation contract

`nix/modules` is authoritative for fresh NixOS installations. The ISO imports
these modules plus a live-only profile; both checkout entry points invoke that
ISO's `nerdos-install`. They do not provision another operating system.

| Layer | Locations | Update semantics |
|---|---|---|
| Vendor | Nix store; `/etc/nerdos/runtime`; system-profile binaries | Immutable, selected by authenticated NerdOS input |
| Machine/personal declarations | `/etc/nixos/{flake.nix,flake.lock,machine.nix,local/}` | Root-owned working copy; staged separately; vendor defaults use Nix module priorities |
| Personal desktop | `~/.config/nerdos/{shell.json,plugins.json,displays.json,hypr/user.lua}` | Live preferences; never reconciled by vendor updates |
| Personal code | `~/.local/share/nerdos/{plugins,themes}` | API 1 native/Omarchy packages, retained across system generations |
| Persistent state | Home; `/var/lib`; `/etc/NetworkManager/system-connections`; plugin-data | Independent of system generations; requires application-aware backup/migration |
| Secrets | `/var/lib/nerdos/secrets`; keyring; private runtime credentials | Root directory 0700/files 0600; no plaintext in store, source, argv or logs |
| Deployment records | `/var/lib/nerdos/transactions` | Private immutable source/lock snapshots, archive identities and GC roots |

The machine's flake has one supported stable `nixpkgs` input. NerdOS follows it
and contributes configuration/assets, not a second host package universe.
Lanzaboote is a vendor dependency following the same Nixpkgs. Personal inputs
remain separately locked. Native camera source pins have a documented narrow
hardware reason and a removal/requalification policy.

A stage copies the complete personal configuration, updates only selected
inputs, verifies lock ownership and publisher identities, archives inputs,
builds the full system and checks the candidate desktop. Apply requires the
reviewed ID/token and rejects intervening personal edits. Boot/login health
confirms a deployment; an interrupted activation restores coherent configuration
and boot selection. Working edits present at rollback are retained privately.

Nix module list definitions merge; administrator normal definitions override
vendor `mkDefault` values. The primary user's shell uses priority 900 because
NixOS also supplies it with `mkDefault`; a normal administrator definition wins.
Use `mkForce` deliberately, not to hide conflicts.

No updater changes `system.stateVersion`. Routine updates advance within 26.05;
a major release upgrade requires explicit edits and fresh qualification.
