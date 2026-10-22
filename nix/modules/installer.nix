{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];
  nerdos = {
    enable = true; primaryUser = "nixos";
    features = { proprietary = false; steam = false; docker = false; };
  };
  # Live installation credentials and autologin never enter the installed module.
  services.displayManager.autoLogin = { enable = true; user = "nixos"; };
  services.getty.autologinUser = lib.mkForce "nixos";
  users.users.nixos.extraGroups = [ "wheel" "networkmanager" ];
  security.sudo.wheelNeedsPassword = lib.mkForce false;
  environment.etc."nerdos/installer".text = "fresh-install-only\n";
  # Interpolation retains the store dependency. toString would leave a dangling
  # path on the live medium and make the offline source unavailable.
  environment.etc."nerdos/installer-source".text = "${../..}";
  environment.systemPackages = [ pkgs.dialog pkgs.nixos-install-tools ];
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];
  # Minimal NixOS media opens SSH by default. This desktop installer grants
  # passwordless local wheel access, so expose no unauthenticated remote login.
  services.openssh.enable = lib.mkForce false;
  networking.hostName = lib.mkForce "nerdos-installer";
  isoImage = {
    volumeID = "NERDOS_INSTALL";
    makeEfiBootable = true;
    makeUsbBootable = true;
    prependToMenuLabel = "Start ";
    appendToMenuLabel = " live / install";
    grubTheme = pkgs.runCommand "nerdos-iso-boot-theme" {} ''
      mkdir -p $out
      cp ${../../desktop/boot/theme.txt} $out/theme.txt
      cp ${../../desktop/plymouth/logo.png} $out/logo.png
      cp ${pkgs.grub2}/share/grub/unicode.pf2 $out/unicode.pf2
    '';
    splashImage = ../../desktop/boot/splash.png;
    efiSplashImage = ../../desktop/boot/splash.png;
  };
  image.baseName = lib.mkForce "nerdos-${config.nerdos.release.version}-${pkgs.stdenv.hostPlatform.system}";
  system.stateVersion = "26.05";
  systemd.user.services.nerdos-install-welcome = {
    wantedBy = [ "hyprland-session.target" ];
    serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.kitty}/bin/kitty --title NerdOS-Installer ${config.nerdos.updaterPackage}/bin/nerd install"; };
  };
}
