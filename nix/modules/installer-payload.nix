# A representative fresh installation, evaluated only so the installation ISO
# can carry its store paths: the default application groups minus the unfree
# ones, which the medium cannot redistribute. It never boots. Installation
# builds the real machine from its own configuration and copies whatever it
# shares with this system from the medium instead of downloading it.
{ ... }: {
  cybexos = {
    enable = true;
    encrypted = true;
    features = { proprietary = false; steam = false; };
  };
  fileSystems."/" = { device = "/dev/mapper/cybexos-install-root"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/disk/by-label/CYBEXOS_EFI"; fsType = "vfat"; };
  system.stateVersion = "26.05";
}
