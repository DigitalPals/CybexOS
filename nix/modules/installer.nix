{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];
  cybexos = {
    enable = true; primaryUser = "nixos";
    features = { proprietary = false; steam = false; docker = false; };
  };
  # Live installation credentials and autologin never enter the installed module.
  services.displayManager.autoLogin = { enable = true; user = "nixos"; };
  services.getty.autologinUser = lib.mkForce "nixos";
  users.users.nixos.extraGroups = [ "wheel" "networkmanager" ];
  security.sudo.wheelNeedsPassword = lib.mkForce false;
  environment.etc."cybexos/installer".text = "fresh-install-only\n";
  # Interpolation retains the store dependency. toString would leave a dangling
  # path on the live medium and make the offline source unavailable.
  environment.etc."cybexos/installer-source".text = "${../..}";
  environment.systemPackages = [ pkgs.dialog pkgs.nixos-install-tools ];
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];
  # Minimal NixOS media opens SSH by default. This desktop installer grants
  # passwordless local wheel access, so expose no unauthenticated remote login.
  services.openssh.enable = lib.mkForce false;
  networking.hostName = lib.mkForce "cybexos-installer";
  isoImage = {
    volumeID = "CYBEXOS_INSTALL";
    makeEfiBootable = true;
    makeUsbBootable = true;
  };
  image.baseName = lib.mkForce "cybexos-${config.cybexos.release.version}-${pkgs.stdenv.hostPlatform.system}";
  system.stateVersion = "26.05";
  systemd.user.services.cybexos-install-welcome = {
    wantedBy = [ "hyprland-session.target" ];
    serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.kitty}/bin/kitty --title CybexOS-Installer ${config.cybexos.updaterPackage}/bin/cybex install"; };
  };
}
