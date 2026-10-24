{ lib, stdenvNoCC, source }:
stdenvNoCC.mkDerivation {
  pname = "cybexos-plymouth";
  version = lib.trim (builtins.readFile (source + /VERSION));
  src = source + /desktop/plymouth;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    theme=$out/share/plymouth/themes/cybexos
    mkdir -p "$theme"
    cp *.png cybexos.script cybexos.plymouth "$theme/"
    substituteInPlace "$theme/cybexos.plymouth" \
      --replace-fail /usr/share/plymouth/themes/cybexos "$theme"
    runHook postInstall
  '';
  meta = { description = "Cybex OS boot splash and encrypted-disk unlock theme"; license = lib.licenses.mit; platforms = lib.platforms.linux; };
}
