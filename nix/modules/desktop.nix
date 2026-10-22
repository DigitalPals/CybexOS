{ config, lib, pkgs, ... }:
let cfg = config.cybexos;
    session = pkgs.writeTextDir "share/wayland-sessions/cybexos.desktop" ''
      [Desktop Entry]
      Name=CybexOS
      Comment=Hyprland with the CybexOS desktop
      Exec=${cfg.desktopPackage}/bin/cybexos-session
      Type=Application
      DesktopNames=Hyprland
    '';
in {
  config = lib.mkIf cfg.enable {
    programs.hyprland = { enable = true; withUWSM = false; };
    services.displayManager.sddm = { enable = true; wayland.enable = true; };
    services.displayManager.sessionPackages = [ (session.overrideAttrs (_: { passthru.providedSessions = [ "cybexos" ]; })) ];
    services.displayManager.defaultSession = lib.mkDefault "cybexos";
    services.displayManager.autoLogin = lib.mkIf cfg.autoLogin { enable = true; user = cfg.primaryUser; };
    services.displayManager.sddm.autoLogin.relogin = false;
    # A declaration alone cannot prove encryption. Refuse autologin when runtime
    # block-device ancestry does not prove encryption of root and personal data.
    security.pam.services.sddm-autologin.rules.auth.cybexos-encryption = lib.mkIf cfg.autoLogin {
      order = 50; control = "requisite";
      modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
      args = [ "quiet" "${cfg.updaterPackage}/bin/cybexos-verify-encryption" ];
    };
    environment.etc."cybexos/runtime".source = "${cfg.desktopPackage}/share/cybexos/runtime";
    environment.etc."cybexos/titlebars.so".source = "${pkgs.callPackage ../packages/titlebars.nix { hyprland = config.programs.hyprland.package; }}/lib/omarchy-hyprland-titlebars/titlebars.so";
    environment.etc."cybexos/fingerprint-enabled" = lib.mkIf cfg.authentication.fingerprint { text = "enabled\n"; };
    environment.etc."cybexos/proprietary-enabled" = lib.mkIf cfg.features.proprietary { text = "enabled\n"; };
    environment.etc."cybexos/developer-enabled" = lib.mkIf cfg.features.developer { text = "enabled\n"; };
    environment.sessionVariables = {
      CYBEXOS_CONNECTED_WIDGETS = if cfg.features.connectedWidgets then "1" else "0";
      CYBEXOS_DEVELOPER_TOOLS = if cfg.features.developer then "1" else "0";
      CYBEXOS_PROPRIETARY_APPS = if cfg.features.proprietary then "1" else "0";
      CYBEXOS_PODMAN = if cfg.features.podman then "1" else "0";
    };
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      config.Hyprland.default = [ "hyprland" "gtk" ];
    };
    systemd.user.targets.hyprland-session = {
      description = "CybexOS Hyprland session";
      bindsTo = [ "graphical-session.target" ];
      wants = [ "graphical-session-pre.target" ];
      after = [ "graphical-session-pre.target" ];
      before = [ "graphical-session.target" ];
    };
    systemd.user.services.quickshell = {
      description = "CybexOS Quickshell desktop";
      partOf = [ "hyprland-session.target" ];
      wantedBy = [ "hyprland-session.target" ];
      # User units do not inherit a login shell's system-profile PATH. The
      # Include the machine's selected packages so personal widgets can invoke
      # locally declared tools as well as the bundled desktop helpers.
      path = [ config.system.path ];
      serviceConfig = {
        ExecStart = "${cfg.desktopPackage}/bin/cybexos-runtime exec quickshell";
        ExecStopPost = "${cfg.desktopPackage}/bin/cybexos-runtime shell record-stop";
        Restart = "on-failure"; RestartSec = 2;
      };
      environment.PYTHONDONTWRITEBYTECODE = "1";
    };
    systemd.user.services.cybexos-session-lock = {
      partOf = [ "hyprland-session.target" ];
      serviceConfig = { ExecStart = "${cfg.desktopPackage}/bin/cybexos-runtime exec hyprlock"; };
    };
    systemd.user.services.hypridle = {
      partOf = [ "hyprland-session.target" ]; wantedBy = [ "hyprland-session.target" ];
      serviceConfig = { ExecStart = "${cfg.desktopPackage}/bin/cybexos-runtime exec hypridle"; Restart = "on-failure"; };
    };
    systemd.user.services.cybexos-backup = {
      description = "Encrypted personal backup and overdue reminder";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.desktopPackage}/bin/cybexos-backup scheduled";
        UMask = "0077";
      };
      path = with pkgs; [ restic openssh libsecret libnotify ];
    };
    systemd.user.services.external-monitor-toggle = {
      description = "Restore display policy after lid and dock changes";
      partOf = [ "hyprland-session.target" ]; wantedBy = [ "hyprland-session.target" ];
      serviceConfig = { ExecStart = "${cfg.desktopPackage}/bin/external-monitor-toggle"; Restart = "on-failure"; RestartSec = 3; };
      path = with pkgs; [ hyprland jq socat glib coreutils gnugrep ];
    };
    environment.etc."cybexos/models/ggml-base.bin".source = pkgs.fetchurl {
      name = "ggml-base.bin";
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin";
      hash = "sha256-YO1bw90U7qhWST0zQ0m0BXgt3K8AKNS130CINF+6Lv4=";
    };
    systemd.user.services.voxtype = {
      description = "Push-to-talk dictation";
      partOf = [ "hyprland-session.target" ]; wantedBy = [ "hyprland-session.target" ];
      after = [ "cybexos-personal-init.service" "pipewire.service" "pipewire-pulse.service" ];
      requires = [ "cybexos-personal-init.service" ];
      path = with pkgs; [ wtype wl-clipboard libnotify ];
      serviceConfig = { ExecStart = "${cfg.dictationPackage}/bin/voxtype --on-demand-loading daemon"; Restart = "on-failure"; RestartSec = 5; };
    };
    systemd.user.services.hermes-menubar-bridge = lib.mkIf cfg.features.connectedWidgets {
      description = "Remote Hermes WebUI desktop bridge";
      partOf = [ "hyprland-session.target" ]; wantedBy = [ "hyprland-session.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.callPackage ../packages/hermes-bridge.nix {}}/bin/cybexos-hermes-bridge --listen 127.0.0.1 --port 9120 --remote-only --state %h/.local/state/hermes-menubar/conversations.json --remote-auth-state %h/.local/state/hermes-menubar/remote-webui-auth.json";
        UMask = "0077";
        Restart = "on-failure"; RestartSec = 2; RestartSteps = 8; RestartMaxDelaySec = "5min";
        TimeoutStopSec = 15;
      };
    };
    systemd.user.timers.cybexos-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnStartupSec = "15m"; OnUnitActiveSec = "1h"; RandomizedDelaySec = "5m"; };
    };
    systemd.user.services.cybexos-personal-init = {
      description = "Install vendor agent skills without replacing user skills";
      wantedBy = [ "hyprland-session.target" ];
      before = [ "quickshell.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.updaterPackage}/bin/cybexos-personal-init";
        # The helper records removed defaults and never recreates them.
        ExecStartPost = "-${cfg.desktopPackage}/bin/cybexos-webapp seed";
      };
    };
  };
}
