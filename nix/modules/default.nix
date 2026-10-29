{ config, options, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types mkIf mkDefault;
  cfg = config.cybexos;
  source = ../..;
  # GRUB's installation paths for the ESP mounted at /boot. The firmware boot
  # entry and its EFI directory carry this name.
  esp = config.boot.loader.efi.efiSysMountPoint;
  grubDirectory = "/boot/grub";
  # install-grub copies the theme here; its row variants are chosen per menu.
  themeDirectory = "/boot/theme";
  efiArch = pkgs.stdenv.hostPlatform.efiArch;
  bootloaderId = "CybexOS";
  grubLoader = "${esp}/EFI/${bootloaderId}/grub${efiArch}.efi";
  # The same closing entries as the installation medium's menu.
  closingEntries = source + /desktop/boot/closing.cfg;
  bootMenu = pkgs.writeShellScript "cybexos-boot-menu-install" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.diffutils ]}
    # Brand the generated menu and identify each exact system for the updater.
    ${cfg.updaterPackage}/bin/cybexos-boot-menu --distro ${lib.escapeShellArg config.system.nixos.distroName} \
      --append ${closingEntries} --theme ${themeDirectory} \
      --check ${pkgs.grub2_efi}/bin/grub-script-check ${grubDirectory}/grub.cfg
    # Firmware that loses its boot entry still finds the removable fallback
    # path, as with systemd-boot's installation.
    fallback=${esp}/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI
    if ! cmp -s ${grubLoader} "$fallback"; then
      mkdir -p ${esp}/EFI/BOOT
      cp ${grubLoader} "$fallback.tmp"
      sync "$fallback.tmp"
      mv -f "$fallback.tmp" "$fallback"
      sync ${esp}/EFI/BOOT
    fi
  '';
