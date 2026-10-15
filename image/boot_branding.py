"""Style the generated firmware menu without replacing its boot commands.

Call after LiveImageCreator._configure_bootloader(isodir), before its EFI
filesystem is generated. The upstream subclass hook is documented in
https://github.com/livecd-tools/livecd-tools/blob/main/imgcreate/live.py.
"""
from pathlib import Path
import re
import shutil

MARKER = "# CybexOS menu appearance"
# Kernel argument for the installation-only session; see cybexos-live-setup.
INSTALL_ARGUMENT = "cybexos.install"


def grub_install_entries(text):
    """Offer each generated live entry twice: straight to the installer, then live.

    The first entry stays the default, so an unattended boot opens the installer.
    """
    if INSTALL_ARGUMENT in text:
        return text

    def pair(match):
        block = match.group(0)
        install = re.sub(r"(?m)^([ \t]*linux(?:efi)?[ \t].*?)[ \t]*$", rf"\1 {INSTALL_ARGUMENT}", block, count=1)
        return (install.replace("menuentry 'Start CybexOS", "menuentry 'Install CybexOS", 1)
                + block.replace("menuentry 'Start CybexOS", "menuentry 'Try CybexOS live", 1))
    return re.sub(r"(?ms)^[ \t]*menuentry 'Start CybexOS[^\n]*\{\n.*?^[ \t]*\}\n", pair, text)


def isolinux_install_entries(text):
    """The BIOS menu equivalent; `menu default` moves to the installer entry."""
    if INSTALL_ARGUMENT in text:
        return text

    def pair(match):
        name, body = match.group(1), match.group(2)
        label = re.search(r"(?m)^\s*menu label (.*)$", body).group(1)
        if "Start CybexOS" not in label.replace("^", ""):
            return match.group(0)
        main = label.startswith("^Start CybexOS")
        live_label = label.replace("Start CybexOS", "Try CybexOS live", 1)
        install_label = ("^Install CybexOS" + label[len("^Start CybexOS"):] if main
                         else label.replace("^", "").replace("Start CybexOS", "Install CybexOS", 1))
        live = body.replace(f"menu label {label}", f"menu label {live_label}", 1)
        live = re.sub(r"(?m)^[ \t]*menu default\n", "", live)
        install = body.replace(f"menu label {label}", f"menu label {install_label}", 1)
        install = re.sub(r"(?m)^([ \t]*append .*?)[ \t]*$", rf"\1 {INSTALL_ARGUMENT}", install, count=1)
        return f"label install-{name}\n{install}label {name}\n{live}"
    return re.sub(r"(?m)^label (\S+)\n((?:[ \t]+.*\n)*)", pair, text)


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
            text = grub_install_entries(path.read_text())
            path.write_text(text if MARKER in text else text + appearance)
    bios = isodir / "isolinux/isolinux.cfg"
    if bios.is_file():
        text = isolinux_install_entries(bios.read_text())
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
