{ lib, stdenv, source, cmake, ninja, pkg-config, qt6, makeWrapper, bash, python3, coreutils,
  quickshell, hyprland, hyprlock, hypridle, systemd, dbus, glib, openssl, git,
  gobject-introspection, wrapGAppsNoGuiHook, networkmanager, libsecret,
  gnome-online-accounts, evolution-data-server, libical, fwupd, glib-networking,
  gsettings-desktop-schemas, adwaita-icon-theme,
  satty, wayfreeze, tesseract, zbar, qrencode, hyprpicker, hyprsunset, imagemagick,
  libnotify, wtype, pulseaudio, pipewire, wireplumber, wl-clipboard, cliphist, grim, slurp,
  wf-recorder, ffmpeg, libva-utils, jq, procps, findutils, gnugrep, gnused, gawk,
  xdg-utils, xdg-terminal-exec, curl, nodejs, iw, iproute2, brightnessctl, playerctl, bluez, upower,
  power-profiles-daemon, restic, openssh, age, gnutar, zstd, util-linux, kitty, libxkbcommon, xkeyboard-config,
  fetchFromGitHub }:
let
  lazyvimStarter = fetchFromGitHub {
    owner = "LazyVim"; repo = "starter";
    rev = "803bc181d7c0d6d5eeba9274d9be49b287294d99";
    hash = "sha256-QrpnlDD4r1X4C8PqBhQ+S3ar5C+qDrU1Jm/lPqyMIFM=";
  };
  # QML helpers inherit this interpreter from the managed desktop. A plain
  # python3 earlier in PATH would shadow the system's withPackages environment.
  python = python3.withPackages (p: [ p.pygobject3 p.pillow p.dbus-python p.websockets ]);
  # QML and shell helpers run these commands directly. Bind them into the
  # desktop environment so optional developer tools or ambient host PATH cannot
  # conceal a missing product dependency (notably Node for connected widgets).
  runtimeTools = [ bash python coreutils quickshell hyprland hyprlock hypridle systemd dbus glib openssl git
    satty wayfreeze tesseract zbar qrencode hyprpicker hyprsunset imagemagick libnotify wtype
    pulseaudio pipewire wireplumber wl-clipboard cliphist grim slurp wf-recorder ffmpeg libva-utils jq
    procps findutils gnugrep gnused gawk xdg-utils xdg-terminal-exec curl nodejs iw iproute2 brightnessctl playerctl
    networkmanager bluez upower power-profiles-daemon restic openssh age gnutar zstd util-linux kitty libsecret fwupd
    libxkbcommon ];  # xkbcli: the shortcut recorder's keycode -> keysym map
  images = stdenv.mkDerivation {
    pname = "cybexos-notification-images";
    version = "1";
    src = lib.cleanSource (source + /desktop/notification-images);
    nativeBuildInputs = [ cmake ninja pkg-config qt6.wrapQtAppsHook ];
    buildInputs = [ qt6.qtbase qt6.qtdeclarative ];
    cmakeFlags = [ "-DNOTIFICATION_IMAGES_QML_DIR=lib/qt-6/qml/CybexOS/Images" ];
    doCheck = true;
    preCheck = "export QT_QPA_PLATFORM=offscreen";
  };
in stdenv.mkDerivation {
  pname = "cybexos-desktop";
  version = lib.trim (builtins.readFile (source + /VERSION));
  src = source;
  nativeBuildInputs = [ makeWrapper gobject-introspection wrapGAppsNoGuiHook ];
  buildInputs = [ python glib networkmanager libsecret gnome-online-accounts
    evolution-data-server libical fwupd glib-networking gsettings-desktop-schemas adwaita-icon-theme ];
  dontWrapGApps = true;
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/share/cybexos/runtime $out/bin $out/libexec $out/share/cybexos/skills
    cp -r desktop/quickshell $out/share/cybexos/runtime/
    cp -r desktop/hypr $out/share/cybexos/runtime/
    cp -r desktop/defaults $out/share/cybexos/
    cp -r desktop/fastfetch $out/share/cybexos/
    cp -r assets/brand $out/share/cybexos/
    mkdir -p $out/share/icons $out/share/applications
    cp -r desktop/icons/hicolor $out/share/icons/
    cp desktop/*.desktop $out/share/applications/
    substituteInPlace $out/share/cybexos/defaults/fastfetch.jsonc \
      --replace-fail @CYBEXOS_FASTFETCH@ $out/share/cybexos/fastfetch/cybexos-large.fastfetch.txt
    cp -r ${lazyvimStarter} $out/share/cybexos/defaults/nvim
    cp assets/EDM115-newline2.omp.json $out/share/cybexos/defaults/prompt.json
    cp -r assets/wallpapers $out/share/cybexos/runtime/
    cp -r agent-skills/cybexos $out/share/cybexos/skills/
    cp assets/scripts/* $out/bin/
    cp desktop/bin/* $out/bin/
    cp nix/tests/desktop-runtime.py $out/libexec/cybexos-desktop-runtime-check
    chmod +x $out/bin/*
    chmod +x $out/libexec/cybexos-desktop-runtime-check
    export PATH=${lib.makeBinPath [ python ]}:$PATH
    patchShebangs $out
  '';
  preFixup = ''
    # Share the GI, GSettings and GIO environment with every helper and the
    # Quickshell process it launches, including source-development runtimes.
    for script in $out/bin/* $out/libexec/*; do
      wrapProgram "$script" "''${gappsWrapperArgs[@]}" \
        --prefix PATH : ${lib.makeBinPath runtimeTools} \
        --prefix PATH : "$out/bin" \
        --set-default XKB_CONFIG_ROOT ${xkeyboard-config}/etc/X11/xkb \
        --prefix XDG_DATA_DIRS : ${lib.makeSearchPath "share" [ adwaita-icon-theme gnome-online-accounts evolution-data-server ]} \
        --prefix QML_IMPORT_PATH : ${lib.makeSearchPath "lib/qt-6/qml" [ images qt6.qtwebsockets qt6.qtmultimedia qt6.qt5compat ]}
    done
  '';
  doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  installCheckPhase = ''
    runHook preInstallCheck
    for module in bindings keybinding_helpers keybinding_json keybinding_preferences; do
      test -r "$out/share/cybexos/runtime/hypr/$module.lua"
    done
    for module in Keybindings.qml KeybindingsModel.js KeybindEditor.js; do
      test -r "$out/share/cybexos/runtime/quickshell/Common/$module"
    done
    for module in system_settings_keybindings system_settings_keymap; do
      test -r "$out/share/cybexos/runtime/quickshell/scripts/$module.py"
    done
    PATH=${lib.makeBinPath [ libxkbcommon ]} xkbcli compile-keymap --layout us > /dev/null
    # Settings → Keyboard lists layouts from the same data (no /usr/share on NixOS).
    test -r ${xkeyboard-config}/etc/X11/xkb/rules/evdev.xml
    env -i HOME="$TMPDIR" $out/libexec/cybexos-desktop-runtime-check
    runHook postInstallCheck
  '';
  passthru = { inherit images python runtimeTools; };
  meta.license = lib.licenses.mit;
}
