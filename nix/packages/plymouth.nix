{ lib, stdenvNoCC, source }:
stdenvNoCC.mkDerivation {
  pname = "nerdos-plymouth";
  version = lib.trim (builtins.readFile (source + /VERSION));
  src = source + /desktop/plymouth;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    theme=$out/share/plymouth/themes/nerdos
    mkdir -p "$theme"
    cp *.png nerdos.script nerdos.plymouth "$theme/"
    substituteInPlace "$theme/nerdos.plymouth" \
      --replace-fail /usr/share/plymouth/themes/nerdos "$theme"
    runHook postInstall
  '';
  meta = { description = "NerdOS boot splash and encrypted-disk unlock theme"; license = lib.licenses.mit; platforms = lib.platforms.linux; };
}
