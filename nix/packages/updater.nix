{ lib, stdenvNoCC, source, python3, makeWrapper, nix, openssl, systemd, util-linux,
  coreutils, bubblewrap, cryptsetup, parted, dosfstools, e2fsprogs, btrfs-progs, gptfdisk, shadow,
  nixos-install-tools, curl, dbus, procps, bash, callPackage, quickshell, hyprland, qt6, libxcrypt }:
let desktopPackage = callPackage ./desktop.nix { inherit source; }; in
stdenvNoCC.mkDerivation {
  pname = "cybexos-updater";
  version = lib.trim (builtins.readFile (source + /VERSION));
  src = source;
  nativeBuildInputs = [ makeWrapper python3 ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/lib/cybexos $out/bin $out/share/cybexos
    cp -r lifecycle/cybexos $out/lib/
    cp -r templates/machine $out/share/cybexos/
    cp -r agent-skills/cybexos $out/share/cybexos/skill
    cp -r assets/brand $out/share/cybexos/
    ln -s ${source} $out/share/cybexos/source
    cp lifecycle/bin/* installer/cybexos-install $out/bin/
    cp -r tests/lib $out/share/cybexos/
    cp -r tests/desktop-smoke $out/share/cybexos/
    cp desktop/runtime-compatibility.json $out/share/cybexos/desktop-compatibility.json
    cat > $out/share/cybexos/desktop-runtime.json <<'RUNTIME'
    ${builtins.toJSON { quickshell = quickshell.version; qt = qt6.qtbase.version; hyprland = hyprland.version; }}
    RUNTIME
    patchShebangs $out
    for script in $out/bin/*; do
      wrapProgram "$script" --prefix PYTHONPATH : $out/lib \
        --set PYTHONDONTWRITEBYTECODE 1 \
        --set CYBEXOS_UPDATER_SHARE $out/share/cybexos \
        --set CYBEXOS_LIBCRYPT ${libxcrypt}/lib/libcrypt.so.2 \
        --prefix QML_IMPORT_PATH : ${desktopPackage.images}/lib/qt-6/qml \
        --prefix PATH : ${lib.makeBinPath [ python3 nix openssl systemd util-linux coreutils bubblewrap cryptsetup parted dosfstools e2fsprogs btrfs-progs gptfdisk shadow nixos-install-tools curl dbus procps bash quickshell hyprland desktopPackage ]} \
        --prefix PATH : "$out/bin"
    done
  '';
  doInstallCheck = stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform;
  installCheckPhase = ''
    # Dispatch must resolve sibling helpers without a system-profile PATH.
    # On a builder the helper should refuse the absent live marker cleanly.
    if env -i HOME="$TMPDIR" "$out/bin/cybex" install >dispatch.log 2>&1; then
      echo 'Installer unexpectedly accepted a non-live environment' >&2
      exit 1
    fi
    if ! grep -q 'Fresh installation is available only from the Cybex OS installation ISO' dispatch.log; then
      cat dispatch.log >&2
      exit 1
    fi
  '';
  meta.license = lib.licenses.mit;
}
