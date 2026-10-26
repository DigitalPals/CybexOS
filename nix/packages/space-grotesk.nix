# Space Grotesk for the desktop, from the installer's vendored copy
# (installer/kiosk/assets/fonts; provenance and checksums in its README), so
# the welcome guide sets type in the same face as the installer.
{ lib, runCommand }:
let fonts = ../../installer/kiosk/assets/fonts;
in runCommand "cybexos-space-grotesk" { } ''
  install -Dm444 -t $out/share/fonts/truetype \
    ${fonts}/SpaceGrotesk-Regular.ttf ${fonts}/SpaceGrotesk-Medium.ttf ${fonts}/SpaceGrotesk-Bold.ttf
  install -Dm444 ${fonts}/OFL-SpaceGrotesk.txt $out/share/licenses/cybexos-space-grotesk/OFL.txt
''
