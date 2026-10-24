{ lib, stdenvNoCC, source, updater, python3, makeWrapper, qt6, polkit }:
let python = python3.withPackages (p: [ p.pyside6 ]); in
stdenvNoCC.mkDerivation {
  pname = "nerdos-password";
  version = lib.trim (builtins.readFile (source + /VERSION));
  src = source;
  nativeBuildInputs = [ makeWrapper qt6.wrapQtAppsHook ];
  buildInputs = [ qt6.qtbase ];
  dontWrapQtApps = true;
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/bin $out/libexec
    cp desktop/password/nerdos-password.py $out/libexec/
  '';
  preFixup = ''
    makeWrapper ${python}/bin/python3 $out/bin/nerdos-password \
      "''${qtWrapperArgs[@]}" \
      --add-flags "$out/libexec/nerdos-password.py" \
      --prefix PATH : ${lib.makeBinPath [ polkit ]} \
      --set NERDOS_PASSWORD_WORKER ${updater}/bin/nerdos-password-worker \
      --set PYTHONDONTWRITEBYTECODE 1
  '';
  meta.license = lib.licenses.mit;
}
