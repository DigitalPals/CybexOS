{ config, options, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types mkIf mkDefault;
  cfg = config.nerdos;
  source = ../..;
in {
  imports = [ ./desktop.nix ./security.nix ./hardware.nix ./lifecycle.nix ./applications.nix ];
  options.nerdos = {
    enable = mkEnableOption "the NerdOS desktop";
    release = {
      version = mkOption { type = types.str; default = "0.0.0-dev"; internal = true; };
      revision = mkOption { type = types.str; default = "uncommitted"; internal = true; };
      narHash = mkOption { type = types.str; default = "unavailable"; internal = true; };
    };
    primaryUser = mkOption { type = types.str; default = "nerd"; };
    encrypted = mkOption { type = types.bool; default = false; description = "Root and all persistent personal storage use LUKS; runtime verified before automatic login"; };
    autoLogin = mkOption { type = types.bool; default = false; };
    secureBoot = mkOption { type = types.bool; default = false; description = "Use locally enrolled Secure Boot keys; never disable firmware verification"; };
    features = {
      developer = mkOption { type = types.bool; default = true; };
      proprietary = mkOption { type = types.bool; default = true; };
      steam = mkOption { type = types.bool; default = true; };
      docker = mkOption { type = types.bool; default = true; };
      podman = mkOption { type = types.bool; default = true; };
      tailscale = mkOption { type = types.bool; default = true; };
      connectedWidgets = mkOption { type = types.bool; default = true; };
      localNetworkServices = mkOption { type = types.bool; default = false; };
    };
    desktopPackage = mkOption { type = types.package; default = pkgs.callPackage ../packages/desktop.nix { inherit source; }; };
    updaterPackage = mkOption { type = types.package; default = pkgs.callPackage ../packages/updater.nix { inherit source; }; };
    dictationPackage = mkOption { type = types.package; default = pkgs.voxtype.override { vulkanSupport = true; }; description = "Nixpkgs Voxtype with Vulkan acceleration and CPU fallback"; };
  };
  config = mkIf cfg.enable {
    assertions = [
      { assertion = !cfg.autoLogin || cfg.encrypted; message = "NerdOS automatic login requires verified LUKS encryption."; }
      { assertion = lib.elem config.system.nixos.release [ "26.05" ]; message = "This NerdOS release supports NixOS 26.05. Major upgrades require explicit qualification."; }
      { assertion = lib.versionAtLeast config.programs.hyprland.package.version "0.56.2"; message = "The NerdOS Lua desktop needs Hyprland >=0.56.2. Externally supplied pkgs must include nerdos.overlays.default."; }
    ];
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      substituters = mkDefault [ "https://cache.nixos.org" ];
      # No GitHub Actions artifact is treated as a binary cache.
      auto-optimise-store = true;
    };
    nix.channel.enable = mkDefault false;
    nixpkgs.config = mkIf (cfg.features.proprietary && options.nixpkgs.config.type.name != "unique") { allowUnfree = mkDefault true; };
    networking.networkmanager.enable = mkDefault true;
    networking.hostName = mkDefault "nerdos";
    time.timeZone = mkDefault "UTC";
    i18n.defaultLocale = mkDefault "en_US.UTF-8";
    console.keyMap = mkDefault "us";
    services.dbus.enable = true;
    # Stable discovery paths follow the selected generation. NixOS does not
    # otherwise link arbitrary package share directories into the system profile.
    environment.pathsToLink = [ "/share/nerdos" ];
    services.fwupd.enable = mkDefault true;
    services.fstrim.enable = mkDefault true;
    services.udisks2.enable = mkDefault true;
    services.upower.enable = mkDefault true;
    services.gvfs.enable = mkDefault true;
    services.printing.enable = mkDefault true;
    services.avahi = { enable = mkDefault true; nssmdns4 = true; openFirewall = false; };
    services.blueman.enable = mkDefault true;
    hardware.bluetooth.enable = mkDefault true;
    services.power-profiles-daemon.enable = mkDefault true;
    services.pipewire = { enable = mkDefault true; alsa.enable = true; pulse.enable = true; wireplumber.enable = true; };
    security.rtkit.enable = true;
    zramSwap.enable = mkDefault true;
    programs.fish.enable = true;
    users.users.${cfg.primaryUser} = {
      isNormalUser = true;
      shell = lib.mkOverride 900 pkgs.fish;
      extraGroups = mkDefault [ "wheel" "networkmanager" "video" ];
    };
    boot.loader.systemd-boot.enable = mkDefault (!cfg.secureBoot);
    boot.loader.efi.canTouchEfiVariables = mkDefault true;
    boot.loader.systemd-boot.configurationLimit = mkDefault 10;
    boot.initrd.systemd.enable = true;
    boot.plymouth.enable = mkDefault true;
    boot.plymouth.theme = mkDefault "nerdos";
    boot.plymouth.themePackages = [ (pkgs.callPackage ../packages/plymouth.nix { inherit source; }) ];
    boot.plymouth.logo = mkDefault ../../desktop/plymouth/logo.png;
    # Label boot generations while keeping the upstream NixOS os-release ID.
    system.nixos.label = lib.mkOverride 900 "NerdOS-${cfg.release.version}-${config.system.nixos.release}";
    boot.lanzaboote = mkIf cfg.secureBoot { enable = true; pkiBundle = "/var/lib/nerdos/secrets/secureboot"; };
    environment.etc."nerdos/release.json".text = builtins.toJSON {
      inherit (cfg.release) version revision narHash;
      configurationApi = 1; pluginApi = 1; updaterApi = 1; nixos = "26.05";
      architecture = pkgs.stdenv.hostPlatform.system;
    };
  };
}
