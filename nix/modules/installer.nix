{ config, options, lib, pkgs, modulesPath, ... }:
# The installation ISO boots straight into the installer: no desktop session,
# display manager or live account. tty1 shows nerdos-installer, a Slint kiosk
# drawn with the software renderer directly to KMS/DRM; it runs unprivileged
# in a logind seat session and owns no state. nerdos-installerd (root) keeps
# the draft and drives the one disk-writing worker, nerdos-install, whose
# protocol and checks are shared with the terminal and automated installers.
let
  cfg = config.nerdos.installer;
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
  reservedNames = lib.optionals (payload != null) (lib.subtractLists [ payload.config.nerdos.primaryUser ]
    (lib.unique (builtins.attrNames payload.config.users.users ++ builtins.attrNames payload.config.users.groups)));
  text = lib.getExe' updater "nerdos-install";
in {
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ./iso-boot.nix ];

  options.nerdos.installer.payload = lib.mkOption {
    type = lib.types.nullOr lib.types.raw;
    default = null;
    internal = true;
    description = "An evaluated default NerdOS system whose store paths the medium carries for installation.";
  };

  config = {
    nerdos.installationMedium = true;

    environment.etc."nerdos/installer".text = "fresh-install-only\n";
    # Interpolation retains the store dependency. toString would leave a dangling
    # path on the live medium and make the offline source unavailable.
    environment.etc."nerdos/installer-source".text = "${../..}";
    environment.etc."nerdos/installer-ui".source = installer;
    environment.etc."nerdos/installer-defaults.json".text = builtins.toJSON
      (lib.mapAttrs (_: option: option.default) options.nerdos.features);
    environment.etc."nerdos/installer-region.json".text = builtins.toJSON {
      timezone = config.time.timeZone;
      locale = config.i18n.defaultLocale;
      keyboard = config.console.keyMap;
      desktopKeyboard = config.services.xserver.xkb.layout;
    };
    environment.etc."nerdos/installer-layout.json".text = builtins.toJSON config.nerdos.installation;
    environment.etc."nerdos/installer-reserved-names.json".text = builtins.toJSON reservedNames;
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
      NerdOS installer recovery shell. Alt+F1 returns to the installer screen.
      nmtui configures the network. The installation log is /run/nerdos-installer.log.
      For the text installer, choose "Use the text installer" in the screen's
      menu, or start the ISO's text-mode entry.
    '';
    documentation.enable = lib.mkForce false;
    documentation.nixos.enable = lib.mkForce false;
    documentation.man.enable = lib.mkForce false;
    documentation.info.enable = lib.mkForce false;
    documentation.doc.enable = lib.mkForce false;
    system.installer.channel.enable = false;
    networking.hostName = lib.mkForce "nerdos-installer";
    services.logind.settings.Login = {
      IdleAction = "ignore";
      HandleLidSwitch = "ignore";
      HandleLidSwitchExternalPower = "ignore";
      HandleLidSwitchDocked = "ignore";
    };

    # ── the installer screen and its state service ──────────────────────────
    users.groups.nerdos-installer = { };
    users.users.nerdos-installer = {
      isSystemUser = true;
      group = "nerdos-installer";
      description = "NerdOS installer screen";
      extraGroups = [ "video" "input" ];
    };
    systemd.tmpfiles.rules = [ "d /run/nerdos-installer 0750 root nerdos-installer -" ];
    # tty1 belongs to the installer screen (or the text installer). NixOS
    # otherwise wants autovt@tty1 (getty@tty1) at boot; a Wants-only conflict
    # in the boot transaction makes systemd drop one side arbitrarily, before
    # any kernel command line condition is checked. logind still starts
    # autovt@ttyN for the other VTs, including the tty2 recovery shell.
    systemd.targets.getty.wants = lib.mkForce [ ];
    security.pam.services.nerdos-installer.text = ''
      auth    required pam_unix.so nullok
      account required pam_unix.so
      session required pam_unix.so
      session required pam_env.so conffile=/etc/pam/environment readenv=0
      session required ${config.systemd.package}/lib/security/pam_systemd.so
    '';

    systemd.services.nerdos-installerd = {
      description = "NerdOS installer state service";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" "NetworkManager.service" ];
      wants = [ "NetworkManager.service" ];
      unitConfig.ConditionKernelCommandLine = "!nerdos.text";
      serviceConfig = {
        ExecStart = lib.getExe' installer "nerdos-installerd";
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

    systemd.services.nerdos-installer-ui = {
      description = "NerdOS installer screen";
      wantedBy = [ "multi-user.target" ];
      wants = [ "nerdos-installerd.service" ];
      after = [ "nerdos-installerd.service" "systemd-user-sessions.service" "plymouth-quit-wait.service" "systemd-logind.service" ];
      unitConfig = {
        ConditionKernelCommandLine = "!nerdos.text";
        # A keyboard change restarts the screen; it must never give up.
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        User = "nerdos-installer";
        PAMName = "nerdos-installer";
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
        EnvironmentFile = "-/run/nerdos-installer/keyboard.env";
        Environment = [ "XDG_SESSION_TYPE=wayland" "XDG_SESSION_CLASS=user" ];
        Restart = "always";
        RestartSec = "300ms";
        # 75: no usable display; the text installer has taken tty1.
        RestartPreventExitStatus = 75;
      };
    };

    # The text installer: the boot menu's text entry (nerdos.text), or the
    # screen's menu, or automatically when no display device works. At boot
    # the kernel command line alone selects either side; no boot-time unit
    # conflicts with another (see getty.wants above).
    systemd.services.nerdos-installer-text = {
      description = "NerdOS text installer";
      wantedBy = [ "multi-user.target" ];
      after = [ "NetworkManager.service" "plymouth-quit-wait.service" ];
      unitConfig.ConditionKernelCommandLine = "nerdos.text";
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
    systemd.services.nerdos-installer-text-switch = {
      description = "Switch tty1 to the NerdOS text installer";
      conflicts = [ "getty@tty1.service" "nerdos-installer-ui.service" "nerdos-installerd.service" ];
      after = [ "nerdos-installer-ui.service" "nerdos-installerd.service" ];
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
      volumeID = "NERDOS_INSTALL";
      makeEfiBootable = true;
      makeUsbBootable = true;
      prependToMenuLabel = "Install ";
      appendToMenuLabel = "";
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
  };
}
