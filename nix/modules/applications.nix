{ config, lib, pkgs, ... }:
let
  cfg = config.cybexos;
  chatgptLinux = pkgs.callPackage ../packages/chatgpt.nix {};
in {
  options.cybexos.browser.bravePolicies = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = {};
    description = "Brave enterprise policies; administrator values override vendor defaults.";
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      cfg.desktopPackage cfg.updaterPackage
      (pkgs.callPackage ../packages/omawrite.nix {}) oh-my-posh cfg.dictationPackage
      hyprland quickshell hyprlock hypridle hyprsunset hyprpicker
      wl-clipboard cliphist grim slurp satty swappy wayfreeze wf-recorder tesseract zbar qrencode
      imagemagick libnotify wtype pulseaudio
      wlr-randr brightnessctl playerctl pavucontrol networkmanagerapplet bluez polkit
      kitty fish firefox nautilus sushi libreoffice pinta inkscape evince file-roller unicode-emoji
      system-config-printer libqalculate libva-utils v4l-utils ffmpegthumbnailer orca
      gnome-calculator gnome-text-editor simple-scan solaar mpv imv yt-dlp ffmpeg
      localsend neovim nano git gh openssh curl wget jq ripgrep fd fzf zoxide direnv eza
      bat tree unzip zip btop fastfetch delta glow duf dust pciutils usbutils lm_sensors
      strace net-tools dmidecode yq-go file _7zz bc bzip2 cifs-utils compsize
      man-pages mtr nmap tcpdump traceroute whois bind.dnsutils hunspell hunspellDicts.en_US
      age libsecret gnome-keyring p11-kit pam_u2f libfido2 fprintd fwupd sbctl efibootmgr restic
      btrfs-progs cryptsetup parted gptfdisk dosfstools util-linux openssl shadow
      (python3.withPackages (p: [ p.pygobject3 p.pillow p.dbus-python ]))
      gsettings-desktop-schemas adwaita-icon-theme adw-gtk3 glib
    ] ++ lib.optionals cfg.features.proprietary [ (pkgs.callPackage ../packages/brave-origin.nix {}) spotify chatgptLinux ]
      ++ lib.optionals (cfg.features.proprietary && cfg.features.developer) [ claude-code ]
      ++ lib.optionals cfg.features.developer [ git-lfs gcc cmake gnumake mold sccache rustup nodejs bun jdk25 tree-sitter python3 ruff shellcheck lazygit lazydocker android-tools codex opencode balena-cli (pkgs.callPackage ../packages/mdview.nix {}) ]
      ++ lib.optionals cfg.features.podman [ distrobox podman-compose ]
      ++ lib.optionals cfg.features.steam [ mangohud protonup-qt ]
      ++ lib.optionals cfg.features.connectedWidgets [ gnome-calendar gnome-online-accounts-gtk (pkgs.callPackage ../packages/t3-code.nix {}) ];
    fonts.packages = with pkgs; [
      (pkgs.callPackage ../packages/fonts.nix {}) figtree geist-font
      nerd-fonts.jetbrains-mono nerd-fonts.fira-code inter ibm-plex noto-fonts
      noto-fonts-color-emoji font-awesome fira-code jetbrains-mono
    ];
    services.tailscale.enable = lib.mkDefault cfg.features.tailscale;
    virtualisation.docker = { enable = lib.mkDefault cfg.features.docker; enableOnBoot = false; };
    virtualisation.podman.enable = lib.mkDefault cfg.features.podman;
    # Docker's socket remains root-owned. Wheel is not put in docker.
    programs._1password.enable = lib.mkDefault cfg.features.proprietary;
    # Match upstream's exact-executable user-namespace exception for Chromium's
    # sandbox; do not turn off sandboxing or weaken unrelated AppArmor policy.
    security.apparmor.policies.chatgpt = lib.mkIf cfg.features.proprietary {
      profile = chatgptLinux.appArmorProfile;
      state = "enforce";
    };
    programs._1password-gui = {
      enable = lib.mkDefault cfg.features.proprietary;
      polkitPolicyOwners = [ cfg.primaryUser ];
    };
    programs.steam = { enable = lib.mkDefault cfg.features.steam; remotePlay.openFirewall = false; dedicatedServer.openFirewall = false; };
    programs.gamemode.enable = lib.mkDefault cfg.features.steam;
    services.flatpak.enable = lib.mkDefault true;
    services.gnome.gnome-keyring.enable = true;
    services.gnome.at-spi2-core.enable = lib.mkDefault true;
    services.speechd.enable = lib.mkDefault true;
    services.gnome.gnome-online-accounts.enable = lib.mkDefault cfg.features.connectedWidgets;
    services.gnome.evolution-data-server.enable = lib.mkDefault cfg.features.connectedWidgets;
    programs.gnupg.agent = { enable = true; pinentryPackage = pkgs.pinentry-gnome3; };
    programs.firefox = {
      enable = lib.mkDefault true;
      policies.ExtensionSettings = lib.mkIf cfg.features.proprietary {
        "{d634138d-c276-4fc8-924b-40a0ea21d284}" = {
          installation_mode = lib.mkDefault "force_installed";
          install_url = lib.mkDefault "https://addons.mozilla.org/firefox/downloads/latest/1password-x-password-manager/latest.xpi";
        };
      };
    };
    cybexos.browser.bravePolicies = lib.mkIf cfg.features.proprietary {
      RestoreOnStartup = lib.mkDefault 1;
      SpellcheckLanguage = lib.mkDefault [ (lib.toLower (lib.head (lib.splitString "_" config.i18n.defaultLocale))) ];
      ExtensionInstallForcelist = lib.mkDefault [ "aeblfdkhhhdcdjpifhhbdiojplfjncoa;https://clients2.google.com/service/update2/crx" ];
    };
    # The pinned Origin executable retains Brave's native policy root. Keep
    # this namespaced file declarative and expose policy overrides above.
    environment.etc."brave/policies/managed/cybexos.json" = lib.mkIf cfg.features.proprietary {
      text = builtins.toJSON cfg.browser.bravePolicies;
    };
    hardware.sane.enable = lib.mkDefault true;
    # Driverless printers remain available; retain the maintained free drivers
    # for devices that need them. HP's proprietary firmware plugin is a local,
    # explicit choice, never an implicit unfree dependency of basic printing.
    services.printing.drivers = lib.mkDefault [ pkgs.gutenprint pkgs.hplip ];
    hardware.sane.extraBackends = lib.mkDefault [ pkgs.hplip ];
    # GNOME recommends maintained Libreswan for Cisco IKEv1/IPsec. The archived
    # vpnc plugin still has unfixed local-root CVEs and is never permitted.
    networking.networkmanager.plugins = with pkgs; [ networkmanager-openvpn networkmanager-openconnect networkmanager-ssh (pkgs.callPackage ../packages/networkmanager-libreswan.nix {}) ];
    services.libreswan.enable = lib.mkDefault true;
    environment.etc."cybexos/emoji-test.txt".source = "${pkgs.unicode-emoji}/share/unicode/emoji/emoji-test.txt";
    i18n.inputMethod = { enable = true; type = "ibus"; ibus.engines = with pkgs.ibus-engines; [ anthy chewing hangul libpinyin m17n typing-booster ]; };
  };
}
