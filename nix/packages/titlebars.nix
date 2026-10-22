{ lib, hyprland, hyprlandPlugins, fetchurl, cmake, binutils }:
hyprlandPlugins.mkHyprlandPlugin {
  pluginName = "nerdos-titlebars";
  version = "0.2.2";
  inherit hyprland;
  src = fetchurl {
    name = "omarchy-titlebars-379ff91.tar.gz";
    url = "https://codeload.github.com/omacom/omarchy-hyprland-titlebars/tar.gz/379ff910fcce9f0cc9b41f9a87c527997076a417";
    sha256 = "a453ae6b0a39f75e9a559a0258746e7df24a9432d5571ce505501cd0a333aa72";
  };
  patches = [ ../../desktop/hypr/titlebars-native.patch ];
  nativeBuildInputs = [ cmake binutils ];
  preConfigure = ''
    # Nixpkgs' public binary is a Qt wrapper. The guard identifies the actual
    # compositor ELF, built with the same derivation and headers as this plugin.
    compositor=${hyprland}/bin/.Hyprland-wrapped
    test -e "$compositor" || compositor=${hyprland}/bin/Hyprland
    build_id=$(readelf -n "$compositor" | sed -n 's/.*Build ID: //p')
    test -n "$build_id"
    cmakeFlagsArray+=("-DNERDOS_HYPRLAND_BUILD_ID=$build_id")
  '';
  meta = { license = [ lib.licenses.mit lib.licenses.bsd3 ]; };
}
