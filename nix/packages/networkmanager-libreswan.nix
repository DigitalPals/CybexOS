{ networkmanager-libreswan, libreswan }:
# Stable Nixpkgs 26.05's plugin recipe points at libexec/{pluto,whack}, but its
# Libreswan 5 package installs libexec/ipsec/*. Keep the
# maintained upstream plugin and correct only these native helper paths. Remove
# this override once Nixpkgs fixes them, after installed VPN qualification.
networkmanager-libreswan.overrideAttrs (old: {
  doCheck = true;
  postPatch = (old.postPatch or "") + ''
    for helper in pluto whack; do
      test -x "${libreswan}/libexec/ipsec/$helper"
      substituteInPlace src/nm-libreswan-service.c \
        --replace-fail "${libreswan}/libexec/$helper" "${libreswan}/libexec/ipsec/$helper"
    done
  '';
})
