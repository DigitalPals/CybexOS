"""Style the generated firmware menu without replacing its boot commands.

Call after LiveImageCreator._configure_bootloader(isodir), before its EFI
filesystem is generated. The upstream subclass hook is documented in
https://github.com/livecd-tools/livecd-tools/blob/main/imgcreate/live.py.
"""
from pathlib import Path
import re
import shutil

MARKER = "# CybexOS menu appearance"


def brand_boot_menu(isodir, install_root, source=None):
    isodir, install_root = Path(isodir), Path(install_root)
    source = Path(source) if source else Path(__file__).with_name("boot-theme")
    grub_paths = [path for relative in ("EFI/BOOT/grub.cfg", "boot/grub2/grub.cfg")
                  if (path := isodir / relative).is_file()]
    if grub_paths:
        theme = isodir / "boot/grub2/themes/cybexos"
        theme.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / "theme.txt", theme / "theme.txt")
        shutil.copy2(install_root / "usr/share/plymouth/themes/cybex/logo.png", theme / "logo.png")
        font = install_root / "usr/share/grub/unicode.pf2"
        if font.is_file():
            shutil.copy2(font, theme / "unicode.pf2")
        # Text colors are a fallback when firmware cannot use gfxterm. Keep
        # every menuentry, kernel argument, media check and recovery entry.
        appearance = "\n" + MARKER + "\n" + '''set color_normal=light-gray/black
set color_highlight=yellow/black
if loadfont /boot/grub2/themes/cybexos/unicode.pf2; then
  insmod gfxterm
  insmod png
  set gfxmode=auto
  terminal_output gfxterm
  set theme=/boot/grub2/themes/cybexos/theme.txt
  export theme
fi
'''
        for path in grub_paths:
            text = path.read_text()
            if MARKER not in text:
                path.write_text(text + appearance)
    bios = isodir / "isolinux/isolinux.cfg"
    if bios.is_file():
        text = bios.read_text()
        # A generic Fedora splash can be referenced by stock syslinux. Use a
        # dark canvas with the same warm accent, retaining all boot entries.
        text = re.sub(r"(?m)^menu background .*\n", "", text)
        text = re.sub(r"(?m)^menu title .*", "menu title CybexOS", text)
        colors = {"title": "#ffd3d283 #ff0d0d0d", "sel": "#ff0d0d0d #ffd3d283",
                  "unsel": "#ffe8e7df #ff0d0d0d", "border": "#00000000 #ff0d0d0d"}
        for key, color in colors.items():
            line = f"menu color {key} 0 {color} none"
            pattern = rf"(?m)^menu color {key} .*"
            text = re.sub(pattern, line, text) if re.search(pattern, text) else text + "\n" + line + "\n"
        bios.write_text(text)
