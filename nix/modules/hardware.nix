{ config, options, lib, pkgs, ... }:
let
  cfg = config.nerdos;
  xps = cfg.hardware.xps;
  camera = pkgs.callPackage ../packages/ipu7.nix { kernel = config.boot.kernelPackages.kernel; };
  lpmd = pkgs.callPackage ../packages/intel-lpmd.nix {};
  relay = config.services.v4l2-relayd.instances.ipu7;
in {
  options.nerdos.hardware = {
    nvidia = lib.mkOption { type = lib.types.bool; default = false; };
    nvidiaOpen = lib.mkOption { type = lib.types.bool; default = true; description = "Use open kernel modules on supported Turing or newer GPUs; choose false for supported older devices"; };
    nvidiaPrime = {
      enable = lib.mkEnableOption "hybrid graphics with explicit PRIME render offload";
      intelBusId = lib.mkOption { type = lib.types.str; default = ""; };
      amdgpuBusId = lib.mkOption { type = lib.types.str; default = ""; };
      nvidiaBusId = lib.mkOption { type = lib.types.str; default = ""; };
    };
    xps = {
      enable = lib.mkEnableOption "matched Dell XPS 2026 hardware";
      sku = lib.mkOption { type = lib.types.str; default = ""; };
      panel = lib.mkOption { type = lib.types.str; default = ""; };
      camera = lib.mkEnableOption "OVTI08F4/8086:b05d IPU7 processed camera";
      lowPower = lib.mkOption { type = lib.types.bool; default = true; description = "Intel LPMd active-idle optimization on the exact matched XPS platform; retains upstream CPU/platform safety checks"; };
      hapticIntensity = lib.mkOption { type = lib.types.enum [ "low" "mid" "high" ]; default = "high"; };
    };
  };
  config = lib.mkIf cfg.enable (lib.mkMerge [ {
    hardware.enableRedistributableFirmware = lib.mkDefault true;
    hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
    hardware.cpu.amd.updateMicrocode = lib.mkDefault true;
    hardware.graphics = { enable = true; enable32Bit = cfg.features.steam; };
    services.hardware.bolt.enable = lib.mkDefault true;
  } (lib.mkIf cfg.hardware.nvidia {
    # Selecting NVIDIA is an explicit driver choice, independent of the
    # optional proprietary application group. Its userspace is unfree even
    # when the open kernel module is selected. Permit only these drivers.
    nixpkgs.config = lib.mkIf (options.nixpkgs.config.type.name != "unique") {
      allowUnfreePredicate = lib.mkDefault (package:
        lib.elem (lib.getName package) [ "nvidia-x11" "nvidia-settings" "nvidia-persistenced" ]);
    };
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.nvidia = {
      modesetting.enable = true;
      open = cfg.hardware.nvidiaOpen;
      powerManagement.enable = true;
      package = config.boot.kernelPackages.nvidiaPackages.stable;
    };
    hardware.nvidia.prime = lib.mkIf cfg.hardware.nvidiaPrime.enable {
      inherit (cfg.hardware.nvidiaPrime) intelBusId amdgpuBusId nvidiaBusId;
      offload = { enable = true; enableOffloadCmd = true; };
    };
    services.switcherooControl.enable = lib.mkDefault cfg.hardware.nvidiaPrime.enable;
    hardware.graphics.extraPackages = [ pkgs.nvidia-vaapi-driver ];
    environment.sessionVariables = { NVD_BACKEND = "direct"; }
      // lib.optionalAttrs (!cfg.hardware.nvidiaPrime.enable) {
        LIBVA_DRIVER_NAME = "nvidia"; __GLX_VENDOR_LIBRARY_NAME = "nvidia";
      };
  }) (lib.mkIf xps.enable {
    assertions = [ { assertion = lib.elem xps.sku [ "0DB9" "0DBA" ]; message = "XPS quirks require the exact supported SKU."; } ];
    # IPU7 base/ISYS and Panther Lake graphics need the supported stable input's
    # current kernel series, not the LTS kernel. This is still Nixpkgs-owned.
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
    boot.kernelParams = lib.optional (lib.hasPrefix "30e4" xps.panel) "xe.enable_dpcd_backlight=1"
      ++ lib.optional (xps.sku == "0DB9" && xps.panel == "30e4c607") "xe.enable_psr=0";
    environment.sessionVariables.NERDOS_XPS_2026 = "1";
    # PPD owns user-selected profiles. Adaptive thermald supplies the separate
    # firmware/DPTF thermal protection; do not run a competing profile manager.
    services.thermald.enable = lib.mkDefault true;
    nerdos.updates.additionalHealthServices = lib.optional config.services.thermald.enable "thermald.service";
    environment.etc."nerdos/xps-haptic.conf".text = "intensity=${xps.hapticIntensity}\n";
    systemd.services.xps-haptic-touchpad = {
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.python3 ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${../../hardware/xps/xps-haptic-touchpad}";
        Restart = "on-failure"; RestartSec = 5;
      };
    };
    hardware.graphics.extraPackages = with pkgs; [ intel-media-driver vpl-gpu-rt intel-compute-runtime ];
    environment.etc."nerdos/xps-audio/filter-chain.conf".source = ../../hardware/xps/xps-speaker-filter-chain.conf;
    environment.etc."nerdos/xps-audio/host.conf".source = ../../hardware/xps/xps-speaker-host.conf;
    environment.systemPackages = [ (pkgs.writeShellApplication {
      name = "xps-speaker-tuning";
      runtimeInputs = with pkgs; [ coreutils gnugrep gnused gawk pulseaudio pipewire ];
      text = ''
        export NERDOS_LSP_LV2=${pkgs.lsp-plugins}/lib/lv2
        export LV2_PATH=${pkgs.lsp-plugins}/lib/lv2
        exec ${pkgs.bash}/bin/bash ${../../hardware/xps/xps-speaker-tuning} "$@"
      '';
    }) ];
    systemd.user.services.xps-speaker-tuning = {
      wantedBy = [ "hyprland-session.target" ];
      partOf = [ "hyprland-session.target" ];
      after = [ "pipewire.service" "wireplumber.service" ];
      path = with pkgs; [ bash coreutils gnugrep gnused gawk pulseaudio pipewire ];
      environment = { NERDOS_LSP_LV2 = "${pkgs.lsp-plugins}/lib/lv2"; LV2_PATH = "${pkgs.lsp-plugins}/lib/lv2"; };
      serviceConfig = {
        ExecStart = "${pkgs.bash}/bin/bash ${../../hardware/xps/xps-speaker-tuning} run";
        ExecStartPost = "${pkgs.bash}/bin/bash ${../../hardware/xps/xps-speaker-tuning} activate";
        ExecStopPost = "${pkgs.bash}/bin/bash ${../../hardware/xps/xps-speaker-tuning} deactivate";
        Restart = "on-failure"; RestartSec = 5;
      };
    };
  }) (lib.mkIf (xps.enable && xps.lowPower) {
    # LPMd follows the PowerProfiles D-Bus API (PPD here, TuneD's bridge
    # before). PPD alone owns EPP/EPB and platform profiles. Upstream's Panther
    # Lake policy keeps LP-mode CPU restriction off in all three profiles and
    # sets the SoC power slider for AC/battery. Neither daemon replaces the other.
    environment.systemPackages = [ lpmd ];
    environment.etc."intel_lpmd".source = "${lpmd}/etc/intel_lpmd";
    users.groups.power = {};
    services.dbus.packages = [ lpmd ];
    # Keep upstream's unit: its virtualization condition, unsupported-platform
    # exit status and restart limits. The alias serves its D-Bus activation.
    systemd.packages = [ lpmd ];
    systemd.services.intel_lpmd = {
      wantedBy = [ "multi-user.target" ];
      aliases = [ "org.freedesktop.intel_lpmd.service" ];
      after = [ "power-profiles-daemon.service" "upower.service" ];
    };
    nerdos.updates.additionalHealthServices = [ "intel_lpmd.service" ];
  }) (lib.mkIf (xps.enable && xps.camera) {
    environment.systemPackages = [ (pkgs.writeShellApplication {
      name = "xps-ipu7-camera-frame-check";
      runtimeInputs = [ pkgs.python3 pkgs.v4l-utils ];
      text = ''
        exec python3 ${../../hardware/xps/camera/xps-ipu7-camera-frame-check} "$@"
      '';
    }) ];
    # Source and kernel identities are a single generation. A failure blocks
    # the new generation; it never mutates the camera stack on the running OS.
    boot.extraModulePackages = [ camera.psys ];
    # CVS must acquire the sensor's USBIO power path before sensor probing.
    # Explicit modprobe from the managed initializer bypasses the blacklist.
    boot.blacklistedKernelModules = [ "ov08x40" ];
    boot.extraModprobeConfig = ''
      softdep ov08x40 pre: intel_cvs
      install intel-ipu7-psys ${pkgs.writeShellScript "ipu7-checked-load" ''
        export PATH=${lib.makeBinPath [ pkgs.python3 pkgs.pahole pkgs.kmod pkgs.zstd pkgs.coreutils ]}
        ${pkgs.python3}/bin/python3 ${../../hardware/xps/camera/xps-ipu7-abi-check} || exit $?
        exec ${pkgs.kmod}/bin/modprobe --ignore-install intel-ipu7-psys "$@"
      ''}
    '';
    # Keep the vendor file names: extraRules lands in 99-local.rules, after
    # 73-seat-late.rules has already queued the desktop uaccess ACL.
    services.udev.packages = [ (pkgs.runCommand "xps-ipu7-udev-rules" {} ''
      install -Dm444 ${../../hardware/xps/camera/71-xps-ipu7-hide-isys.rules} $out/lib/udev/rules.d/71-xps-ipu7-hide-isys.rules
      install -Dm444 ${../../hardware/xps/camera/90-xps-ipu7-psys.rules} $out/lib/udev/rules.d/90-xps-ipu7-psys.rules
    '') ];
    services.v4l2-relayd.instances.ipu7 = {
      enable = true; cardLabel = "Hardware ISP Camera";
      extraPackages = [ camera.sensor ];
      input = {
        pipeline = "icamerasrc device-name=ov08x40-uf sharpness=80 ev=-1 saturation=10 ! videoflip method=rotate-180";
        format = "NV12"; width = 1920; height = 1080;
      };
      output.format = "NV12";
    };
    # The relay can remain idle until an application opens its loopback node.
    # Active relay status alone therefore cannot certify the stock/private ABI.
    # Check the booted kernel independently, including after a trial boot.
    systemd.services.xps-ipu7-abi = {
      description = "Validate the booted XPS IPU7 private kernel ABI";
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.python3 pkgs.pahole pkgs.kmod pkgs.zstd pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.python3}/bin/python3 ${../../hardware/xps/camera/xps-ipu7-abi-check}";
      };
    };
    systemd.services.v4l2-relayd-ipu7 = {
      requires = [ "xps-ipu7-abi.service" "xps-ipu7-camera-init.service" ];
      after = [ "xps-ipu7-abi.service" "xps-ipu7-camera-init.service" ];
      partOf = [ "xps-ipu7-camera-init.service" ];
      # Keep NixOS's dynamic, exclusive-capable loopback lifecycle and plugin
      # paths. Avoid holding a producer sample across splash/capture changes.
      script = lib.mkForce ''
        pipeline=${lib.escapeShellArg ("appsrc name=appsrc caps=video/x-raw,format=${relay.input.format},width=${toString relay.input.width},height=${toString relay.input.height},framerate=${toString relay.input.framerate}/1 ! videoconvert"
          + lib.optionalString (relay.input.format != relay.output.format) " ! video/x-raw,format=${relay.output.format} ! queue")}
        exec ${pkgs.v4l2-relayd}/bin/v4l2-relayd \
          -i ${lib.escapeShellArg relay.input.pipeline} \
          -o "$pipeline ! v4l2sink name=v4l2sink device=$(cat "$V4L2_DEVICE_FILE") enable-last-sample=false"
      '';
      # Each start (boot, resume) recreates the exclusive-caps loopback node,
      # which only advertises capture once the relay attaches. Make the
      # logged-in session rediscover it; no session is a harmless no-op.
      serviceConfig.ExecStartPost = "-${pkgs.writeShellScript "xps-ipu7-refresh-wireplumber" ''
        ${pkgs.coreutils}/bin/sleep 2
        exec ${pkgs.systemd}/bin/systemctl --user --machine=${lib.escapeShellArg cfg.primaryUser}@.host try-restart wireplumber.service
      ''}";
    };
    systemd.services.xps-ipu7-camera-init = {
      description = "Initialize the matched XPS processed camera in CVS-first order";
      wantedBy = [ "multi-user.target" ];
      requires = [ "xps-ipu7-abi.service" ];
      after = [ "xps-ipu7-abi.service" ];
      before = [ "v4l2-relayd-ipu7.service" ];
      path = with pkgs; [ coreutils gnugrep kmod systemd ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 60; };
      script = builtins.readFile ../../hardware/xps/camera/xps-ipu7-camera-init;
    };
    systemd.services.xps-ipu7-camera-sleep = {
      description = "Quiesce the XPS camera before sleep and restore it after wake";
      wantedBy = [ "sleep.target" ];
      before = [ "sleep.target" ];
      unitConfig.StopWhenUnneeded = true;
      serviceConfig = {
        Type = "oneshot"; RemainAfterExit = true;
        # Cancel a pending restore first so repeated or suspend-then-hibernate
        # sleeps stay idempotent. Kernel IPU7 modules are never cycled here.
        ExecStart = "${pkgs.systemd}/bin/systemctl stop xps-ipu7-camera-resume.service v4l2-relayd-ipu7.service";
        ExecStop = [
          "-${pkgs.systemd}/bin/systemctl reset-failed xps-ipu7-camera-resume.service"
          "${pkgs.systemd}/bin/systemctl --no-block restart xps-ipu7-camera-resume.service"
        ];
      };
    };
    systemd.services.xps-ipu7-camera-resume = {
      description = "Restore the XPS processed camera after sleep";
      path = [ pkgs.coreutils pkgs.systemd ];
      serviceConfig = { Type = "oneshot"; TimeoutStartSec = 90; };
      script = ''
        sleep 2
        systemctl restart xps-ipu7-camera-init.service
        systemctl reset-failed v4l2-relayd-ipu7.service
        systemctl start v4l2-relayd-ipu7.service
      '';
    };
    nerdos.updates.additionalHealthServices = [ "xps-ipu7-camera-init.service" ];
    systemd.tmpfiles.rules = [ "d /run/camera 0750 root video -" ];
  }) ]);
}
