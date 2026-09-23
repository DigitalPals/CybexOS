%global debug_package %{nil}
%global __os_install_post %{nil}

Name:           xps-ipu7-camera-stack
Version:        @BUNDLE_VERSION@
Release:        1.xps@INPUT_RELEASE@%{?dist}
Summary:        Pinned Panther Lake IPU7 PSYS/CVS and camera userspace extension
License:        GPL-2.0-only AND Apache-2.0 AND LGPL-2.1-or-later AND LicenseRef-Intel-Binary
URL:            https://github.com/DigitalPals/CybexOS
Source0:        xps-ipu7-camera-stack.tar.gz
BuildArch:      x86_64
AutoReqProv:    no
Requires:       dkms
Requires:       expat
Requires:       jsoncpp
Requires:       libdrm
Requires:       gstreamer1
Requires:       gstreamer1-plugins-base

%description
The Fedora-specific extension required to expose the OVTI08F4/OV08X40 camera
on the 2026 Dell XPS. Fedora's stock kernel continues to supply IPU7 base/ISYS,
the sensor driver, ACPI bridge, and firmware. This package carries only pinned
PSYS and CVS DKMS sources plus the Intel HAL, binary interface, and icamerasrc.

%prep

%build

%install
mkdir -p %{buildroot}
tar -xzf %{SOURCE0} -C %{buildroot}

%files
/etc/camera/ipu75xa
/usr/lib64/libcamhal.so*
/usr/lib64/libcamhal
/usr/lib64/libia_*-ipu75xa.so*
/usr/lib64/libgsticamerainterface-1.0.so*
/usr/lib64/gstreamer-1.0/libgsticamerasrc.so*
/usr/src/ipu7-drivers-@DKMS_VERSION@
/usr/src/vision-drivers-@DKMS_VERSION@
/usr/share/xps-ipu7-camera-stack/input-manifest
%license /usr/share/licenses/xps-ipu7-camera-stack

%changelog
* Wed Aug 19 2026 DigitalPals <noreply@digitalpals.nl> - @BUNDLE_VERSION@-1
- Fedora 44 Panther Lake camera extension with pinned upstream inputs
