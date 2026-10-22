{ lib, stdenvNoCC, python3, makeWrapper }:
let python = python3.withPackages (p: [ p.websockets ]);
in stdenvNoCC.mkDerivation {
  pname = "nerdos-hermes-bridge";
  version = "1";
  src = lib.cleanSource ../../desktop/hermes-menubar-bridge;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/lib/nerdos-hermes $out/bin
    cp -r *.py nerdos_hermes $out/lib/nerdos-hermes/
    makeWrapper ${python}/bin/python3 $out/bin/nerdos-hermes-bridge \
      --add-flags "$out/lib/nerdos-hermes/hermes_bridge.py"
  '';
  meta.license = lib.licenses.mit;
}
