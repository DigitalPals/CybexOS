{ config, lib, pkgs, ... }:
let cfg = config.cybexos;
    worker = action: {
      description = "CybexOS ${action}";
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
  config = lib.mkIf cfg.enable {
    environment.etc."cybexos/trust.json".text = builtins.toJSON { schema = 1; keys = cfg.updates.trustKeys; };
    environment.etc."cybexos/update.json".text = builtins.toJSON { schema = 1; channel = cfg.updates.channel; branch = "nixos-26.05"; };
    environment.etc."cybexos/health-services.json".text = builtins.toJSON {
      schema = 1;
      units = lib.unique ([ "multi-user.target" "NetworkManager.service" "display-manager.service" ]
        ++ lib.optional config.services.libreswan.enable "ipsec.service"
        ++ lib.optional cfg.hardware.xps.enable "xps-haptic-touchpad.service"
        ++ lib.optionals (cfg.hardware.xps.enable && cfg.hardware.xps.camera)
          [ "xps-ipu7-abi.service" "v4l2-relayd-ipu7.service" ]
        ++ cfg.updates.additionalHealthServices);
      userUnits = lib.optional cfg.hardware.xps.enable "xps-speaker-tuning.service";
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/cybexos 0755 root root -"
      "d /var/lib/cybexos/transactions 0700 root root -"
      "d /var/lib/cybexos/working 0755 root root -"
      "d /var/lib/cybexos/cache 0700 root root -"
    ];
    systemd.services = {
      "cybexos-stage@" = worker "stage %i";
      "cybexos-apply@" = worker "apply %i";
      cybexos-rollback = worker "rollback";
      cybexos-confirm = worker "confirm";
      cybexos-region = worker "region";
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
    # Ordinary nix-collect-garbage cannot delete the indirect roots retained by
    # deployments. Retention/pruning is an explicit administrator operation.
    nix.gc.automatic = lib.mkDefault false;
  };
}
