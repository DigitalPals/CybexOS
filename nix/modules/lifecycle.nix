{ config, lib, pkgs, ... }:
let cfg = config.cybexos;
    worker = action: {
      description = "Cybex OS ${action}";
      unitConfig.ConditionPathExists = "!/etc/cybexos/installer";
      path = [ cfg.updaterPackage cfg.desktopPackage pkgs.nix pkgs.systemd pkgs.util-linux pkgs.hyprland ];
      restartIfChanged = false;
      stopIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.updaterPackage}/bin/cybexos-admin ${action}";
        TimeoutStartSec = "infinity";
        UMask = "0077";
        KillMode = "control-group";
      };
    };
in {
  options.cybexos.updates = {
    channel = lib.mkOption {
      type = lib.types.enum [ "stable" "beta" ];
      # The stable channel rejects prereleases, so a prerelease vendor release
      # follows beta by default. Administrators may still select either.
      default = if builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+-.+" cfg.release.version != null then "beta" else "stable";
      defaultText = lib.literalMD ''`"beta"` for a prerelease `cybexos.release.version`, otherwise `"stable"`'';
    };
    trustKeys = lib.mkOption { type = lib.types.attrs; default = (builtins.fromJSON (builtins.readFile ../../release/keys/trust.json)).keys; description = "Publisher Ed25519 public keys and validity/purposes. No private keys."; };
    additionalHealthServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "my-critical-service.service" ];
      description = "Additional systemd units that must be active before a deployment can be accepted.";
    };
  };
  config = lib.mkMerge [ (lib.mkIf (cfg.enable || cfg.installationMedium) {
    # The medium authenticates its own release with the same trust and policy.
    environment.etc."cybexos/trust.json".text = builtins.toJSON { schema = 1; keys = cfg.updates.trustKeys; };
    environment.etc."cybexos/update.json".text = builtins.toJSON { schema = 1; channel = cfg.updates.channel; branch = "nixos-26.05"; };
  }) (lib.mkIf cfg.enable {
    environment.etc."cybexos/health-services.json".text = builtins.toJSON {
      schema = 1;
      units = lib.unique ([ "multi-user.target" "NetworkManager.service" "display-manager.service" ]
        ++ lib.optional config.services.libreswan.enable "ipsec.service"
        ++ lib.optional cfg.hardware.xps.enable "xps-haptic-touchpad.service"
        ++ lib.optionals (cfg.hardware.xps.enable && cfg.hardware.xps.camera)
          [ "xps-ipu7-abi.service" "v4l2-relayd-ipu7.service" ]
        ++ cfg.updates.additionalHealthServices);
      userUnits = lib.optional config.systemd.user.services.hypridle.enable "hypridle.service"
        ++ lib.optional cfg.hardware.xps.enable "xps-speaker-tuning.service";
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/cybexos 0755 root root -"
      "d /var/lib/cybexos/transactions 0700 root root -"
      "d /var/lib/cybexos/working 0755 root root -"
      "d /var/lib/cybexos/cache 0700 root root -"
      "d /var/lib/cybexos/requests 0700 root root -"
      "d /var/lib/cybexos/request-status 0755 root root -"
    ];
    systemd.services = {
      "cybexos-update@" = worker "update %i";
      cybexos-region = worker "region";
      "cybexos-software@" = worker "software %i";
      "cybexos-maintenance-policy@" = worker "maintenance-policy %i";
      "cybexos-maintenance@" = worker "maintenance %i";
      # Background preparation only downloads, builds and checks a candidate;
      # installing it stays an authorized, reviewed action.
      cybexos-update-auto = lib.recursiveUpdate (worker "update-auto") {
        description = "Cybex OS background update preparation";
        unitConfig.ConditionACPower = true;
        serviceConfig.TimeoutStartSec = "15min";
      };
      # Started by the signed-in desktop after a trial boot; desktop health decides.
      cybexos-update-confirm = lib.recursiveUpdate (worker "update-confirm") {
        description = "Cybex OS restart confirmation";
        serviceConfig.TimeoutStartSec = "5min";
      };
      cybexos-recover = (worker "recover") // {
        wantedBy = [ "multi-user.target" ];
        # Recovery runs once per boot. NixOS activation starts active targets
        # again; leaving this oneshot inactive would rerun it inside apply's
        # operation lock and make both activation and restoration fail.
        serviceConfig = (worker "recover").serviceConfig // { RemainAfterExit = true; };
        # systemd suppresses a target's implicit reverse ordering when an
        # explicit After=target is present. Keep normal service dependencies,
        # and wait for SDDM as well: graphical.target starts it beside this
        # target, while trial-boot health requires an active login manager.
        after = [ "multi-user.target" "display-manager.service" ];
      };
    };
    systemd.timers.cybexos-update-auto = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "15min"; OnUnitInactiveSec = "6h"; RandomizedDelaySec = "30min"; };
    };
    # Both units validate the updater's own state as root and take no input.
    # An active local administrator session may start them without a prompt.
    security.polkit.extraConfig = ''
      polkit.addRule(function (action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" && action.lookup("verb") == "start"
            && (action.lookup("unit") == "cybexos-update-auto.service"
                || action.lookup("unit") == "cybexos-update-confirm.service")
            && subject.local && subject.active && subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';
    # Exact versions of the components a person recognises. The update review
    # compares the running and the prepared system's copies of this file.
    environment.etc."cybexos/components.json".text = builtins.toJSON {
      schema = 1;
      components = lib.filterAttrs (_: version: version != null) {
        cybexos = cfg.release.version;
        nixos = config.system.nixos.version;
        kernel = config.boot.kernelPackages.kernel.version;
        graphics = if config.hardware.graphics.enable then config.hardware.graphics.package.version or null else null;
        nvidia = if lib.elem "nvidia" config.services.xserver.videoDrivers then config.hardware.nvidia.package.version else null;
        firmware = if config.hardware.enableRedistributableFirmware then pkgs.linux-firmware.version else null;
        hyprland = if config.programs.hyprland.enable then config.programs.hyprland.package.version else null;
      };
    };
    # Ordinary nix-collect-garbage cannot delete the indirect roots retained by
    # deployments. The Cybex OS maintenance worker owns recovery-aware retention.
    nix.gc.automatic = lib.mkDefault false;
  }) ];
}
