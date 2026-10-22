{ lib, stdenv, fetchurl, qt6 }:
stdenv.mkDerivation {
  pname = "omawrite"; version = "0.5.0";
  src = fetchurl {
    name = "omawrite-source.tar.gz";
    url = "https://codeload.github.com/omacom/omawrite/tar.gz/8f98892b26768236b2c20f4e637cf4b102d898bf";
    sha256 = "7277c05472930f15a5b13842a88260b0abe3a26bb0e7db9f9c852681e515842e";
  };
  nativeBuildInputs = [ qt6.qmake qt6.wrapQtAppsHook ];
  buildInputs = [ qt6.qtbase qt6.qtdeclarative qt6.qtwayland ];
  installPhase = ''
    mkdir -p $out/bin $out/share/applications
    cp omawrite $out/bin/
    find . -name '*.desktop' -exec cp {} $out/share/applications/ \;
  '';
  meta.license = lib.licenses.gpl3Only;
}