in {
  imports = [ ./desktop.nix ./security.nix ./ssh.nix ./hardware.nix ./networking.nix ./lifecycle.nix ./applications.nix ./software.nix ./maintenance.nix ];
  options.cybexos = {
    enable = mkEnableOption "the Cybex OS desktop";
    installationMedium = mkOption {
      type = types.bool;
      default = false;
      internal = true;
      description = ''
        The installation ISO's own runtime: the shared release, trust, update,
        network and boot-branding contract, without the desktop. The medium
        carries the desktop as an offline payload but never runs it.
      '';
    };
    release = {
      version = mkOption { type = types.str; default = "0.0.0-dev"; internal = true; };
      revision = mkOption { type = types.str; default = "uncommitted"; internal = true; };
      narHash = mkOption { type = types.str; default = "unavailable"; internal = true; };
    };
    primaryUser = mkOption { type = types.str; default = "cybex"; };
    installation = mkOption {
      type = types.attrsOf types.ints.positive;
      internal = true;
      readOnly = true;
      # Native GPU firmware makes an initrd about 1.5 GB. Leave room for
      # ten retained boot generations plus one being installed, and the
      # complete standard desktop on the remaining root filesystem.
      default = { minimumDiskGiB = 64; espGiB = 16; };
    };
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
      # The floating Cybex OS Assistant, its service and the agent CLIs it uses
      # (Codex; Claude Code also needs proprietary). Independent of developer.
      assistant = mkOption { type = types.bool; default = true; };
      localNetworkServices = mkOption { type = types.bool; default = true; };
    };
    bootTheme = mkOption {
      type = types.package;
      internal = true;
      readOnly = true;
      description = "GRUB menu theme shared by the installation ISO and installed systems";
      default = pkgs.callPackage ../packages/boot-theme.nix { inherit source; inherit (cfg.release) version; };
    };
    desktopPackage = mkOption { type = types.package; default = pkgs.callPackage ../packages/desktop.nix { inherit source; }; };
    updaterPackage = mkOption { type = types.package; default = pkgs.callPackage ../packages/updater.nix { inherit source; }; };
    dictationPackage = mkOption { type = types.package; default = pkgs.voxtype.override { vulkanSupport = true; }; description = "Nixpkgs Voxtype with Vulkan acceleration and CPU fallback"; };
  };
  config = lib.mkMerge [ (mkIf (cfg.enable || cfg.installationMedium) {
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      substituters = mkDefault [ "https://cache.nixos.org" ];
      # No GitHub Actions artifact is treated as a binary cache.
      auto-optimise-store = true;
    };
    nix.channel.enable = mkDefault false;
    networking.networkmanager.enable = mkDefault true;
    networking.hostName = mkDefault "cybexos";
    # OS fallbacks must be weaker than the installer's mkDefault choices
    # (1000), Settings declarations (900) and personal declarations (100).
    time.timeZone = lib.mkOverride 1100 "UTC";
    i18n.defaultLocale = lib.mkOverride 1100 "en_US.UTF-8";
    console.keyMap = mkDefault "us";
    hardware.enableRedistributableFirmware = mkDefault true;
    boot.plymouth.enable = mkDefault true;
    boot.plymouth.theme = mkDefault "cybexos";
    boot.plymouth.themePackages = [ (pkgs.callPackage ../packages/plymouth.nix { inherit source; }) ];
    boot.plymouth.logo = mkDefault ../../desktop/plymouth/logo.png;
    # Shared by the ISO and installed machines. Keep console output behind
    # Plymouth; the journal retains diagnostics and disk unlock stays visible.
    # "quiet" precedes NixOS's loglevel= parameter, which then takes effect.
    boot.kernelParams = lib.mkBefore [
      "quiet" "udev.log_level=3" "rd.udev.log_level=3"
      "systemd.show_status=false" "rd.systemd.show_status=false"
      "vt.global_cursor_default=0"
    ];
    boot.consoleLogLevel = mkDefault 0;
    boot.initrd.verbose = mkDefault false;
    # Label boot generations while keeping the upstream NixOS os-release ID.
    system.nixos.label = lib.mkOverride 900 "CybexOS-${cfg.release.version}-${config.system.nixos.release}";
    environment.etc."cybexos/release.json".text = builtins.toJSON {
      inherit (cfg.release) version revision narHash;
      configurationApi = 1; pluginApi = 1; updaterApi = 1; nixos = "26.05";
      architecture = pkgs.stdenv.hostPlatform.system;
    };
  }) (mkIf cfg.enable {
    assertions = [
      { assertion = !cfg.autoLogin || cfg.encrypted; message = "Cybex OS automatic login requires verified LUKS encryption."; }
      { assertion = lib.elem config.system.nixos.release [ "26.05" ]; message = "This Cybex OS release supports NixOS 26.05. Major upgrades require explicit qualification."; }
      { assertion = lib.versionAtLeast config.programs.hyprland.package.version "0.56.2"; message = "The Cybex OS Lua desktop needs Hyprland >=0.56.2. Externally supplied pkgs must include cybexos.overlays.default."; }
      { assertion = lib.versionAtLeast pkgs.hypridle.version "0.1.8"; message = "Cybex OS idle locking needs hypridle >=0.1.8. Externally supplied pkgs must include cybexos.overlays.default."; }
    ];
    nixpkgs.config = mkIf (cfg.features.proprietary && options.nixpkgs.config.type.name != "unique") { allowUnfree = mkDefault true; };
    services.dbus.enable = true;
    # Stable discovery paths follow the selected generation. NixOS does not
    # otherwise link arbitrary package share directories into the system profile.
    environment.pathsToLink = [ "/share/cybexos" ];
    services.fwupd.enable = mkDefault true;
    services.fstrim.enable = mkDefault true;
    services.udisks2.enable = mkDefault true;
    services.upower.enable = mkDefault true;
    services.gvfs.enable = mkDefault true;
    services.printing.enable = mkDefault true;
    services.avahi = {
      enable = mkDefault cfg.features.localNetworkServices;
      nssmdns4 = cfg.features.localNetworkServices;
      nssmdns6 = cfg.features.localNetworkServices;
      openFirewall = false; # The shared firewall below owns discovery ports.
      publish = { enable = cfg.features.localNetworkServices; addresses = cfg.features.localNetworkServices; };
    };
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
    # The boot menu has the installation medium's GRUB theme. Updates pin exact
    # systems through GRUB's environment block (lifecycle/cybexos/boot.py), so
    # the menu's own default and last-booted memory stay unused. Secure Boot
    # keeps Lanzaboote's signed systemd-boot UKIs.
    # The menu stays hidden: Esc opens it during GRUB's one-second wait, and
    # systemd-boot shows its own when a key is held. GRUB marks each start as
    # pending; cybexos-boot-started clears the mark, and a start that never got
    # there opens the menu with a notice on the next boot (boot.py).
    boot.loader.timeout = mkDefault (if cfg.secureBoot then 0 else 1);
    boot.loader.grub = {
      enable = mkDefault (!cfg.secureBoot);
      efiSupport = true;
      device = "nodev";
      # Replaces the entry NixOS derives from device, named after its distroName.
      mirroredBoots = lib.mkForce [ { path = "/boot"; devices = [ "nodev" ]; efiSysMountPoint = esp; efiBootloaderId = bootloaderId; } ];
      configurationLimit = mkDefault 10;
      theme = mkDefault cfg.bootTheme;
      splashImage = lib.mkOverride 900 null;
      # The medium's mode list; "auto" alone can choose the smallest mode.
      gfxmodeEfi = mkDefault "1920x1200,1920x1080,1366x768,1280x800,1280x720,1200x1920,1024x768,800x1280,800x600,auto";
      default = "\"\${saved_entry}\"";
      extraConfig = "background_color '${cfg.bootTheme.background}'";
      timeoutStyle = mkDefault "hidden";
      extraPerEntryConfig = ''
        set cybexos_boot=pending
        save_env cybexos_boot
      '';
      extraInstallCommands = "${bootMenu}\n";
    };
    systemd.services.cybexos-boot-started = mkIf config.boot.loader.grub.enable {
      description = "Record that this start of Cybex OS finished";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = esp;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.updaterPackage}/bin/cybexos-boot-started";
      };
    };
    boot.loader.systemd-boot.configurationLimit = mkDefault 10;
    boot.loader.efi.canTouchEfiVariables = mkDefault true;
    environment.etc."cybexos/boot.json".text = builtins.toJSON (
      if config.boot.loader.grub.enable
      then { loader = "grub"; menu = "${grubDirectory}/grub.cfg"; environment = "${grubDirectory}/grubenv"; }
      else { loader = "systemd-boot"; });
    boot.initrd.systemd.enable = true;
    boot.lanzaboote = mkIf cfg.secureBoot { enable = true; pkiBundle = "/var/lib/cybexos/secrets/secureboot"; };
  }) ];
}
