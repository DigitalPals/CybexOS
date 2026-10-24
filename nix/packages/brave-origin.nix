{ lib, brave, fetchurl,
  # Keep the former shortcut flags in the package, so desktop-entry launches,
  # private actions and the selected-browser helper retain camera/IME support.
  commandLineArgs ? "--enable-features=TouchpadOverscrollHistoryNavigation,PipeWireCamera,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder --enable-wayland-ime --restore-last-session --hide-crash-restore-bubble"
}:
# Reuse the machine Nixpkgs Chromium wrapper, libraries and sandbox policy.
# The Origin edition is not yet selectable in that recipe. Remove this pin
# when stable Nixpkgs packages Origin; review it on every vendor release.
(brave.override { inherit commandLineArgs; }).overrideAttrs (old: {
  pname = "brave-origin";
  version = "1.97.59";
  src = fetchurl {
    url = "https://github.com/brave/brave-browser/releases/download/v1.97.59/brave-origin_1.97.59_amd64.deb";
    sha256 = "a20f953d7a12330bf6b7feaff05744cb83fcfd1fdbf7b621e39dec368775b287";
  };
  # Normalize upstream's edition-specific paths for the Nixpkgs recipe.
  postPatch = (old.postPatch or "") + ''
    mv opt/brave.com/brave-origin opt/brave.com/brave
    mv opt/brave.com/brave/brave-origin opt/brave.com/brave/brave-browser
    mv usr/share/applications/brave-origin.desktop usr/share/applications/brave-browser.desktop
    mv usr/share/applications/com.brave.Origin.desktop usr/share/applications/com.brave.Browser.desktop
    mv usr/share/gnome-control-center/default-apps/brave-origin.xml usr/share/gnome-control-center/default-apps/brave-browser.xml
    substituteInPlace usr/share/applications/{brave-browser,com.brave.Browser}.desktop \
      --replace-fail /usr/bin/brave-origin-stable /usr/bin/brave-browser-stable
    substituteInPlace opt/brave.com/brave/default-app-block \
      usr/share/gnome-control-center/default-apps/brave-browser.xml \
      --replace-fail /opt/brave.com/brave-origin /opt/brave.com/brave
  '';
  postInstall = (old.postInstall or "") + ''
    ln -s brave $out/bin/brave-origin-stable
    ln -s brave-browser.desktop $out/share/applications/brave-origin.desktop
    ln -s com.brave.Browser.desktop $out/share/applications/com.brave.Origin.desktop
    for icon in $out/share/icons/hicolor/*/apps/brave-browser.png; do
      ln -s brave-browser.png "$(dirname "$icon")/brave-origin.png"
    done
  '';
  meta = old.meta // {
    description = "Brave Origin privacy-oriented browser";
    platforms = [ "x86_64-linux" ];
  };
})
