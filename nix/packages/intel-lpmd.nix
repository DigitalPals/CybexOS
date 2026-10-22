# Nixpkgs 26.05 has no LPMd package. This narrow hardware pin restores Intel's
# Panther Lake active-idle policy. Review new upstream releases and XPS power /
# suspend behavior on each supported NixOS kernel update; drop the recipe when
# Nixpkgs supplies the maintained package. It never pins another Nixpkgs tree.
{ lib, stdenv, fetchurl, autoreconfHook, pkg-config, autoconf-archive, gtk-doc,
  glib, libxml2, libnl, systemd, upower }:
stdenv.mkDerivation {
  pname = "intel-lpmd";
  version = "0.1.0";
  src = fetchurl {
    url = "https://github.com/intel/intel-lpmd/archive/956df747e56aca1739b39bff8cff77e81758af9a.tar.gz";
    sha256 = "0sj0q0bnlih78v0rmdh9dqsa49smckwrpmxivjg6wn9w1rh3lqfp";
  };
  nativeBuildInputs = [ autoreconfHook pkg-config autoconf-archive gtk-doc glib.dev ];
  buildInputs = [ glib libxml2 libnl systemd upower ];
  configureFlags = [
    "--sysconfdir=/etc" "--localstatedir=/var"
    "--with-systemdsystemunitdir=${placeholder "out"}/lib/systemd/system"
    "--with-dbus-sys-dir=${placeholder "out"}/share/dbus-1/system.d"
  ];
  installFlags = [ "sysconfdir=${placeholder "out"}/etc" "lpmd_confdir=${placeholder "out"}/etc/intel_lpmd" ];
  meta = {
    description = "Intel Low Power Mode Daemon with Panther Lake support";
    homepage = "https://github.com/intel/intel-lpmd";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
}
