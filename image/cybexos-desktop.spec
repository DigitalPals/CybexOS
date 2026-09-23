Name:           cybexos-desktop
# The packager derives Version and Release from VERSION and build provenance.
# Epoch 1 allows source-versioned packages to replace the old hardcoded 0.1.0.
Epoch:          1
Version:        0.1.0
Release:        0.1.alpha%{?dist}
Summary:        CybexOS Hyprland and Quickshell desktop
# No repository license has been selected. These are private evaluation
# artifacts; this label does not grant redistribution rights.
License:        LicenseRef-Not-Licensed
URL:            https://github.com/DigitalPals/CybexOS
Source0:        desktop.tar
BuildArch:      x86_64
AutoReqProv:    no
# Replaces the alpha package published under the project's former name.
Obsoletes:      fedora-config-desktop < %{epoch}:%{version}-%{release}
# This RPM is an intermediate container; the live ISO compresses the installed
# filesystem separately. Avoid spending minutes recompressing user toolchains.
%global _binary_payload w3.zstdio
%global _binary_filedigest_algorithm 8
Requires:       bash coreutils util-linux systemd python3
Requires:       hyprland hyprland-guiutils quickshell hypridle hyprlock hyprpolkitagent hyprsunset
Requires:       xdg-desktop-portal-hyprland xdg-desktop-portal-gtk xdg-utils
Requires:       qt6-qtwebsockets-devel qt6-qt5compat qt6-qtsvg
Requires:       qt6-qtbase qt6-qtdeclarative qt6-qtwayland
Requires:       python3-pyside6 python3-websockets python3-gobject
Requires:       kitty firefox nautilus jq curl NetworkManager iw qrencode iproute iputils
Requires:       pipewire pipewire-pulseaudio wireplumber bluez brightnessctl playerctl
Requires:       gnome-keyring polkit dbus-daemon dnf5-plugins flatpak sudo
Requires:       gnome-online-accounts evolution-data-server gnome-control-center zenity
Requires:       grim slurp satty wl-clipboard cliphist wf-recorder libnotify
Requires:       ImageMagick tesseract tesseract-langpack-eng btop matugen
Requires:       btrfs-progs tar zstd fastfetch
Requires:       rsms-inter-fonts google-noto-sans-fonts google-noto-color-emoji-fonts
Requires:       jetbrains-mono-fonts

%description
CybexOS (Cybex Opinionated System) is a Hyprland and Quickshell desktop for Fedora.
Shared desktop defaults, session services, and first-login welcome application.
Personal settings and overrides remain in each user's home directory.
Private alpha image integration; not a public distribution release.

%prep
%setup -q -c -n desktop

%build

# Bundled upstream binaries must retain the bytes their installers verified.
%global __os_install_post %{nil}
%global debug_package %{nil}

%install
mkdir -p %{buildroot}
cp -a usr opt etc %{buildroot}/

%files
%config(noreplace) /etc/yum.repos.d/cybexos-desktop.repo
/opt/cybexos-apps/
/opt/cybexos-builds/
/usr/local/bin/*
/usr/local/libexec/*
/usr/local/share/fonts/*
/usr/local/share/applications/omawrite.desktop
/usr/share/icons/hicolor/scalable/apps/omawrite.svg
/usr/bin/cybex
/usr/bin/cybexos-*
/usr/bin/hyprland-quickshell
/usr/libexec/cybexos-*
/usr/lib/systemd/user/*.service
/usr/lib/systemd/user/hypridle.service.d/
/usr/lib/systemd/user/hyprpolkitagent.service.d/
/usr/lib/systemd/user/voxtype.service.d/
/usr/lib/systemd/user/hyprland-session.target
/usr/share/cybexos/
/usr/share/applications/cybex.desktop
/usr/share/wayland-sessions/hyprland-quickshell.desktop
/usr/share/fonts/cybexos/
/usr/share/licenses/cybexos-fonts/
/usr/share/plymouth/themes/cybex/
/usr/lib/sysctl.d/60-cybexos-hardening.conf
/usr/lib/firewalld/zones/cybexos.xml

%changelog
* Sat Sep 05 2026 CybexOS <noreply@localhost> - 0.1.0-0.1.alpha
- Initial private live-image desktop package.
