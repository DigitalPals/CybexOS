{ lib, stdenvNoCC, source, updater, python3, makeWrapper, qt6 }:
let python = python3.withPackages (p: [ p.pyside6 ]); in
stdenvNoCC.mkDerivation {
  pname = "cybexos-password";
  version = lib.trim (builtins.readFile (source + /VERSION));
  src = source;
  nativeBuildInputs = [ makeWrapper qt6.wrapQtAppsHook ];
  buildInputs = [ qt6.qtbase ];
  dontWrapQtApps = true;
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/bin $out/libexec
    cp desktop/password/cybexos-password.py $out/libexec/
  '';
  preFixup = ''
    makeWrapper ${python}/bin/python3 $out/bin/cybexos-password \
      "''${qtWrapperArgs[@]}" \
      --add-flags "$out/libexec/cybexos-password.py" \
      --set CYBEXOS_PASSWORD_WORKER ${updater}/bin/cybexos-password-worker \
      --set PYTHONDONTWRITEBYTECODE 1
  '';
  meta.license = lib.licenses.mit;
}
