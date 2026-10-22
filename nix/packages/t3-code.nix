# T3 Code's desktop is not in the selected stable Nixpkgs. Keep the connected
# widget's supported desktop client exact and immutable; review its release and
# bar API together. Replace with Nixpkgs when an equivalent package is available.
{ lib, appimageTools, fetchurl, makeDesktopItem }:
let
  pname = "t3code-desktop";
  version = "0.1.2-nightly.20261022.3512";
  # Upstream source: 3b95e7831b11b17627dff16843bc087bfca397ec.
  src = fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${version}/T3-Code-${version}-x86_64.AppImage";
    sha256 = "cdda407bf1bdff08f6de5d939f451ea83b8bb927332b669fe00cda8b15b7eea3";
  };
  contents = appimageTools.extractType2 { inherit pname version src; };
  desktop = makeDesktopItem {
    name = "t3code-nightly";
    desktopName = "T3 Code";
    exec = "t3code-desktop %U";
    terminal = false;
    categories = [ "Development" ];
    mimeTypes = [ "x-scheme-handler/t3code" ];
    icon = "t3code";
  };
in appimageTools.wrapType2 {
  inherit pname version src;
  extraInstallCommands = ''
    mkdir -p $out/share/applications $out/share/icons/hicolor/512x512/apps
    cp ${desktop}/share/applications/* $out/share/applications/
    icon=$(find ${contents} -name '*.png' -not -path '*/node_modules/*' | head -1)
    test -z "$icon" || cp "$icon" $out/share/icons/hicolor/512x512/apps/t3code.png
  '';
  meta = {
    description = "T3 Code connected desktop client";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = pname;
  };
}
