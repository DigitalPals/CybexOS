# The installation medium's boot menus.
#
# UEFI keeps NixOS's GRUB header, which finds the medium, sets the video mode
# and theme, and offers its text-mode menu ('t'). Cybex OS replaces the
# entries: install, install with basic graphics, start an installed Cybex OS
# (only when GRUB finds one, e.g. a USB stick left plugged in),
# troubleshooting, firmware settings and shut down. Every installer entry
# starts the same fresh installer. The theme's row variants match the entries.
#
# Legacy BIOS cannot install, so isolinux explains how to start in UEFI mode.
#
# Kernel and initrd paths are canonical. GRUB accepts /boot//nix/store; iVentoy's
# ISO parser does not, and consequently finds no initrd to prepare for network
# boot. Both copies of the UEFI menu carry the same file.
{ config, lib, pkgs, ... }:
let
  theme = config.cybexos.bootTheme;
  themes = "($root)/EFI/BOOT/grub-theme";
  params = config.boot.kernelParams;
  quiet = lib.filter (param: param != "splash" && !(lib.hasPrefix "loglevel=" param)) params;
  diagnostic = lib.filter (param: param != "quiet" && param != "vt.global_cursor_default=0"
    && !(lib.any (prefix: lib.hasPrefix prefix param)
      [ "udev.log_level=" "rd.udev.log_level=" "systemd.show_status=" "rd.systemd.show_status=" ])) quiet;
  kernel = "/boot${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile}";
  initrd = "/boot${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
  init = "init=${config.system.build.toplevel}/init";
  installed = "/EFI/CybexOS/grub${pkgs.stdenv.hostPlatform.efiArch}.efi";
  memtest = config.boot.loader.grub.memtest86;
  # The theme stays drawn while the entry loads; gfxpayload keeps the mode for
  # the kernel's framebuffer and Plymouth.
  entry = title: class: extra: ''
    menuentry '${title}' --class ${class} {
      terminal_output gfxterm
      set gfxpayload=keep
      linux ${kernel} ''${isoboot} ${init} ${toString extra}
      initrd ${initrd}
    }
  '';
  rotations = [
    { title = "Rotate clockwise"; fbcon = 1; degrees = 90; }
    { title = "Upside down"; fbcon = 2; degrees = 180; }
    { title = "Rotate counter-clockwise"; fbcon = 3; degrees = 270; }
  ];
  troubleshooting = [
    (entry "Show all boot messages" "log" (diagnostic ++ [
      "plymouth.enable=0" "loglevel=7" "systemd.show_status=true" "rd.systemd.show_status=true"
    ]))
    (entry "Install in text mode" "terminal" (quiet ++ [ "plymouth.enable=0" "cybexos.text" ]))
    # The medium's store is about 7 GB.
    (entry "Run from memory  (16 GB RAM or more)" "usb" (params ++ [ "copytoram" ]))
    # The last console= is /dev/console.
    (entry "Serial console  (ttyS0, 115200)" "serial" (params ++ [ "console=ttyS0,115200n8" ]))
    # The console and the graphical installer (cybexos.rotate, see the kiosk).
    ''
      submenu 'Rotate the screen  ›' --class rotate {
        set theme=${themes}/rotate.txt
        ${lib.concatMapStrings (r: entry r.title "rotate" (params ++ [ "fbcon=rotate:${toString r.fbcon}" "cybexos.rotate=${toString r.degrees}" ])) rotations}
      }
    ''
  ] ++ lib.optional memtest.enable ''
    menuentry 'Memory test  (Memtest86+)' --class memtest {
      linux ($root)/boot/memtest.bin ${toString memtest.params}
    }
  '';
  grubEntries = ''
    # Submenus see only exported variables.
    export isoboot
    if [ "$textmode" == "false" ]; then
      # The theme's colour, not black, fills GRUB's text window while loading.
      background_color '${theme.background}'
    fi
    set theme=${themes}/installer-5.txt
    ${entry "Install Cybex OS" "installer" params}
    ${entry "Install with basic graphics" "basic" (params ++ [ "nomodeset" ])}
    # The installer's ESP is partition 1. A false test prints nothing; a
    # failed search would print an error over the menu.
    for disk in hd0 hd1 hd2 hd3 hd4 hd5 hd6 hd7 hd8 hd9; do
      if [ -z "$cybexos_installed" ]; then
        if [ -f ($disk,gpt1)${installed} ]; then
          set cybexos_installed=$disk,gpt1
        fi
      fi
    done
    if [ -n "$cybexos_installed" ]; then
      export cybexos_installed
      set theme=${themes}/installer-6.txt
      menuentry 'Start Cybex OS on this computer' --class disk {
        # GRUB 2.12 gives a chainloaded image $root as its device, not the
        # file's, and the installed loader finds its ESP from that.
        set root=$cybexos_installed
        chainloader ${installed}
      }
    fi
    submenu 'Troubleshooting  ›' --class troubleshoot {
      set theme=${themes}/troubleshooting-${toString (builtins.length troubleshooting)}.txt
      ${lib.concatStrings troubleshooting}
    }
    ${builtins.readFile ../../desktop/boot/closing.cfg}
  '';
  # vesamenu draws only these entries over the theme's pre-rendered notice.
  isolinuxCfg = ''
    SERIAL 0 115200
    UI vesamenu.c32
    TIMEOUT 0
    DEFAULT restart
    MENU BACKGROUND /isolinux/background.png
    MENU RESOLUTION 800 600
    MENU CLEAR
    MENU TITLE
    MENU ROWS 3
    MENU WIDTH 40
    MENU MARGIN 4
    # Centred on the 100-column, 8×16-cell grid of 800×600.
    MENU VSHIFT 18
    MENU HSHIFT 29
    MENU TABMSG
    MENU CMDLINEROW 30
    MENU COLOR BORDER       0  #00000000 #00000000 none
    MENU COLOR SCREEN       0  #00000000 #00000000 none
    MENU COLOR TITLE        0  #00000000 #00000000 none
    MENU COLOR UNSEL        0  #ffe4e3dd #00000000 none
    MENU COLOR SEL          0  #ff1a1b1e #ff60a5fa none
    MENU COLOR TABMSG       0  #00000000 #00000000 none
    MENU COLOR CMDMARK      0  #ff9a9c95 #00000000 none
    MENU COLOR CMDLINE      0  #ffe4e3dd #00000000 none

    LABEL restart
      MENU LABEL Restart
      COM32 reboot.c32

    LABEL poweroff
      MENU LABEL Shut down
      COM32 poweroff.c32

    LABEL continue
      MENU LABEL Continue without installing
      LINUX ${kernel}
      INITRD ${initrd}
      APPEND ${init} ${toString params}
  '';
