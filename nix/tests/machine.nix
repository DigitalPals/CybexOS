{ lib, ... }: {
  cybexos = { enable = true; primaryUser = "tester"; features = { proprietary = false; steam = false; docker = false; }; };
  fileSystems."/" = { device = "/dev/vda2"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/vda1"; fsType = "vfat"; };
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  # Two installed languages, so the lifecycle VM can stage a system language
  # change: the prebuilt candidate already holds both locales, and a new
  # default only rewrites /etc.
  i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" "nl_NL.UTF-8/UTF-8" ];
  system.stateVersion = "26.05";
}
