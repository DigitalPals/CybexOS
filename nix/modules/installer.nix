{ config, options, lib, pkgs, modulesPath, ... }:
# The installation ISO boots straight into the installer: no desktop session,
# display manager or live account. tty1 shows cybexos-installer, a Slint kiosk
# drawn with the software renderer directly to KMS/DRM; it runs unprivileged
# in a logind seat session and owns no state. cybexos-installerd (root) keeps
# the draft and drives the one disk-writing worker, cybexos-install, whose
# protocol and checks are shared with the terminal and automated installers.
let
  cfg = config.cybexos.installer;
  installer = pkgs.callPackage ../packages/installer.nix { source = ../..; };
  updater = installer.passthru.updater;
  payload = cfg.payload;
  # The medium carries the free part of the default desktop as an offline
  # payload, so installation copies most store paths instead of downloading
  # them. The payload's initrd is per machine and is rebuilt during install;
  # unfree groups (proprietary, Steam) and NVIDIA drivers still download.
  payloadContents = lib.optionals (payload != null) (with payload.config; [
    system.path
    system.build.etc
    system.modulesTree
    boot.kernelPackages.kernel
    systemd.package
    system.build.installBootLoader
    # The option's apply merges every firmware package into one tree.
    hardware.firmware
  ]);
  reservedNames = lib.optionals (payload != null) (lib.subtractLists [ payload.config.cybexos.primaryUser ]
    (lib.unique (builtins.attrNames payload.config.users.users ++ builtins.attrNames payload.config.users.groups)));
  text = lib.getExe' updater "cybexos-install";