in
{
  options.isoImage.contents = lib.mkOption {
    apply = contents:
      let
        efi = lib.findFirst (item: item.target == "/EFI") null contents;
        canonicalEfi = pkgs.runCommand "cybexos-iso-efi" {} ''
          mkdir -p $out
          cp -r ${efi.source}/. $out/
          chmod -R u+w $out
          # Keep NixOS's header and replace its entries.
          entries=${pkgs.writeText "cybexos-grub-entries.cfg" grubEntries}
          awk -v entries="$entries" '
            /^[[:space:]]*# Menu entries[[:space:]]*$/ { while ((getline line < entries) > 0) print line; done = 1; exit }
            { print }
            END { if (!done) exit 3 }
          ' $out/BOOT/grub.cfg > grub.cfg
          mv grub.cfg $out/BOOT/grub.cfg
          ! grep -q '/boot//nix/store/' $out/BOOT/grub.cfg
          ${pkgs.grub2_efi}/bin/grub-script-check $out/BOOT/grub.cfg
        '';
      in map (item:
        if item.target == "/isolinux/isolinux.cfg" then item // {
          source = pkgs.writeText "cybexos-isolinux.cfg" isolinuxCfg;
        } else if item.target == "/EFI" then item // {
          source = canonicalEfi;
        } else if item.target == "/boot/efi.img" then item // {
          source = pkgs.runCommand "cybexos-iso-efi.img" {
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
