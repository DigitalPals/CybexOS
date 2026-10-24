# The installation ISO's screen and its privileged state service.
#
# nerdos-installer: the Rust/Slint kiosk, drawn with the software renderer
#   straight to KMS/DRM and driven by libinput through a logind seat. No
#   compositor, browser, Qt or GPU stack.
# nerdos-installerd: the root service that owns the draft plan, Wi-Fi, time
#   zone detection and diagnostics, and drives the unchanged nerdos-install
#   worker over its private JSON protocol.
{ lib, stdenvNoCC, rustPlatform, source, python3, makeWrapper, callPackage, pkg-config,
  fontconfig, libinput, libxkbcommon, udev, seatd, networkmanager, coreutils, iproute2, iw,
  kbd, util-linux, systemd, pciutils, tzdata, makeFontsConf, dejavu_fonts }:
let
  version = lib.trim (builtins.readFile (source + "/VERSION"));
  updater = callPackage ./updater.nix { inherit source; };
  kioskSource = builtins.path {
    name = "nerdos-installer-kiosk-source";
    path = source + "/installer/kiosk";
    filter = path: type: !(type == "directory" && baseNameOf path == "target");
  };
  screen = rustPlatform.buildRustPackage {
    pname = "nerdos-installer-screen";
    inherit version;
    src = kioskSource;
    cargoLock.lockFile = kioskSource + "/Cargo.lock";
    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ fontconfig libinput libxkbcommon udev seatd ];
    cargoBuildFlags = [ "--bin" "nerdos-installer" ];
    # The time zone tests read real TZif data, the same tzdata as the medium.
    env.TZDIR = "${tzdata}/share/zoneinfo";
    meta.mainProgram = "nerdos-installer";
  };
  # Slint embeds Space Grotesk and JetBrains Mono. Its fallback resolver still
  # consults Fontconfig, which the minimal medium does not configure globally.
  fonts = makeFontsConf { fontDirectories = [ dejavu_fonts.minimal ]; };
  python = python3;
in stdenvNoCC.mkDerivation {
  pname = "nerdos-installer";
  inherit version;
  src = source;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/bin $out/libexec
    cp installer/nerdos-installerd $out/libexec/nerdos-installerd
    cp desktop/quickshell/scripts/network-tool.py $out/libexec/network-tool.py
    patchShebangs $out/libexec
    makeWrapper ${screen}/bin/nerdos-installer $out/bin/nerdos-installer \
      --set-default FONTCONFIG_FILE ${fonts} \
      --set-default NERDOS_INSTALLER_ZOOM auto
    makeWrapper ${python}/bin/python3 $out/bin/nerdos-installerd \
      --add-flags "-B $out/libexec/nerdos-installerd" \
      --prefix PYTHONPATH : ${updater}/lib \
      --prefix PATH : ${lib.makeBinPath [ updater networkmanager coreutils iproute2 iw kbd util-linux systemd pciutils ]} \
      --set PYTHONDONTWRITEBYTECODE 1 \
      --set TZDIR ${tzdata}/share/zoneinfo \
      --set NERDOS_NETWORK_HELPER $out/libexec/network-tool.py
  '';
  passthru = { inherit screen updater; };
  meta = {
    license = lib.licenses.mit;
    mainProgram = "nerdos-installer";
  };
}
