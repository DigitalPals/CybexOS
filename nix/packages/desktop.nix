{ lib, stdenv, source, cmake, ninja, pkg-config, qt6, makeWrapper, bash, python3, coreutils,
  quickshell, hyprland, hyprlock, hypridle, systemd, dbus, glib, openssl, git,
  gobject-introspection, wrapGAppsNoGuiHook, networkmanager, libsecret,
  gnome-online-accounts, evolution-data-server, libical, fwupd, glib-networking,
  gsettings-desktop-schemas, adwaita-icon-theme,
  satty, wayfreeze, tesseract, zbar, qrencode, hyprpicker, hyprsunset, imagemagick,
  libnotify, wtype, pulseaudio, pipewire, wireplumber, wl-clipboard, cliphist, grim, slurp,
  wf-recorder, ffmpeg, libva-utils, jq, procps, findutils, gnugrep, gnused, gawk,
  xdg-utils, curl, nodejs, iw, iproute2, brightnessctl, playerctl, bluez, upower,
  power-profiles-daemon, restic, openssh, age, gnutar, zstd, util-linux, kitty, fetchFromGitHub }:
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
    procps findutils gnugrep gnused gawk xdg-utils curl nodejs iw iproute2 brightnessctl playerctl
    networkmanager bluez upower power-profiles-daemon restic openssh age gnutar zstd util-linux kitty libsecret fwupd ];
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
        --prefix XDG_DATA_DIRS : ${lib.makeSearchPath "share" [ adwaita-icon-theme gnome-online-accounts evolution-data-server ]} \
        --prefix QML_IMPORT_PATH : ${lib.makeSearchPath "lib/qt-6/qml" [ images qt6.qtwebsockets qt6.qtmultimedia qt6.qt5compat ]}
    done
  '';
  doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  installCheckPhase = ''
    runHook preInstallCheck
    env -i HOME="$TMPDIR" $out/libexec/cybexos-desktop-runtime-check
    runHook postInstallCheck
  '';
  passthru = { inherit images python runtimeTools; };
  meta.license = lib.licenses.mit;
}
