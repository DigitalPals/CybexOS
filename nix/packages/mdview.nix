{ lib, rustPlatform, fetchFromGitHub, pkg-config, desktop-file-utils,
  wrapGAppsHook4, cairo, gdk-pixbuf, glib, glib-networking, graphene,
  gst_all_1, gsettings-desktop-schemas, gtk4, libadwaita, openssl, pango,
  webkitgtk_6_0 }:
let
  src = fetchFromGitHub {
    owner = "DigitalPals";
    repo = "mdview";
    rev = "75c72eb72ba2afbb6176e7d6e03037b6c0cdf034";
    hash = "sha256-d0pBifyuTks0DpISNDK7jGcPsDfluSV0N2t1Ue4pzC0=";
  };
in rustPlatform.buildRustPackage {
  pname = "mdview";
  version = "0.0.1";
  inherit src;
  # Keep evaluation independent of fetched derivations. This lock is copied
  # byte-for-byte from the pinned source and verified again by the build.
  cargoLock.lockFile = ./mdview-Cargo.lock;
  postPatch = ''
    cmp Cargo.lock ${./mdview-Cargo.lock}
  '';
  nativeBuildInputs = [ pkg-config desktop-file-utils wrapGAppsHook4 ];
  buildInputs = [ cairo gdk-pixbuf glib glib-networking graphene
    gst_all_1.gst-plugins-base gsettings-desktop-schemas gtk4 libadwaita
    openssl pango webkitgtk_6_0 ];
  postInstall = ''
    install -Dm0644 resources/dev.codex.mdview.desktop \
      "$out/share/applications/dev.codex.mdview.desktop"
    desktop-file-validate "$out/share/applications/dev.codex.mdview.desktop"
  '';
  meta = {
    description = "GTK Markdown viewer";
    homepage = "https://github.com/DigitalPals/mdview";
    # Matches the license declaration in upstream's pinned Nix recipe.
    license = lib.licenses.mit;
    mainProgram = "mdview";
    platforms = lib.platforms.linux;
  };
}
