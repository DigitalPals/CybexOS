# Evaluation parity is distinct from installation/boot qualification. Compare
# the evaluated product for the live profile's explicit choices with an ordinary
# machine importing the public module; only live credentials/install tools differ.
{ nixpkgs, pkgs, module, installer, system, inputSources, inputNarHashes }:
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  lockedNarHashes = map (node: node.locked.narHash)
    (builtins.attrValues (builtins.removeAttrs lock.nodes [ lock.root ]));
  machine = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module ({ ... }: {
      cybexos = {
        enable = true;
        primaryUser = installer.cybexos.primaryUser;
        features = installer.cybexos.features;
      };
      fileSystems."/" = { device = "/dev/disk/by-label/cybexos-root"; fsType = "ext4"; };
      fileSystems."/boot" = { device = "/dev/disk/by-label/CYBEX_EFI"; fsType = "vfat"; };
      system.stateVersion = "26.05";
    }) ];
  };
  contract = c: {
    inherit (c.cybexos) features authentication hardware;
    runtime = toString c.environment.etc."cybexos/runtime".source;
    updates = builtins.fromJSON c.environment.etc."cybexos/update.json".text;
    titlebars = toString c.environment.etc."cybexos/titlebars.so".source;
    updater = toString c.cybexos.updaterPackage;
    fonts = map toString c.fonts.packages;
    compositor = c.programs.hyprland.package.version;
    firewall = { inherit (c.networking.firewall) enable allowedTCPPorts allowedUDPPorts allowedUDPPortRanges; };
    pam = map (name: c.security.pam.services.${name}.text) [ "login" "sddm" "cybexos-lock" "polkit-1" ];
    managedShell = c.systemd.user.services.quickshell.serviceConfig;
    personalInit = c.systemd.user.services.cybexos-personal-init.serviceConfig;
    backup = c.systemd.user.services.cybexos-backup.serviceConfig;
    printing = map toString c.services.printing.drivers;
    scanning = map toString c.hardware.sane.extraBackends;
    vpn = map toString c.networking.networkmanager.plugins;
    inputMethods = map toString c.i18n.inputMethod.ibus.engines;
    accessibility = { inherit (c.services.gnome.at-spi2-core) enable; speech = c.services.speechd.enable; };
  };
  # The vendor channel default follows the release version. An administrator
  # choice, including the installer's persisted medium channel, always wins.
  channel = extra: (builtins.fromJSON (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module ./machine.nix extra ];
  }).config.environment.etc."cybexos/update.json".text).channel;
  prerelease = builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+-.+" (nixpkgs.lib.trim (builtins.readFile ../../VERSION)) != null;
  live = contract installer;
  installed = contract machine.config;
  xps = (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module ./machine.nix {
      cybexos.hardware.xps = { enable = true; sku = "0DB9"; camera = true; };
    } ];
  }).config;
  encrypted = (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module ./machine.nix {
      cybexos.encrypted = true;
      cybexos.autoLogin = true;
    } ];
  }).config;
  health = c: builtins.fromJSON c.environment.etc."cybexos/health-services.json".text;
  lib = nixpkgs.lib;
  names = map lib.getName;
  generic = machine.config;
  lpmd = lib.findFirst (p: lib.getName p == "intel-lpmd") null xps.systemd.packages;
  relay = xps.services.v4l2-relayd.instances.ipu7;
  relayUnit = xps.systemd.services.v4l2-relayd-ipu7;
  cameraInit = xps.systemd.services.xps-ipu7-camera-init;
  cameraSleep = xps.systemd.services.xps-ipu7-camera-sleep;
  pam = machine.config.security.pam;
  passwordLogin = name: !pam.services.${name}.u2f.enable && !pam.services.${name}.fprintAuth;
  keyWithPassword = name:
    let auth = pam.services.${name}.rules.auth;
    in auth.u2f.enable && auth.u2f.control == "sufficient"
      && auth.u2f.order < auth.unix.order && auth.unix.enable
      && builtins.elem "origin=pam://cybexos" auth.u2f.args
      && builtins.elem "userpresence=1" auth.u2f.args
      && !(builtins.elem "nouserok" auth.u2f.args)
      && !(builtins.elem "nullok" auth.unix.args);
