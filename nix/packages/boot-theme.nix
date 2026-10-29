# The GRUB theme shared by the installation ISO and installed systems, built by
# desktop/boot/theme.py: the installer's fonts, the Plymouth wordmark, Tabler
# icons and pre-rendered static text, plus the legacy BIOS notice background.
{ lib, runCommand, grub2, resvg, python3, source, version }:
let
  # GRUB fills its terminal window with this colour while an entry loads.
  background = "#000000";
in
runCommand "cybexos-boot-theme" {
  nativeBuildInputs = [ grub2 resvg (python3.withPackages (ps: [ ps.fonttools ])) ];
  passthru = { inherit background; };
} ''
  python3 ${source + /desktop/boot/theme.py} --out $out --version ${lib.escapeShellArg version} \
    --fonts ${source + /installer/kiosk/assets/fonts} \
    --logo ${source + /desktop/plymouth/logo.png} \
    --symbol ${source + /assets/brand/symbol/svg/cybexos-symbol-on-dark.svg} \
    --icons ${source + /desktop/boot/icon-paths.json} \
    --unifont ${grub2}/share/grub/unicode.pf2
  grep -qx 'desktop-color: "${background}"' $out/theme.txt
''
