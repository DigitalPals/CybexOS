# The installation ISO's screen and its privileged state service.
#
# cybexos-installer: the Rust/Slint kiosk, drawn with the software renderer
#   straight to KMS/DRM and driven by libinput through a logind seat. No
#   compositor, browser, Qt or GPU stack.
# cybexos-installerd: the root service that owns the draft plan, Wi-Fi, time
#   zone detection and diagnostics, and drives the unchanged cybexos-install
#   worker over its private JSON protocol.
{ lib, stdenvNoCC, rustPlatform, source, python3, makeWrapper, callPackage, pkg-config,
  fontconfig, libinput, libxkbcommon, udev, seatd, networkmanager, coreutils, iproute2, iw,
  kbd, util-linux, systemd, pciutils, tzdata, makeFontsConf, dejavu_fonts }:
let
  version = lib.trim (builtins.readFile (source + "/VERSION"));
  updater = callPackage ./updater.nix { inherit source; };
  kioskSource = builtins.path {
    name = "cybexos-installer-kiosk-source";
    path = source + "/installer/kiosk";
    filter = path: type: !(type == "directory" && baseNameOf path == "target");
  };
  screen = rustPlatform.buildRustPackage {
    pname = "cybexos-installer-screen";
    inherit version;
    src = kioskSource;
    cargoLock.lockFile = kioskSource + "/Cargo.lock";
    # Slint 1.18's KMS software renderer drops the cursor callback, repaints
    # triple buffers in full and blends in uncached display memory. Its
    # libinput backend also has no held-key repeat. Patch pinned dependencies
    # in this build's private vendor copy, never the shared package cache.
    postPatch = ''
      patch -d "$cargoDepsCopy" -p1 < ${kioskSource}/slint-kms.patch
      cp ${kioskSource}/kms-shadow.rs "$cargoDepsCopy/i-slint-backend-linuxkms-1.18.1/renderer/sw_shadow.rs"
      ${python3}/bin/python3 - "$cargoDepsCopy" <<'PY'
      import hashlib, json, pathlib, sys
      vendor = pathlib.Path(sys.argv[1])
      for name in ('i-slint-backend-linuxkms-1.18.1', 'i-slint-renderer-software-1.18.1'):
          directory = vendor / name
          checksum = directory / '.cargo-checksum.json'
          data = json.loads(checksum.read_text())
          if name == 'i-slint-backend-linuxkms-1.18.1':
              data['files']['renderer/sw_shadow.rs'] = ""
          for name in data['files']:
              data['files'][name] = hashlib.sha256((directory / name).read_bytes()).hexdigest()
          checksum.write_text(json.dumps(data))
      PY
    '';
    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ fontconfig libinput libxkbcommon udev seatd ];
    cargoBuildFlags = [ "--bin" "cybexos-installer" ];
    # The time zone tests read real TZif data, the same tzdata as the medium.
    env.TZDIR = "${tzdata}/share/zoneinfo";
    meta.mainProgram = "cybexos-installer";
  };
  # Slint embeds Space Grotesk and JetBrains Mono. Its fallback resolver still
  # consults Fontconfig, which the minimal medium does not configure globally.
  fonts = makeFontsConf { fontDirectories = [ dejavu_fonts.minimal ]; };
  python = python3;
in stdenvNoCC.mkDerivation {
  pname = "cybexos-installer";
  inherit version;
  src = source;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/bin $out/libexec
    cp installer/cybexos-installerd $out/libexec/cybexos-installerd
    cp desktop/quickshell/scripts/network-tool.py $out/libexec/network-tool.py
    patchShebangs $out/libexec
    makeWrapper ${screen}/bin/cybexos-installer $out/bin/cybexos-installer \
      --set-default FONTCONFIG_FILE ${fonts} \
      --set-default CYBEXOS_INSTALLER_ZOOM auto
    makeWrapper ${python}/bin/python3 $out/bin/cybexos-installerd \
      --add-flags "-B $out/libexec/cybexos-installerd" \
      --prefix PYTHONPATH : ${updater}/lib \
      --prefix PATH : ${lib.makeBinPath [ updater networkmanager coreutils iproute2 iw kbd util-linux systemd pciutils ]} \
      --set PYTHONDONTWRITEBYTECODE 1 \
      --set TZDIR ${tzdata}/share/zoneinfo \
      --set CYBEXOS_NETWORK_HELPER $out/libexec/network-tool.py
  '';
  passthru = { inherit screen updater; };
  meta = {
    license = lib.licenses.mit;
    mainProgram = "cybexos-installer";
  };
}
