{ lib, runCommand, fetchurl, unzip }:
let data = builtins.fromJSON (builtins.readFile ../../desktop/fonts.json);
in runCommand "cybexos-fonts" { nativeBuildInputs = [ unzip ]; } (''
  mkdir -p $out/share/fonts/truetype $out/share/licenses/cybexos-fonts
'' + lib.concatMapStrings (font: ''
  cp ${fetchurl { inherit (font) url; sha256 = lib.removePrefix "sha256:" font.checksum; }} "$out/share/fonts/truetype/${font.filename}"
'' + lib.optionalString (font ? license_url) ''
  cp ${fetchurl { url = font.license_url; sha256 = lib.removePrefix "sha256:" font.license_checksum; }} "$out/share/licenses/cybexos-fonts/${font.name}.txt"
'') data.files + lib.concatMapStrings (font: ''
  unzip -q ${fetchurl { inherit (font) url; sha256 = lib.removePrefix "sha256:" font.checksum; }} -d ${font.name}
  cp "${font.name}/${font.expected_font}" "$out/share/fonts/truetype/${font.name}.ttf"
'') data.archives)
