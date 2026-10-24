{ lib, stdenvNoCC, python3, makeWrapper }:
let python = python3.withPackages (p: [ p.websockets ]);
in stdenvNoCC.mkDerivation {
  pname = "cybexos-hermes-bridge";
  version = "1";
  src = lib.cleanSource ../../desktop/hermes-menubar-bridge;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/lib/cybexos-hermes $out/bin
    cp -r *.py cybexos_hermes $out/lib/cybexos-hermes/
    makeWrapper ${python}/bin/python3 $out/bin/cybexos-hermes-bridge \
      --add-flags "$out/lib/cybexos-hermes/hermes_bridge.py"
  '';
  meta.license = lib.licenses.mit;
}
