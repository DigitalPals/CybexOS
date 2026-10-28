# Evaluation parity is distinct from installation/boot qualification. The ISO
# runs only the installer; the product it installs is the payload system it
# carries. Compare that payload with an ordinary machine importing the public
# module, and check the medium's own shared release, trust and network contract.
{ nixpkgs, pkgs, module, installer, system, inputSources, inputNarHashes }:
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  lockedNarHashes = map (node: node.locked.narHash)
    (builtins.attrValues (builtins.removeAttrs lock.nodes [ lock.root ]));
  payload = installer.cybexos.installer.payload.config;
  machine = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module ({ ... }: {
      cybexos = {
        enable = true;
        primaryUser = payload.cybexos.primaryUser;
        features = payload.cybexos.features;
      };
      fileSystems."/" = { device = "/dev/disk/by-label/cybexos-root"; fsType = "ext4"; };
      fileSystems."/boot" = { device = "/dev/disk/by-label/CYBEXOS_EFI"; fsType = "vfat"; };
      system.stateVersion = "26.05";
    }) ];
  };
  contract = c: {
    inherit (c.cybexos) features authentication hardware installation;
    runtime = toString c.environment.etc."cybexos/runtime".source;
    updates = builtins.fromJSON c.environment.etc."cybexos/update.json".text;
    maintenance = {
      policy = builtins.fromJSON c.environment.etc."cybexos/maintenance.json".text;
      timer = c.systemd.timers.cybexos-maintenance-auto.timerConfig;
      genericGC = c.nix.gc.automatic;
    };
    titlebars = toString c.environment.etc."cybexos/titlebars.so".source;
    updater = toString c.cybexos.updaterPackage;
    updateWorker = c.systemd.services."cybexos-update@".serviceConfig;
    ssh = {
      inherit (c.services.openssh) enable openFirewall ports settings;
      condition = c.systemd.services.sshd.unitConfig.ConditionPathExists;
      pam = c.security.pam.services.sshd.text;
      ui = builtins.fromJSON c.environment.etc."cybexos/ssh-server.json".text;
    };
    bootBrand = {
      inherit (c.boot.plymouth) enable theme;
      packages = map toString c.boot.plymouth.themePackages;
      logo = toString c.boot.plymouth.logo;
      label = c.system.nixos.label;
      menu = {
        inherit (c.boot.loader.grub) enable efiSupport device default gfxmodeEfi;
        theme = toString c.boot.loader.grub.theme;
        firmwareEntries = map (boot: boot.efiBootloaderId) c.boot.loader.grub.mirroredBoots;
        selection = builtins.fromJSON c.environment.etc."cybexos/boot.json".text;
      };
      quiet = { inherit (c.boot) consoleLogLevel; inherit (c.boot.initrd) verbose; params = lib.take 2 c.boot.kernelParams; };
    };
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
    networking = {
      resolver = c.networking.networkmanager.dns;
      resolved = c.services.resolved.enable;
      resolvconf = c.networking.resolvconf.enable;
      resolvFile = c.environment.etc."resolv.conf".source;
      fallback = c.services.resolved.settings.Resolve.FallbackDNS;
      initialize = c.systemd.services.cybexos-network-defaults.script;
      before = c.systemd.services.cybexos-network-defaults.before;
    };
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
  live = contract payload;
  installed = contract machine.config;
  xps = (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module ./machine.nix {
      cybexos.hardware.xps = { enable = true; sku = "0DB9"; camera = true; };
    } ];
  }).config;
  secureBoot = (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module ./machine.nix { cybexos.secureBoot = true; } ];
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
  # Exercise non-default fresh-install choices with the real module merger.
  # UTC/en_US fixtures alone cannot detect equal-priority default conflicts.
  regional = extra: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module ./machine.nix ] ++ extra;
  }).config;
  dutchInstall = { lib, ... }: {
    time.timeZone = lib.mkDefault "Europe/Amsterdam";
    i18n.defaultLocale = lib.mkDefault "nl_NL.UTF-8";
  };
  englishInstall = { lib, ... }: {
    time.timeZone = lib.mkDefault "Europe/London";
    i18n.defaultLocale = lib.mkDefault "en_GB.UTF-8";
  };
  regionalSettings = { lib, ... }: {
    time.timeZone = lib.mkOverride 900 "Europe/Berlin";
    i18n.defaultLocale = lib.mkOverride 900 "de_DE.UTF-8";
  };
  personalRegion = {
    time.timeZone = "America/New_York";
    i18n.defaultLocale = "en_US.UTF-8";
  };
  regionValues = c: { timezone = c.time.timeZone; locale = c.i18n.defaultLocale; };
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
  medium = name: installer.environment.etc."cybexos/${name}".text;
  reserved = builtins.fromJSON (medium "installer-reserved-names.json");
  ui = installer.systemd.services.cybexos-installer-ui;
