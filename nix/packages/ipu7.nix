# Narrow hardware source pins: Intel's IPU7 userspace and missing PSYS/CVS
# companions are absent from Nixpkgs 26.05. Requalify on each kernel/HAL update;
# remove these derivations when upstream supplies an equivalent processed path.
{ lib, stdenv, fetchurl, cmake, pkg-config, autoPatchelfHook, autoreconfHook,
  patchelf, expat, jsoncpp, libtool, gst_all_1, libdrm, kernel }:
let
  fetch = repo: revision: hash: fetchurl {
    name = "${repo}-${revision}.tar.gz";
    url = "https://github.com/intel/${repo}/archive/${revision}.tar.gz";
    sha256 = hash;
  };
  bins = stdenv.mkDerivation {
    pname = "ipu75xa-camera-bins"; version = "403c67d";
    src = fetch "ipu7-camera-bins" "403c67db6b279dd02752f11db6a34552f31a3ac5" "faf152bde831a7f1da7b1c2bbd1bb97ea6ae0e487ec55e9e09d4faa88b5259e8";
    nativeBuildInputs = [ autoPatchelfHook ];
    buildInputs = [ stdenv.cc.cc.lib ];
    installPhase = ''
      mkdir -p $out/lib/pkgconfig $out/include
      cp -a lib/*ipu75xa.so* $out/lib/
      cp -r include/ipu75xa $out/include/
      cp lib/pkgconfig/ia_imaging-ipu75xa.pc $out/lib/pkgconfig/
      substituteInPlace $out/lib/pkgconfig/ia_imaging-ipu75xa.pc \
        --replace-fail /usr "$out"
    '';
  };
  hal = stdenv.mkDerivation {
    pname = "ipu7-camera-hal"; version = "b1f6ebe";
    src = fetch "ipu7-camera-hal" "b1f6ebef12111fb5da0133b144d69dd9b001836c" "6f20aa7d435ec3f106987eb376a34ee290d73cdbbedcb7e91f4b9a2ec53dfe32";
    patches = [ ../../hardware/xps/camera/patches/0006-camera-hal-native-cvs-bridge.patch ];
    nativeBuildInputs = [ cmake pkg-config patchelf ];
    buildInputs = [ bins expat jsoncpp libtool gst_all_1.gstreamer gst_all_1.gst-plugins-base libdrm ];
    cmakeFlags = [ "-DCMAKE_INSTALL_LIBDIR=lib" "-DCMAKE_INSTALL_SYSCONFDIR=etc"
      "-DBUILD_CAMHAL_ADAPTOR=ON" "-DBUILD_CAMHAL_PLUGIN=ON" "-DIPU_VERSIONS=ipu75xa"
      "-DUSE_STATIC_GRAPH=ON" "-DUSE_STATIC_GRAPH_AUTOGEN=ON" "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];
    env.NIX_CFLAGS_COMPILE = "-Wno-error";
    postPatch = ''
      # jsoncpp 1.9.7's public ABI uses string_view under C++17. Compile
      # consumers in that mode rather than asking for removed char* symbols.
      substituteInPlace CMakeLists.txt \
        --replace-fail 'set (CMAKE_CXX_STANDARD 11)' 'set (CMAKE_CXX_STANDARD 17)'
      # Nixpkgs exposes jsoncpp headers through its pkg-config include root.
      substituteInPlace src/platformdata/JsonParserBase.h \
        --replace-fail '<jsoncpp/json/json.h>' '<json/json.h>'
      substituteInPlace src/platformdata/PlatformData.h \
        --replace /usr/share/ "$out/share/" \
        --replace /etc/camera/ "$out/etc/camera/"
    '';
    postFixup = ''
      for file in $out/lib/*.so*; do
        test -L "$file" || patchelf --add-rpath ${bins}/lib "$file"
      done
    '';
    postInstall = ''
      # Intel's template prepends prefix to GNUInstallDirs' absolute paths.
      find $out -name '*.pc' -exec sed -i 's|''${prefix}//nix/store/|/nix/store/|g' {} \;
    '';
  };
  sensor = stdenv.mkDerivation {
    pname = "icamerasrc-ipu7"; version = "4fb31db";
    src = fetch "icamerasrc" "4fb31db76b618aae72184c59314b839dedb42689" "1bd86ee776dd1f9c0f2bb9761ecb82bd2aa3b42c067cd2fafcadb0137388464c";
    nativeBuildInputs = [ autoreconfHook pkg-config ];
    buildInputs = [ hal bins gst_all_1.gstreamer gst_all_1.gst-plugins-base ];
    CHROME_SLIM_CAMHAL = "ON";
    preConfigure = ''
      # The plugin uses GstVideoMeta directly; upstream's configure only asks
      # for gstreamer-core and misses the split video header/library output.
      export CPPFLAGS="$(pkg-config --cflags gstreamer-video-1.0) $CPPFLAGS"
      export LIBS="$(pkg-config --libs gstreamer-video-1.0) $LIBS"
    '';
  };
  psys = stdenv.mkDerivation {
    pname = "ipu7-psys"; version = "a88b190-${kernel.version}";
    src = fetch "ipu7-drivers" "a88b19096a738d0708742a78d6540d6d4a3021ff" "b2208f4b1b20be7ef0aea75d80ee8f8e6e4cbe559e598511688757d28a86ace0";
    patches = [ ../../hardware/xps/camera/patches/0004-ipu7-psys-register-bus.patch ../../hardware/xps/camera/patches/0005-ipu7-psys-stock-core-layout.patch ];
    nativeBuildInputs = kernel.moduleBuildDependencies;
    makeFlags = [ "KERNELRELEASE=${kernel.modDirVersion}" "KERNEL_SRC=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build" "IPU7_PSYS_ONLY=1" ];
    installPhase = ''
      mkdir -p $out/lib/modules/${kernel.modDirVersion}/extra
      find . -name 'intel-ipu7-psys.ko' -exec cp {} $out/lib/modules/${kernel.modDirVersion}/extra/ \;
      test -n "$(find $out -name '*.ko')"
    '';
  };
in { inherit bins hal sensor psys; }
