{
  description = "Cybex OS: a personal, independently updatable NixOS desktop";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.4.3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs@{ self, nixpkgs, lanzaboote, ... }:
    let
      systems = [ "x86_64-linux" ];
      each = nixpkgs.lib.genAttrs systems;
      # Carry the tested input sources in the live store. A fresh machine starts
      # from this lock, without resolving the moving stable branch during install.
      inputNodes = builtins.genericClosure {
        startSet = map (value: { key = value.outPath; inherit value; })
          (builtins.attrValues (builtins.removeAttrs inputs [ "self" ]));
        operator = node: map (value: { key = value.outPath; inherit value; })
          (builtins.attrValues (node.value.inputs or {}));
      };
      inputSources = map (node: node.key) inputNodes;
      inputNarHashes = map (node: node.value.narHash) inputNodes;
      compatibility = import ./nix/desktop-compatibility.nix;
      # The default desktop the installation ISO carries as an offline payload.
      installerPayload = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ module ./nix/modules/installer-payload.nix ];
      };
      module = { options, lib, ... }: {
        imports = [ ./nix/modules lanzaboote.nixosModules.lanzaboote ];
        # NixOS VM tests can supply an already-configured, read-only pkgs.
        # Normal installations must receive the same exported compatibility overlay.
        nixpkgs.overlays = lib.mkIf (options.nixpkgs.overlays.type.name != "unique") [ compatibility ];
        cybexos.release = {
          version = nixpkgs.lib.mkDefault (nixpkgs.lib.trim (builtins.readFile ./VERSION));
          revision = nixpkgs.lib.mkDefault (self.rev or "uncommitted");
          narHash = nixpkgs.lib.mkDefault (self.narHash or "unavailable");
        };
      };
    in {
      overlays.default = compatibility;
      nixosModules = { default = module; cybexos = module; installer = ./nix/modules/installer.nix; };
      packages = each (system: let pkgs = import nixpkgs { inherit system; overlays = [ compatibility ]; config.allowUnfree = true; }; in rec {
        desktop = pkgs.callPackage ./nix/packages/desktop.nix { source = self; };
        updater = pkgs.callPackage ./nix/packages/updater.nix { source = self; };
        installer-ui = pkgs.callPackage ./nix/packages/installer.nix { source = self; };
        plymouth = pkgs.callPackage ./nix/packages/plymouth.nix { source = self; };
        xps-camera = (pkgs.callPackage ./nix/packages/ipu7.nix { kernel = pkgs.linuxPackages_latest.kernel; }).sensor;
        xps-psys = (pkgs.callPackage ./nix/packages/ipu7.nix { kernel = pkgs.linuxPackages_latest.kernel; }).psys;
        t3-code = pkgs.callPackage ./nix/packages/t3-code.nix {};
        titlebars = pkgs.callPackage ./nix/packages/titlebars.nix {};
        iso = self.nixosConfigurations.installer.config.system.build.isoImage;
        default = desktop;
      });
      nixosConfigurations.installer = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ module ./nix/modules/installer.nix {
          cybexos.installer.payload = installerPayload;
          system.extraDependencies = inputSources;
          environment.etc."cybexos/installer-inputs.json".text = builtins.toJSON
            (map builtins.unsafeDiscardStringContext inputSources);
        } ];
      };
      checks = each (system: let pkgs = import nixpkgs { inherit system; overlays = [ compatibility ]; }; in {
        parity = import ./nix/tests/parity.nix {
          inherit nixpkgs pkgs module system inputSources inputNarHashes;
          installer = self.nixosConfigurations.installer.config;
        };
        lifecycle = pkgs.runCommand "cybexos-lifecycle-tests" {
          nativeBuildInputs = [
            (pkgs.python3.withPackages (p: [ p.websockets p.pygobject3 p.pillow p.dbus-python p.pexpect ]))
            pkgs.openssl pkgs.git pkgs.dbus pkgs.restic pkgs.quickshell pkgs.systemd
            pkgs.xdg-terminal-exec pkgs.desktop-file-utils pkgs.grub2_efi
          ];
          GI_TYPELIB_PATH = pkgs.lib.makeSearchPath "lib/girepository-1.0" [ pkgs.networkmanager pkgs.glib ];
          CYBEXOS_DBUS_SESSION_CONFIG = "${pkgs.dbus}/share/dbus-1/session.conf";
          CYBEXOS_LIBCRYPT = "${pkgs.libxcrypt}/lib/libcrypt.so.2";
        } ''
          cp -r ${self} source; chmod -R u+w source
          # Tests execute the same portable helper scripts as the packages.
          # /usr/bin/env is not available inside a normal Nix build sandbox.
          patchShebangs source
          cd source
          export PYTHONDONTWRITEBYTECODE=1
          python3 -m unittest discover -s tests/nixos -v
          python3 -B tests/nixos/hermes-bridge.py
          python3 -B tests/nixos/hermes-remote-runtime.py
          python3 -B tests/nixos/hermes-webui-auth.py
          python3 -B tests/nixos/default-agent.py
          python3 -B tests/nixos/camera-frame.py
          python3 -B tests/system-settings.py
          touch $out
        '';
        system = (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ module ./nix/tests/machine.nix ];
        }).config.system.build.toplevel;
        # Qualify the complete default application selection too. The small
        # VM/installer choices must not hide unsupported proprietary packages.
        product = (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ module ./nix/tests/machine.nix ({ lib, ... }: {
            cybexos.features = {
              proprietary = lib.mkForce true;
              steam = lib.mkForce true;
              docker = lib.mkForce true;
            };
          }) ];
        }).config.system.build.toplevel;
        nvidia-evaluation = pkgs.writeText "cybexos-nvidia-application-independence" (builtins.unsafeDiscardStringContext (
          (nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [ module ./nix/tests/machine.nix {
              cybexos.hardware.nvidia = true;
            } ];
          }).config.system.build.toplevel.drvPath));
        # Build the complete matched hardware profile: generic product builds
        # cannot detect camera-module, LPMd or hardware-unit packaging failures.
        # This remains a source/build check, never physical qualification.
        xps-system = (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ module ./nix/tests/machine.nix {
            cybexos.hardware.xps = { enable = true; sku = "0DB9"; camera = true; };
          } ];
        }).config.system.build.toplevel;
        vm = import ./nix/tests/lifecycle.nix {
          inherit pkgs module inputSources;
          candidate = self.checks.${system}.system;
        };
        boot = import ./nix/tests/boot.nix { inherit pkgs module; };
      });
      devShells = each (system: let pkgs = import nixpkgs { inherit system; overlays = [ compatibility ]; }; in {
        default = pkgs.mkShell {
          packages = with pkgs; [ openssl nixfmt git nodejs quickshell qt6.qtdeclarative restic systemd
            qt6.qttools cmake ninja pkg-config qt6.qtbase sway qemu OVMF dbus util-linux lua5_4 jq procps hyprland xorriso mtools squashfsTools xdg-terminal-exec desktop-file-utils hostapd dnsmasq iw
            (python3.withPackages (p: [ p.pexpect p.pillow p.pygobject3 p.dbus-python p.websockets p.pyside6 ])) ];
          CYBEXOS_OVMF = "${pkgs.OVMF.fd}/FV";
          CYBEXOS_QA_HOSTAPD = "${pkgs.hostapd}/bin/hostapd";
          CYBEXOS_QA_DNSMASQ = "${pkgs.dnsmasq}/bin/dnsmasq";
          CYBEXOS_QA_IW = "${pkgs.iw}/bin/iw";
          CYBEXOS_LIBCRYPT = "${pkgs.libxcrypt}/lib/libcrypt.so.2";
          GI_TYPELIB_PATH = pkgs.lib.makeSearchPath "lib/girepository-1.0" [ pkgs.networkmanager pkgs.glib ];
          CYBEXOS_DBUS_SESSION_CONFIG = "${pkgs.dbus}/share/dbus-1/session.conf";
          CYBEXOS_SWAY_BINARY = "${pkgs.sway-unwrapped}/bin/sway";
          CYBEXOS_QML_IMPORT_PATH = "${pkgs.qt6.qtdeclarative}/lib/qt-6/qml:${pkgs.qt6.qtmultimedia}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml:${pkgs.qt6.qt5compat}/lib/qt-6/qml:${pkgs.quickshell}/lib/qt-6/qml";
          CYBEXOS_QT_PLUGIN_PATH = "${pkgs.qt6.qtsvg}/lib/qt-6/plugins";
          QT_QPA_PLATFORM = "offscreen";
          QT_QUICK_BACKEND = "software";
        };
      });
      templates.default = { path = ./templates/machine; description = "Machine-owned Cybex OS configuration"; };
    };
}