in
assert live == installed;
assert builtins.elem nixpkgs.outPath inputSources;
assert builtins.sort builtins.lessThan inputNarHashes == builtins.sort builtins.lessThan lockedNarHashes;
assert builtins.length inputSources == builtins.length (nixpkgs.lib.unique inputSources);
assert builtins.all (path: builtins.elem path installer.system.extraDependencies) inputSources;
assert builtins.fromJSON installer.environment.etc."cybexos/installer-inputs.json".text == inputSources;
assert live.updates.channel == (if prerelease then "beta" else "stable");
assert channel { cybexos.release.version = "1.0.0-beta.1"; } == "beta";
assert channel { cybexos.release.version = "1.0.0-rc.2"; } == "beta";
assert channel { cybexos.release.version = "1.0.0"; } == "stable";
assert channel { cybexos.release.version = "1.0.0-beta.1"; cybexos.updates.channel = "stable"; } == "stable";
assert channel { cybexos.release.version = "1.0.0"; cybexos.updates.channel = "beta"; } == "beta";
assert builtins.all passwordLogin [ "login" "sddm" ];
assert pam.services.login.rules.auth.unix.enable;
assert !(builtins.elem "nullok" pam.services.login.rules.auth.unix.args);
assert pam.services.sddm.rules.auth.login.enable;
assert pam.services.sddm.rules.auth.login.modulePath == "login";
assert pam.services.sddm.rules.auth.login.control == "substack";
assert builtins.all keyWithPassword [ "sudo" "polkit-1" "cybexos-lock" ];
assert pam.u2f.settings.nouserok == false;
assert machine.config.security.sudo.wheelNeedsPassword;
assert machine.config.networking.firewall.enable;
assert machine.config.security.apparmor.enable;
assert builtins.elem machine.config.system.path machine.config.systemd.user.services.quickshell.path;
assert machine.config.systemd.user.services.quickshell.serviceConfig.ExecStopPost ==
  "${machine.config.cybexos.desktopPackage}/bin/cybexos-runtime shell record-stop";
# Force the complete encrypted/autologin option set: merely inspecting the
# enable flag missed an invalid SDDM option exposed by a real encrypted install.
assert builtins.isString encrypted.system.build.toplevel.drvPath;
assert encrypted.services.displayManager.autoLogin.enable;
assert !encrypted.services.displayManager.sddm.autoLogin.relogin;
assert encrypted.security.pam.services.sddm-autologin.rules.auth.cybexos-encryption.control == "requisite";
assert builtins.elem "${encrypted.cybexos.updaterPackage}/bin/cybexos-verify-encryption"
  encrypted.security.pam.services.sddm-autologin.rules.auth.cybexos-encryption.args;
assert !(builtins.elem "v4l2-relayd-ipu7.service" (health machine.config).units);
assert (health machine.config).userUnits == [];
assert builtins.all (unit: builtins.elem unit (health xps).units)
  [ "xps-ipu7-abi.service" "v4l2-relayd-ipu7.service" "xps-haptic-touchpad.service" ];
assert (health xps).userUnits == [ "xps-speaker-tuning.service" ];
assert xps.systemd.services.xps-ipu7-abi.serviceConfig.Type == "oneshot";
assert xps.systemd.services.xps-ipu7-abi.serviceConfig.RemainAfterExit;
assert builtins.elem "xps-ipu7-abi.service" xps.systemd.services.v4l2-relayd-ipu7.requires;
assert builtins.elem "xps-ipu7-abi.service" xps.systemd.services.v4l2-relayd-ipu7.after;
# Free printing/scanning drivers, the SSH VPN plugin, typing booster and the
# screen-reader stack are generic; HP's unfree plugin and vpnc never are.
assert builtins.all (name: builtins.elem name (names generic.services.printing.drivers)) [ "gutenprint" "hplip" ];
assert builtins.elem "hplip" (names generic.hardware.sane.extraBackends);
assert builtins.all (p: !(p.meta.unfree or false)) (generic.services.printing.drivers ++ generic.hardware.sane.extraBackends);
assert builtins.elem "NetworkManager-ssh" (names generic.networking.networkmanager.plugins);
assert !(builtins.any (lib.hasInfix "vpnc") (names generic.networking.networkmanager.plugins));
assert builtins.elem "ibus-typing-booster" (names generic.i18n.inputMethod.ibus.engines);
assert generic.services.gnome.at-spi2-core.enable && generic.services.speechd.enable;
assert builtins.elem "orca" (names generic.environment.systemPackages);
# Thermal and active-idle daemons are exact-XPS hardware support only.
assert !generic.services.thermald.enable;
assert !(generic.systemd.services ? intel_lpmd);
assert !(builtins.elem "thermald.service" (health generic).units);
assert builtins.all (unit: builtins.elem unit (health xps).units)
  [ "thermald.service" "intel_lpmd.service" "xps-ipu7-camera-init.service" ];
