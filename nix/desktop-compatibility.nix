# The Lua desktop and native titlebars require 0.56.2. NixOS 26.05 currently
# carries 0.55.4. Reuse Nixpkgs recipes/dependencies with only these source pins;
# remove this overlay after stable supplies >=0.56.2 and the runtime qualifies.
final: prev:
let
  lib = prev.lib;
  # Protocol XML is a build-time dependency only. Scope the newer protocol
  # set to this compositor so it cannot rebuild unrelated upstream packages.
  protocols = if lib.versionAtLeast prev.wayland-protocols.version "1.49" then prev.wayland-protocols else
    prev.wayland-protocols.overrideAttrs {
      version = "1.49";
      src = prev.fetchurl {
        name = "wayland-protocols-ee78491.tar.gz";
        url = "https://github.com/wayland-mirror/wayland-protocols/archive/ee78491a237eaff9389a0ccf8680521d074407d3.tar.gz";
        sha256 = "cc78a5bc9ec73ed286fa43d31ee2bd4dafed498e67833c2bef9650eff3de2363";
      };
    };
  utils = if lib.versionAtLeast prev.hyprutils.version "0.14.0" then prev.hyprutils else
    prev.hyprutils.overrideAttrs {
      version = "0.14.0";
      src = prev.fetchurl {
        name = "hyprutils-5f03477.tar.gz";
        url = "https://github.com/hyprwm/hyprutils/archive/5f03477ab3a005ff27c527486f551883535aea2f.tar.gz";
        hash = "sha256-i9ztYXNW7eS6O1Qs8cukX7XYWyJAW0tLSokj1eu8lxw=";
      };
    };
  lang = prev.hyprlang.override { hyprutils = utils; };
  graphics = prev.hyprgraphics.override { hyprutils = utils; };
  cursor = prev.hyprcursor.override { hyprlang = lang; };
  wire = prev.hyprwire.override { hyprutils = utils; };
  # hyprutils 0.14 deliberately made smart-pointer boolean conversion explicit.
  # Keep the stable Aquamarine recipe; adapt its two boolean returns without
  # changing their meaning. Drop this patch when the upstream recipe does so.
  aquamarine = if lib.versionAtLeast prev.aquamarine.version "0.12.0" then prev.aquamarine.override { hyprutils = utils; } else
    (prev.aquamarine.override { hyprutils = utils; }).overrideAttrs (old: {
      patches = (old.patches or []) ++ [ ./patches/aquamarine-explicit-bool.patch ];
      postPatch = (old.postPatch or "") + ''
        # The test logger streamed CSharedPointer, whose ostream API was removed.
        # Compare/print raw pointer identities and keep all assertions enabled.
        substituteInPlace tests/Attachments.cpp \
          --replace-fail 'EXPECT(attachments.get<CFooAttachment>(), nullptr)' 'EXPECT(attachments.get<CFooAttachment>().get(), nullptr)' \
          --replace-fail 'EXPECT(attachments.get<CBarAttachment>(), nullptr)' 'EXPECT(attachments.get<CBarAttachment>().get(), nullptr)' \
          --replace-fail 'EXPECT(attachments.get<CFooAttachment>(), foo)' 'EXPECT(attachments.get<CFooAttachment>().get(), foo.get())'
      '';
    });
in {
  # Our idle policy uses conditional listeners and battery retries introduced
  # in 0.1.8. This release also fixes --config on a fresh account without a
  # default hypridle.conf. Keep stable's dependencies and recipe.
  hypridle = if lib.versionAtLeast prev.hypridle.version "0.1.8" then prev.hypridle else
    prev.hypridle.overrideAttrs (old: {
      version = "0.1.8";
      src = prev.fetchFromGitHub {
        owner = "hyprwm"; repo = "hypridle";
        rev = "e5c01af0842bd66617f7004568df9406111d6e80";
        hash = "sha256-Wi8kgoWStgYopfjEmHZWsAG7Gkghr9RGFjYLVmxSKpQ=";
      };
      meta = old.meta // { changelog = "https://github.com/hyprwm/hypridle/releases/tag/v0.1.8"; };
    });
  # Do not force the newer C++ utility ABI onto unrelated stable programs
  # (portal, lock screen, etc.). Only the compositor/backend need this pin.
  hyprland = if lib.versionAtLeast prev.hyprland.version "0.56.2" then prev.hyprland else (prev.hyprland.override {
    wayland-protocols = protocols; hyprutils = utils; inherit aquamarine;
    hyprlang = lang; hyprgraphics = graphics; hyprcursor = cursor; hyprwire = wire;
  }).overrideAttrs (old: {
    version = "0.56.2";
    src = prev.fetchFromGitHub {
      owner = "hyprwm"; repo = "Hyprland";
      rev = "efb50993780079460b0cbed1363e2166a2de1d9f";
      fetchSubmodules = true;
      hash = "sha256-jOcfiv+Zs2iz5oTIQcJXZ0+5MfqW0oLgGxD0cKdmXpE=";
    };
    postPatch = (old.postPatch or "") + ''
      # GCC 15's standard library lacks ranges::starts_with. Use its equivalent
      # prefix mismatch comparison; keep the compositor on Nixpkgs' toolchain.
      substituteInPlace src/helpers/MiscFunctions.cpp --replace-fail \
        'std::ranges::starts_with(str_view, prefixes)' \
        '(std::ranges::mismatch(str_view, prefixes).in2 == std::ranges::end(prefixes))' 
    '';
    buildInputs = old.buildInputs ++ [ prev.libei prev.readline ];
    meta = old.meta // { changelog = "https://github.com/hyprwm/Hyprland/releases/tag/v0.56.2"; };
    env = old.env // {
      GIT_BRANCH = "v0.56.2"; GIT_TAG = "v0.56.2";
      GIT_COMMIT_HASH = "efb50993780079460b0cbed1363e2166a2de1d9f";
      GIT_COMMIT_MESSAGE = "Pinned upstream v0.56.2 release";
      GIT_COMMIT_DATE = "2026-08-05";
    };
  });
}
