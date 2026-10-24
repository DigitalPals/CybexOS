{ lib, stdenvNoCC, python3, makeWrapper }:
stdenvNoCC.mkDerivation {
  pname = "cybexos-assistant";
  version = "1";
  src = lib.cleanSourceWith {
    src = lib.cleanSource ../../desktop/assistant;
    filter = path: type: baseNameOf path != "__pycache__";
  };
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/lib/cybexos-assistant $out/bin
    cp -r cybexos_assistant $out/lib/cybexos-assistant/
    makeWrapper ${python3}/bin/python3 $out/bin/cybexos-assistant \
      --add-flags "-m cybexos_assistant" \
      --prefix PYTHONPATH : $out/lib/cybexos-assistant \
      --set PYTHONDONTWRITEBYTECODE 1
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/cybexos-assistant --help >/dev/null
  '';
  meta.license = lib.licenses.mit;
}