in
assert live == installed;
assert regionValues (regional [ ]) == { timezone = "UTC"; locale = "en_US.UTF-8"; };
assert regionValues (regional [ dutchInstall ]) == { timezone = "Europe/Amsterdam"; locale = "nl_NL.UTF-8"; };
assert regionValues (regional [ englishInstall ]) == { timezone = "Europe/London"; locale = "en_GB.UTF-8"; };
assert regionValues (regional [ dutchInstall regionalSettings ]) == { timezone = "Europe/Berlin"; locale = "de_DE.UTF-8"; };
assert regionValues (regional [ dutchInstall regionalSettings personalRegion ]) == { timezone = "America/New_York"; locale = "en_US.UTF-8"; };
# Force the complete locale-dependent system evaluation, not just the scalars.
assert builtins.isString (regional [ dutchInstall ]).system.build.toplevel.drvPath;
# The medium runs only the installer: no desktop, live account, sudo or SSH.
assert installer.cybexos.installationMedium && !installer.cybexos.enable;
assert !installer.programs.hyprland.enable && !installer.services.displayManager.sddm.enable;
assert !installer.users.users.nixos.enable && !installer.security.sudo.enable && !installer.services.openssh.enable;
assert installer.specialisation == { };
assert ui.serviceConfig.User == "cybexos-installer" && ui.serviceConfig.TTYPath == "/dev/tty1";
assert ui.serviceConfig.PAMName == "cybexos-installer";
assert installer.systemd.services.cybexos-installerd.serviceConfig.KillMode == "process";
assert installer.systemd.services.cybexos-installerd.serviceConfig.OOMPolicy == "continue";
# It authenticates and installs with the same release, trust and update policy.
assert medium "release.json" == payload.environment.etc."cybexos/release.json".text;
assert medium "trust.json" == payload.environment.etc."cybexos/trust.json".text;
assert medium "update.json" == payload.environment.etc."cybexos/update.json".text;
assert installer.services.resolved.enable && installer.systemd.services ? cybexos-network-defaults;
assert builtins.elem payload.system.path installer.isoImage.storeContents;
assert builtins.all (name: builtins.elem name reserved) [ "root" "messagebus" "nobody" "wheel" ];
assert !(builtins.elem payload.cybexos.primaryUser reserved);
assert builtins.fromJSON installer.environment.etc."cybexos/installer-layout.json".text == installed.installation;
assert installed.networking.resolved && !installed.networking.resolvconf;
assert installed.networking.resolver == "systemd-resolved";
assert installed.networking.resolvFile == "/run/systemd/resolve/stub-resolv.conf";
assert installed.networking.fallback == [ "8.8.8.8" "8.8.4.4" "2001:4860:4860::8888" "2001:4860:4860::8844" ];
assert builtins.elem "NetworkManager.service" installed.networking.before;
assert pam.services.passwd.rules.password.unix.control == "required";
assert pam.services.passwd.rules.password.gnome_keyring.enable;
assert pam.services.passwd.rules.password.gnome_keyring.control == "required";
assert pam.services.passwd.rules.password.unix.order < pam.services.passwd.rules.password.gnome_keyring.order;
assert installed.maintenance.policy == { automatic = true; keepConfirmed = 5; keepDays = 30; };
assert installed.maintenance.timer.OnCalendar == "weekly";
assert !installed.maintenance.genericGC;
assert builtins.elem nixpkgs.outPath inputSources;
assert builtins.sort builtins.lessThan inputNarHashes == builtins.sort builtins.lessThan lockedNarHashes;
assert builtins.length inputSources == builtins.length (nixpkgs.lib.unique inputSources);
assert builtins.all (path: builtins.elem path installer.system.extraDependencies) inputSources;
assert builtins.fromJSON installer.environment.etc."cybexos/installer-inputs.json".text == inputSources;
assert installer.boot.plymouth.theme == "cybexos";
# The installed menu has the medium's own theme and is selected by exact system.
assert installed.bootBrand.menu.theme == toString installer.isoImage.grubTheme;
assert installed.bootBrand.menu.enable && installed.bootBrand.menu.efiSupport;
assert installed.bootBrand.menu.firmwareEntries == [ "CybexOS" ];
assert installed.bootBrand.menu.selection == { loader = "grub"; menu = "/boot/grub/grub.cfg"; environment = "/boot/grub/grubenv"; };
assert installed.bootBrand.quiet == { consoleLogLevel = 3; verbose = false; params = [ "quiet" "udev.log_level=3" ]; };
# Secure Boot keeps signed Lanzaboote UKIs and the systemd-boot selection.
assert !secureBoot.boot.loader.grub.enable && secureBoot.boot.lanzaboote.enable;
assert (builtins.fromJSON secureBoot.environment.etc."cybexos/boot.json".text).loader == "systemd-boot";
assert installer.system.nixos.distroId == "nixos";
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
# The disk passphrase cached at unlock reaches GNOME Keyring, once per boot.
assert encrypted.systemd.services.display-manager.serviceConfig.KeyringMode == "shared";
assert (let auth = encrypted.security.pam.services.sddm-autologin.rules.auth; in
  auth.systemd-loadkey.enable && auth.gnome_keyring.enable && auth.systemd-loadkey.order < auth.gnome_keyring.order
  && auth.gnome_keyring.control == "optional"
  && auth.cybexos-once.control == "requisite" && builtins.elem "/run/cybexos-autologin-used" auth.cybexos-once.args
  && auth.sddm-autologin-user.order < auth.cybexos-once.order && auth.cybexos-once.order < auth.permit.order);
assert !(machine.config.systemd.services.display-manager.serviceConfig ? KeyringMode);
assert !(builtins.elem "v4l2-relayd-ipu7.service" (health machine.config).units);
assert (health machine.config).userUnits == [ "hypridle.service" ];
assert builtins.all (unit: builtins.elem unit (health xps).units)
  [ "xps-ipu7-abi.service" "v4l2-relayd-ipu7.service" "xps-haptic-touchpad.service" ];
assert (health xps).userUnits == [ "hypridle.service" "xps-speaker-tuning.service" ];
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
