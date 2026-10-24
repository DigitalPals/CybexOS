{ lib, stdenvNoCC, python3, makeWrapper }:
stdenvNoCC.mkDerivation {
  pname = "nerdos-assistant";
  version = "1";
  src = lib.cleanSourceWith {
    src = lib.cleanSource ../../desktop/assistant;
    filter = path: type: baseNameOf path != "__pycache__";
  };
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/lib/nerdos-assistant $out/bin
    cp -r nerdos_assistant $out/lib/nerdos-assistant/
    makeWrapper ${python3}/bin/python3 $out/bin/nerdos-assistant \
      --add-flags "-m nerdos_assistant" \
      --prefix PYTHONPATH : $out/lib/nerdos-assistant \
      --set PYTHONDONTWRITEBYTECODE 1
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/nerdos-assistant --help >/dev/null
  '';
  meta.license = lib.licenses.mit;
}
