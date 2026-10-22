#!/usr/bin/env python3
"""Native package dependency smoke; no login, service or hardware qualification."""
import importlib
import io
import os
import shutil
import subprocess

import dbus
import gi
from PIL import Image
from websockets.sync.client import connect

# Resolve the actual wrapped command environment, without a system profile or
# developer shell supplying missing tools. These are executable dependencies of
# preserved capture, clipboard, network, audio, night-light and assistant flows.
required_commands = (
    'satty', 'wayfreeze', 'tesseract', 'zbarimg', 'qrencode', 'hyprpicker', 'hyprsunset',
    'magick', 'notify-send', 'wtype', 'pactl', 'wpctl', 'wl-copy', 'wl-paste', 'cliphist',
    'grim', 'slurp', 'wf-recorder', 'ffmpeg', 'vainfo', 'jq', 'pgrep', 'find', 'grep', 'sed', 'awk',
    'xdg-open', 'curl', 'node', 'iw', 'ip', 'brightnessctl', 'playerctl', 'nmcli',
    'bluetoothctl', 'upower', 'powerprofilesctl', 'restic', 'ssh', 'age', 'tar', 'zstd',
    'flock', 'kitty', 'secret-tool', 'gdbus', 'gsettings', 'hyprctl', 'systemctl',
    'cybexos-runtime', 'quickshell-reminder', 'cybexos-session-action',
    'fwupdmgr', 'cybexos-firmware-update',
)
missing = [command for command in required_commands if shutil.which(command) is None]
assert not missing, 'Missing desktop executable dependencies: ' + ', '.join(missing)
# Exercise noninteractive helper paths, including the English OCR data, rather
# than accepting only executable filenames or a --version command.
languages = subprocess.check_output(['tesseract', '--list-langs'], text=True)
assert 'eng' in languages.splitlines(), 'The OCR English model is missing'
png = subprocess.check_output(['magick', '-size', '2x2', 'xc:red', 'png:-'])
assert Image.open(io.BytesIO(png)).size == (2, 2)
qr = subprocess.check_output(['qrencode', '-t', 'ASCII', '-m', '2', '-o', '-'], input=b'CybexOS dependency check')
assert b'##' in qr and len(qr.splitlines()) > 10
assert subprocess.check_output(['node', '-p', 'JSON.stringify({runtime:"ok"})'], text=True).strip() == '{"runtime":"ok"}'

versions = {
    'Gio': '2.0', 'GLibUnix': '2.0', 'NM': '1.0', 'Secret': '1',
    'Goa': '1.0', 'EDataServer': '1.2', 'ECal': '2.0', 'ICalGLib': '3.0',
    'Fwupd': '2.0', 'Soup': '3.0', 'Json': '1.0',
}
modules = {}
for namespace, version in versions.items():
    gi.require_version(namespace, version)
    modules[namespace] = importlib.import_module('gi.repository.' + namespace)

# Resolve native classes/functions as well as loading typelib metadata. These
# objects do not connect to a bus, inspect accounts or mutate persistent state.
assert modules['Gio'].File.new_for_path('/').get_path() == '/'
assert modules['NM'].SimpleConnection.new() is not None
assert modules['Secret'].Schema.new('org.cybexos.DependencyCheck', modules['Secret'].SchemaFlags.NONE, {}) is not None
assert modules['Goa'].Client.__gtype__.name == 'GoaClient'
assert modules['EDataServer'].Source.__gtype__.name == 'ESource'
assert modules['ECal'].Component.new() is not None
assert modules['ICalGLib'].Time.new_null_time() is not None
assert modules['Fwupd'].Client.new() is not None
assert modules['Soup'].Session.new() is not None
assert modules['Json'].Parser.new() is not None
signal = modules['GLibUnix'].signal_source_new(15)
signal.destroy()
assert Image.new('RGB', (1, 1)).size == (1, 1)
assert callable(connect) and dbus.String('dependency-check') == 'dependency-check'
schemas = modules['Gio'].SettingsSchemaSource.get_default()
assert schemas is not None and schemas.lookup('org.gnome.desktop.interface', True) is not None
assert modules['Gio'].TlsBackend.get_default().supports_tls()
assert os.environ.get('GI_TYPELIB_PATH') and os.environ.get('GIO_EXTRA_MODULES')
# Both explicit shebangs and QML's PATH-based python3 must select the rich env.
assert shutil.which('python3') is not None
subprocess.run(['python3', '-I', '-c',
                'import gi, dbus; from PIL import Image; from websockets.sync.client import connect; '
                'gi.require_version("Fwupd", "2.0"); from gi.repository import Fwupd; assert Fwupd.Client.new()'],
               check=True)
print('Desktop executable, OCR, image, QR, Node, Python, GI, schema and GIO TLS dependency checks passed')
