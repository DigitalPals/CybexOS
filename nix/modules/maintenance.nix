{ config, lib, pkgs, ... }:
let cfg = config.cybexos; in {
  options.cybexos.maintenance = {
    automatic = lib.mkOption { type = lib.types.bool; default = true; description = "Weekly recovery-aware cleanup after a confirmed healthy boot."; };
    keepConfirmed = lib.mkOption { type = lib.types.ints.between 5 100; default = 5; };
    keepDays = lib.mkOption { type = lib.types.ints.between 30 3650; default = 30; };
  };
  config = lib.mkIf cfg.enable {
    environment.etc."cybexos/maintenance.json".text = builtins.toJSON cfg.maintenance;
    systemd.services.cybexos-maintenance-auto = {
      description = "Retire obsolete Cybex OS recovery references and collect unreachable store paths";
      unitConfig.ConditionPathExists = "!/etc/cybexos/installer";
      path = [ cfg.updaterPackage pkgs.nix pkgs.systemd pkgs.util-linux ];
      restartIfChanged = false;
      stopIfChanged = false;
      serviceConfig = { Type = "oneshot"; ExecStart = "${cfg.updaterPackage}/bin/cybexos-admin maintenance-auto"; UMask = "0077"; Nice = 19; IOSchedulingClass = "idle"; TimeoutStartSec = "infinity"; };
    };
    systemd.timers.cybexos-maintenance-auto = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "weekly"; RandomizedDelaySec = "2h"; Persistent = true; };
    };
  };
}