# Adaptive thermald (DPTF tables), PPD for profiles, and no rival profile manager.
assert xps.services.thermald.enable && xps.services.thermald.configFile == null;
assert xps.services.power-profiles-daemon.enable;
assert !xps.services.tlp.enable && !xps.services.auto-cpufreq.enable && !(xps.services.tuned.enable or false);
# LPMd uses upstream's unit and installed policy verbatim; nothing local tunes
# CPU restriction, HFI or EPP. The D-Bus alias serves upstream's activation file.
assert lpmd != null && lpmd.version == "0.1.0";
assert xps.environment.etc."intel_lpmd".source == "${lpmd}/etc/intel_lpmd";
assert builtins.elem lpmd xps.services.dbus.packages && xps.users.groups ? power;
assert xps.systemd.services.intel_lpmd.wantedBy == [ "multi-user.target" ];
assert xps.systemd.services.intel_lpmd.aliases == [ "org.freedesktop.intel_lpmd.service" ];
assert xps.systemd.services.intel_lpmd.serviceConfig == { };
# The processed camera keeps the previous exact sensor, orientation and format.
assert relay.input.pipeline == "icamerasrc device-name=ov08x40-uf sharpness=80 ev=-1 saturation=10 ! videoflip method=rotate-180";
assert relay.input.format == "NV12" && relay.output.format == "NV12";
assert relay.input.width == 1920 && relay.input.height == 1080 && relay.input.framerate == 30;
assert lib.hasInfix "enable-last-sample=false" relayUnit.script;
# CVS owns the sensor power path first; only alias autoload is blocked.
assert builtins.elem "ov08x40" xps.boot.blacklistedKernelModules;
assert lib.hasInfix "softdep ov08x40 pre: intel_cvs" xps.boot.extraModprobeConfig;
assert builtins.all (unit: builtins.elem unit relayUnit.requires && builtins.elem unit relayUnit.after)
  [ "xps-ipu7-abi.service" "xps-ipu7-camera-init.service" ];
assert relayUnit.partOf == [ "xps-ipu7-camera-init.service" ];
assert builtins.elem "xps-ipu7-abi.service" cameraInit.requires && builtins.elem "v4l2-relayd-ipu7.service" cameraInit.before;
assert cameraInit.serviceConfig.Type == "oneshot" && cameraInit.serviceConfig.RemainAfterExit;
# Sleep stops only userspace, then a delayed restore re-runs CVS-first init.
assert cameraSleep.wantedBy == [ "sleep.target" ] && cameraSleep.before == [ "sleep.target" ];
assert cameraSleep.unitConfig.StopWhenUnneeded && cameraSleep.serviceConfig.RemainAfterExit;
assert lib.hasInfix "stop xps-ipu7-camera-resume.service v4l2-relayd-ipu7.service" cameraSleep.serviceConfig.ExecStart;
assert lib.hasInfix "restart xps-ipu7-camera-init.service" xps.systemd.services.xps-ipu7-camera-resume.script;
# 71-* must precede systemd's 73-seat-late uaccess; 99-local.rules is too late.
assert builtins.elem "xps-ipu7-udev-rules" (names xps.services.udev.packages);
assert !(lib.hasInfix "IPU7 ISYS" xps.services.udev.extraRules);
pkgs.writeText "cybexos-shared-installation-contract.json" (builtins.toJSON live)
