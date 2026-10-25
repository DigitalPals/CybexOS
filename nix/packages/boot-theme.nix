# The GRUB menu theme shared by the installation ISO and installed systems.
# The logo is shared with Plymouth; GRUB's own Unifont renders the entries.
{ lib, runCommand, grub2, source }:
let
  theme = source + /desktop/boot/theme.txt;
  desktop = lib.findFirst (lib.hasPrefix "desktop-color:") null (lib.splitString "\n" (builtins.readFile theme));
in
runCommand "cybexos-boot-theme" {
  # GRUB clears its text window to this colour while an entry loads.
  passthru.background = builtins.head (builtins.match ''desktop-color: "(#[0-9A-Fa-f]{6})"'' desktop);
} ''
  mkdir -p $out
  cp ${theme} $out/theme.txt
  cp ${source + /desktop/plymouth/logo.png} $out/logo.png
  cp ${grub2}/share/grub/unicode.pf2 $out/unicode.pf2
''