in {
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ./iso-boot.nix ];

  options.cybexos.installer.payload = lib.mkOption {
    type = lib.types.nullOr lib.types.raw;
    default = null;
    internal = true;
    description = "An evaluated default Cybex OS system whose store paths the medium carries for installation.";
  };

  config = {
    cybexos.installationMedium = true;

    environment.etc."cybexos/installer".text = "fresh-install-only\n";
    # Interpolation retains the store dependency. toString would leave a dangling
    # path on the live medium and make the offline source unavailable.
    environment.etc."cybexos/installer-source".text = "${../..}";
    environment.etc."cybexos/installer-ui".source = installer;
    environment.etc."cybexos/installer-defaults.json".text = builtins.toJSON
      (lib.mapAttrs (_: option: option.default) options.cybexos.features);
    environment.etc."cybexos/installer-region.json".text = builtins.toJSON {
      timezone = config.time.timeZone;
      locale = config.i18n.defaultLocale;
      keyboard = config.console.keyMap;
      desktopKeyboard = config.services.xserver.xkb.layout;
    };
    environment.etc."cybexos/installer-layout.json".text = builtins.toJSON config.cybexos.installation;
    environment.etc."cybexos/installer-reserved-names.json".text = builtins.toJSON reservedNames;
    environment.systemPackages = [ installer updater pkgs.nixos-install-tools pkgs.pciutils ];
    isoImage.storeContents = payloadContents;

    # ── no live desktop or account ──────────────────────────────────────────
    # Physical access already means control of the disks being installed; the
    # medium still exposes no remote login and no passwordless sudo account.
    users.users.nixos.enable = false;
    security.sudo.enable = lib.mkForce false;
    services.openssh.enable = lib.mkForce false;
    services.getty.autologinUser = lib.mkForce "root";
    services.getty.helpLine = lib.mkForce ''
      Cybex OS installer recovery shell. Alt+F1 returns to the installer screen.
      nmtui configures the network. The installation log is /run/cybexos-installer.log.
      For the text installer, choose "Use the text installer" in the screen's
      menu, or start the ISO's text-mode entry.
    '';
    documentation.enable = lib.mkForce false;
    documentation.nixos.enable = lib.mkForce false;
    documentation.man.enable = lib.mkForce false;
    documentation.info.enable = lib.mkForce false;
    documentation.doc.enable = lib.mkForce false;
    system.installer.channel.enable = false;
    networking.hostName = lib.mkForce "cybexos-installer";
    services.logind.settings.Login = {
      IdleAction = "ignore";
      HandleLidSwitch = "ignore";
      HandleLidSwitchExternalPower = "ignore";
      HandleLidSwitchDocked = "ignore";
    };

    # ── the installer screen and its state service ──────────────────────────
    users.groups.cybexos-installer = { };
    users.users.cybexos-installer = {
      isSystemUser = true;
      group = "cybexos-installer";
      description = "Cybex OS installer screen";
      extraGroups = [ "video" "input" ];
    };
    systemd.tmpfiles.rules = [ "d /run/cybexos-installer 0750 root cybexos-installer -" ];
    # tty1 belongs to the installer screen (or the text installer). NixOS
    # otherwise wants autovt@tty1 (getty@tty1) at boot; a Wants-only conflict
    # in the boot transaction makes systemd drop one side arbitrarily, before
    # any kernel command line condition is checked. logind still starts
    # autovt@ttyN for the other VTs, including the tty2 recovery shell.
    systemd.targets.getty.wants = lib.mkForce [ ];
    security.pam.services.cybexos-installer.text = ''
      auth    required pam_unix.so nullok
      account required pam_unix.so
      session required pam_unix.so
      session required pam_env.so conffile=/etc/pam/environment readenv=0
      session required ${config.systemd.package}/lib/security/pam_systemd.so
    '';

    systemd.services.cybexos-installerd = {
      description = "Cybex OS installer state service";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      unitConfig.ConditionKernelCommandLine = "!cybexos.text";
      serviceConfig = {
        ExecStart = lib.getExe' installer "cybexos-installerd";
        Restart = "on-failure";
        RestartSec = "1s";
        # The worker must outlive a daemon restart; it is cancelled explicitly
        # before the text installer takes over.
        KillMode = "process";
        # An out-of-memory build fails through the worker and is shown; the
        # default policy would stop the whole service and reset the screen.
        OOMPolicy = "continue";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    systemd.services.cybexos-installer-ui = {
      description = "Cybex OS installer screen";
      wantedBy = [ "multi-user.target" ];
      wants = [ "cybexos-installerd.service" ];
      after = [ "cybexos-installerd.service" "systemd-user-sessions.service" "plymouth-quit-wait.service" "systemd-logind.service" ];
      unitConfig = {
        ConditionKernelCommandLine = "!cybexos.text";
        # A keyboard change restarts the screen; it must never give up.
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        User = "cybexos-installer";
        PAMName = "cybexos-installer";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
        StandardInput = "tty-fail";
        StandardOutput = "journal";
        StandardError = "journal";
        UtmpIdentifier = "tty1";
        UtmpMode = "user";
        IgnoreSIGPIPE = false;
        # Native display drivers can still be binding when boot finishes.
        ExecStartPre = "+${config.systemd.package}/bin/udevadm settle --timeout=15";
        ExecStart = lib.getExe installer;
        EnvironmentFile = "-/run/cybexos-installer/keyboard.env";
        Environment = [ "XDG_SESSION_TYPE=wayland" "XDG_SESSION_CLASS=user" ];
        Restart = "always";
        RestartSec = "300ms";
        # 75: no usable display; the text installer has taken tty1.
        RestartPreventExitStatus = 75;
      };
    };

    # The text installer: the boot menu's text entry (cybexos.text), or the
    # screen's menu, or automatically when no display device works. At boot
    # the kernel command line alone selects either side; no boot-time unit
    # conflicts with another (see getty.wants above).
    systemd.services.cybexos-installer-text = {
      description = "Cybex OS text installer";
      wantedBy = [ "multi-user.target" ];
      after = [ "NetworkManager.service" "plymouth-quit-wait.service" ];
      unitConfig.ConditionKernelCommandLine = "cybexos.text";
      environment.TERM = "linux";
      serviceConfig = {
        ExecStart = "${text} --terminal";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        StandardInput = "tty-force";
        StandardOutput = "tty";
        StandardError = "tty";
        Restart = "no";
      };
    };
    # The screen's menu starts the text installer without the kernel flag.
    systemd.services.cybexos-installer-text-switch = {
      description = "Switch tty1 to the Cybex OS text installer";
      conflicts = [ "getty@tty1.service" "cybexos-installer-ui.service" "cybexos-installerd.service" ];
      after = [ "cybexos-installer-ui.service" "cybexos-installerd.service" ];
      environment.TERM = "linux";
      serviceConfig = {
        ExecStart = "${text} --terminal";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        StandardInput = "tty-force";
        StandardOutput = "tty";
        StandardError = "tty";
        Restart = "no";
      };
    };

    # ── hardware and boot ───────────────────────────────────────────────────
    # New hardware needs a current kernel. The pinned ZFS driver supports through
    # 7.2; linuxPackages_latest is 7.3 and fails the all-filesystems live profile.
    # Keep ZFS support and use the newest supported series from the same pin.
    boot.kernelPackages = pkgs.linuxPackages_7_2;
    # iVentoy's upstream NixOS hook inserts network-disk setup into the scripted
    # stage-one init. It cannot patch systemd's binary init: that ISO boots Linux
    # but then waits forever for the network-backed installation medium. Use the
    # upstream live-media initrd here; installed machines retain systemd stage one.
    boot.initrd.systemd.enable = lib.mkForce false;
    # iVentoy needs the wired NIC before it can expose the network-backed ISO.
    # In particular, the X1 Pro's RTL8125 (10ec:8125) uses r8169. The ordinary CD
    # profile only carries storage drivers in its initrd; stage-two NICs are late.
    boot.initrd.availableKernelModules = [
      "af_packet" "nbd"
      "r8169" "r8152" "igc" "igb" "e1000e" "e1000" "ixgbe"
      "tg3" "bnx2" "atlantic" "ax88179_178a" "cdc_ether" "cdc_ncm"
    ];
    # Keep serial diagnostics, but send /dev/console prompts to the local screen.
    boot.kernelParams = [ "console=ttyS0,115200n8" "console=tty0" ];
    # The screen draws with the CPU through any KMS driver (amdgpu, i915/xe,
    # nouveau, virtio) or the firmware framebuffer (simpledrm with nomodeset),
    # so the medium needs no GPU userspace and no separate NVIDIA kernel. The
    # installed system still selects its own NVIDIA driver.
    system.requiredKernelConfig = with config.lib.kernelConfig; [
      (isYes "DRM_SIMPLEDRM")
    ];
    isoImage = {
      volumeID = "CYBEXOS_INSTALL";
      makeEfiBootable = true;
      makeUsbBootable = true;
      prependToMenuLabel = "Install ";
      appendToMenuLabel = "";
      grubTheme = config.cybexos.bootTheme;
      splashImage = ../../desktop/boot/splash.png;
      efiSplashImage = ../../desktop/boot/splash.png;
    };
    image.baseName = lib.mkForce "cybexos-${config.cybexos.release.version}-${pkgs.stdenv.hostPlatform.system}";
    system.stateVersion = "26.05";
  };
}
