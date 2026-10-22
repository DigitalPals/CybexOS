# Personal declarations

Inspect `/etc/nixos/flake.nix`, `machine.nix`, `local/default.nix`, and existing
modules first. Add a narrowly scoped module and import it from
`local/default.nix`; preserve other imports. Example:

```nix
{ pkgs, ... }: {
  environment.systemPackages = [ pkgs.wireshark ];
  services.syncthing.enable = true;
  networking.wg-quick.interfaces.work = {
    address = [ "10.20.0.2/32" ];
    privateKeyFile = "/var/lib/nerdos/secrets/work-vpn.key";
    peers = [{
      publicKey = "PUBLIC_KEY";
      allowedIPs = [ "10.20.0.0/16" ];
      endpoint = "vpn.example.org:51820";
    }];
  };
}
```

Service `StateDirectory` and `LoadCredential` retain state and load runtime
secrets without exposing plaintext to the Nix store. For VPN credentials, ask
for an authorized local secret file or use a private secret-entry mechanism;
never ask the person to paste a key into chat. Do not print it to validate it.

Run `nerd update stage local`, review `nerd update status`, and apply the
returned transaction/token. Failed evaluation/build leaves the active system
available. Correct the personal module; do not disable unrelated modules.

Nixpkgs must remain the single stable root input. New personal dependencies
follow the root `nixpkgs`. Vendor input updates must leave personal input
identities alone. Major NixOS upgrades require explicit intent and compatibility
qualification; `system.stateVersion` records the installation state baseline.
