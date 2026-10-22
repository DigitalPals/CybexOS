{ lib, ... }: {
  nerdos = { enable = true; primaryUser = "tester"; features = { proprietary = false; steam = false; docker = false; }; };
  fileSystems."/" = { device = "/dev/vda2"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/vda1"; fsType = "vfat"; };
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  system.stateVersion = "26.05";
}
