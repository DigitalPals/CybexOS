{ lib, pkgs, ... }: {
  # Personal declarations. Vendor modules are immutable; normal definitions
  # override vendor mkDefault values. Use mkForce only for deliberate conflicts.
  imports = [ ./software.nix ./maintenance.nix ];
  environment.systemPackages = [ ];
  # networking.wg-quick.interfaces.work = {
  #   address = [ "10.20.0.2/32" ];
  #   privateKeyFile = "/var/lib/nerdos/secrets/work-vpn.key";
  #   peers = [ { publicKey = "PUBLIC_KEY"; allowedIPs = [ "10.20.0.0/16" ]; endpoint = "vpn.example.org:51820"; } ];
  # };
}
