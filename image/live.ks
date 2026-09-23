# Image construction only. This kickstart is NOT passed to the GUI installer:
# disk selection and all destructive confirmations remain interactive.
lang en_US.UTF-8
keyboard us
timezone UTC --utc
rootpw --lock
authselect select sssd with-silent-lastlog --force
selinux --enforcing
firewall --enabled
services --enabled=NetworkManager,gdm,firewalld,bluetooth,docker,tailscaled --disabled=sshd
bootloader --timeout=5 --append="quiet rhgb"
part / --size=61440 --fstype=ext4

# Repository configuration, including signature verification, is supplied
# through image/compose's verified DNF adapter from image/build.repo.
# The library also requires a syntactically present Kickstart repository;
# the adapter replaces this entry with the signed DNF definitions.
repo --name=fedora --baseurl=https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/

%packages --excludedocs --exclude-weakdeps
@core
@anaconda-tools
kernel
kernel-modules
kernel-modules-extra
dracut-live
dracut-config-generic
grub2-efi-x64
grub2-efi-x64-cdboot
grub2-pc
grub2-pc-modules
shim-x64
syslinux
syslinux-extlinux
memtest86+
fedora-release-identity-basic
fedora-release-common
fedora-repos
generic-logos
generic-release-notes
anaconda-live
anaconda-webui
libblockdev-plugins-all
lvm2
mdadm
cryptsetup
gdm
cybexos-desktop
selinux-policy-targeted
policycoreutils
firewalld
NetworkManager-wifi
NetworkManager-bluetooth
iwlwifi-mvm-firmware
linux-firmware
# GPU firmware is split out of linux-firmware and must be explicit because
# weak dependencies are disabled above. Cover physical GPUs, not just QEMU.
amd-gpu-firmware
intel-gpu-firmware
nvidia-gpu-firmware
mesa-dri-drivers
mesa-vulkan-drivers
mesa-libEGL
pciutils
xorg-x11-server-Xwayland
at-spi2-core
adwaita-icon-theme
adw-gtk3-theme
glibc-all-langpacks
openssh-server
rsync
btrfs-progs
dosfstools
e2fsprogs
chrony
plymouth
plymouth-system-theme
-dracut-config-rescue
%end

%post --nochroot --erroronfail
set -eu
python3 /home/builder/source/image/install-live-rootfs "$INSTALL_ROOT"
install -Dm0644 /home/builder/build/hyprland.gpg "$INSTALL_ROOT/etc/pki/rpm-gpg/CYBEXOS-sdegler-hyprland-copr.gpg"
install -Dm0644 /home/builder/source/roles/desktop/templates/hyprland-copr.repo.j2 "$INSTALL_ROOT/etc/yum.repos.d/cybexos-hyprland.repo"
%end

%post --erroronfail
set -eu
systemctl enable cybexos-live.service
systemctl set-default graphical.target
mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf <<'GDM'
[daemon]
DefaultSession=hyprland-quickshell.desktop
[security]
[xdmcp]
[chooser]
[debug]
GDM
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/99-live.conf <<'DRACUT'
add_dracutmodules+=" dmsquash-live livenet "
hostonly="no"
DRACUT
rm -f /etc/machine-id /var/lib/dbus/machine-id
touch /etc/machine-id
rm -f /etc/ssh/ssh_host_*
dnf clean all
%end
