# Keep the upstream ISO layout and menu, but use canonical paths. GRUB accepts
# /boot//nix/store; iVentoy's ISO parser does not, and consequently finds no
# initrd to prepare for network boot. Patch both copies of the UEFI menu.
#
# The menu reads "Install NerdOS <version>", followed by the same installer
# with firmware graphics (nomodeset → simpledrm), the text installer on tty1,
# and a verbose diagnostic boot. Every entry starts the same fresh installer.
{ config, lib, pkgs, ... }:
let
  version = config.nerdos.release.version;
  upstreamTitle = "${config.system.nixos.distroName} ${config.system.nixos.label}";
  quiet = lib.filter (param: param != "splash" && !(lib.hasPrefix "loglevel=" param)) config.boot.kernelParams;
  entries = [
    { label = "Install NerdOS ${version} - safe graphics"; params = config.boot.kernelParams ++ [ "nomodeset" ]; }
    { label = "Install NerdOS ${version} - text mode"; params = quiet ++ [ "plymouth.enable=0" "nerdos.text" ]; }
    { label = "Verbose boot diagnostics"; params = quiet ++ [ "plymouth.enable=0" "loglevel=7" ]; }
  ];
  kernel = "/boot${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile}";
  initrd = "/boot${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
  init = "init=${config.system.build.toplevel}/init";
  grubEntries = lib.concatMapStrings (entry: ''
    menuentry '${entry.label}' --class installer {
      terminal_output gfxterm
      set gfxpayload=keep
      linux ${kernel} ''${isoboot} ${init} ${toString entry.params}
      initrd ${initrd}
    }
  '') entries;
  isolinuxEntries = lib.concatMapStrings (entry: ''
    LABEL nerdos-${toString entry.index}
    MENU LABEL ${entry.value.label}
    LINUX ${kernel}
    INITRD ${initrd}
    APPEND ${init} ${toString entry.value.params}
  '') (lib.imap0 (index: value: { inherit index value; }) entries);
  patchMenu = file: extra: ''
    substituteInPlace ${file} \
      --replace-fail '/boot//nix/store/' '/boot/nix/store/' \
      --replace-fail ${lib.escapeShellArg upstreamTitle} ${lib.escapeShellArg "NerdOS ${version}"}
  '';
in
{
  options.isoImage.contents = lib.mkOption {
    apply = contents:
      let
        efi = lib.findFirst (item: item.target == "/EFI") null contents;
        canonicalEfi = pkgs.runCommand "nerdos-iso-efi" {} ''
          mkdir -p $out
          cp -r ${efi.source}/. $out/
          chmod -R u+w $out
          ${patchMenu "$out/BOOT/grub.cfg" ""}
          # Offer the alternatives right below the default entry.
          entries=${pkgs.writeText "nerdos-grub-entries.cfg" grubEntries}
          awk -v entries="$entries" '
            /^[[:space:]]*submenu "Options"/ && !done { while ((getline line < entries) > 0) print line; done = 1 }
            { print }
            END { if (!done) exit 3 }
          ' $out/BOOT/grub.cfg > grub.cfg
          mv grub.cfg $out/BOOT/grub.cfg
        '';
      in map (item:
        if item.target == "/isolinux/isolinux.cfg" then item // {
          source = pkgs.runCommand "nerdos-isolinux.cfg" {} ''
            cp ${item.source} $out
            chmod u+w $out
            ${patchMenu "$out" ""}
            cat ${pkgs.writeText "nerdos-isolinux-entries.cfg" isolinuxEntries} >> $out
          '';
        } else if item.target == "/EFI" then item // {
          source = canonicalEfi;
        } else if item.target == "/boot/efi.img" then item // {
          source = pkgs.runCommand "nerdos-iso-efi.img" {
            nativeBuildInputs = [ pkgs.mtools pkgs.dosfstools ];
          } ''
            cp ${item.source} $out
            chmod u+w $out
            cp ${canonicalEfi}/BOOT/grub.cfg grub.cfg
            touch --date=2000-01-01 grub.cfg
            mcopy -om -i $out grub.cfg ::/EFI/BOOT/grub.cfg
            fsck.vfat -vn $out
          '';
        } else item
      ) contents;
  };
}
