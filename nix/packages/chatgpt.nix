# Nixpkgs' chatgpt currently packages only the macOS application. This is the
# official Linux preview, pinned to the versioned Debian pool object. Replace
# this recipe with a maintained native Nixpkgs package after runtime review.
# Source SHA-256 was verified against OpenAI's signed APT InRelease/Packages,
# key fingerprint 3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4, on 2026-10-22.
{ lib, stdenv, fetchurl, dpkg, autoPatchelfHook, makeWrapper, wrapGAppsHook3,
  alsa-lib, at-spi2-atk, at-spi2-core, atk, cairo, coreutils, cups, dbus, expat,
  gdk-pixbuf, glib, gtk3, libgbm, libGL, libnotify, libusb1, libxkbcommon, nspr,
  nss, openssl, pango, qt5, qt6, systemd, tpm2-tss, vulkan-loader, xdg-utils,
  libX11, libXcomposite, libXdamage, libXext, libXfixes, libXrandr, libxcb }:
stdenv.mkDerivation (finalAttrs: {
  pname = "chatgpt-linux";
  version = "26.1016.61520";
  src = fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${finalAttrs.version}_amd64.deb";
    hash = "sha256-mt1iKRbF+jhhr9lQga934lSIwQjKnFQ+H2dWCzkNKNQ=";
  };
  nativeBuildInputs = [ dpkg autoPatchelfHook makeWrapper wrapGAppsHook3 ];
  buildInputs = [
    alsa-lib at-spi2-atk at-spi2-core atk cairo cups dbus expat gdk-pixbuf glib
    gtk3 libgbm libGL libnotify libusb1 libxkbcommon nspr nss openssl pango
    # These are optional upstream runtime shims, not a mixed-major Qt source
    # build. Use only library outputs, without either Qt development hook.
    qt5.qtbase.out qt6.qtbase.out stdenv.cc.cc.lib systemd tpm2-tss vulkan-loader
    libX11 libXcomposite libXdamage libXext libXfixes libXrandr libxcb
  ];
  # Chromium also dlopens these; preserve sandboxing and use the installed GPU
  # drivers. No --no-sandbox/setuid workaround is applied.
  runtimeDependencies = [ libGL libgbm libnotify openssl systemd vulkan-loader ];
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --extract "$src" .
    runHook postUnpack
  '';
  dontConfigure = true;
  dontBuild = true;
  dontWrapGApps = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib" "$out/bin" "$out/share"
    cp -r usr/lib/chatgpt "$out/lib/"
    cp -r usr/share/. "$out/share/"
    # The application ships glibc and musl alternatives for two optional node
    # backends. NixOS uses glibc; retain all native glibc implementations and
    # remove the unreachable x86_64-musl alternatives before ELF validation.
    find "$out/lib/chatgpt/resources" -type d \
      \( -name HID-linux-x64-musl -o -name HID_hidraw-linux-x64-musl \) \
      -prune -exec rm -rf {} +
    find "$out/lib/chatgpt/resources" -type f -name node.napi.musl.node -delete
    substituteInPlace "$out/share/applications/chatgpt.desktop" \
      --replace-fail 'Exec=chatgpt %U' "Exec=$out/bin/chatgpt --ozone-platform=wayland %U"
    runHook postInstall
  '';
  preFixup = ''
    makeWrapper "$out/lib/chatgpt/ChatGPT" "$out/bin/chatgpt" \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : ${lib.makeBinPath [ coreutils xdg-utils ]}
    addAutoPatchelfSearchPath "$out/lib/chatgpt"
  '';
  passthru.appArmorProfile = ''
    abi <abi/4.0>,
    include <tunables/global>
    profile chatgpt "${finalAttrs.finalPackage}/lib/chatgpt/ChatGPT" flags=(unconfined) {
      userns,
      include if exists <local/chatgpt>
    }
  '';
  meta = {
    description = "Official ChatGPT Linux desktop preview";
    homepage = "https://developers.openai.com/codex/linux/linux-app";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "chatgpt";
  };
})
