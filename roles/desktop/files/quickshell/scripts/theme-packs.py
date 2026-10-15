#!/usr/bin/env python3
"""List, apply, install, export and remove named appearance themes.

`cybex theme` (assets/scripts/cybexos-theme) runs this from the active shell
runtime, and Settings → Appearance (Common/Themes.qml) uses the same
commands, so both validate themes and map them to settings identically
(scripts/theme_packs.py).

  list [--json]                 built-in and user themes
  apply ID                      apply now, or at the next shell start
  install SOURCE [--replace]    a folder, a .tar.gz/.zip archive or an https Git URL
  export ID|CURRENT [DIR] [--name NAME]
                                write a theme folder, or a .tar.gz when DIR ends so
  remove ID                     delete a user theme

The shell also calls:

  resolve ID [--wall-dir DIR]   one line of JSON: {"id", "name", "patch"}, after
                                copying the theme's wallpaper into DIR
  save --name NAME              save the settings JSON on stdin (one line) as a
                                user theme; prints {"id", "name"}
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import theme_packs
from theme_packs import ThemeError

IPC_TIMEOUT = 6
MAX_STDIN = 2 * 1024 * 1024


def ipc(*args):
    """Calls the running shell; None when there is none to answer."""
    helper = os.environ.get('CYBEXOS_RUNTIME_HELPER') or shutil.which('cybexos-runtime')
    if not helper:
        return None
    try:
        result = subprocess.run([helper, 'ipc', *args], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=IPC_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def current_settings():
    """The shell's effective settings when it runs, else the saved ones."""
    answer = ipc('settings', 'values')
    if answer:
        try:
            value = json.loads(answer)
            if isinstance(value, dict):
                return value
        except ValueError:
            pass
    return theme_packs.read_settings()


def command_list(args):
    listing = theme_packs.catalogue()
    if args.json:
        print(json.dumps({'themes': [theme_packs.summary(theme) for theme in listing['themes']],
                          'invalid': listing['invalid']}, separators=(',', ':')))
        return 0
    rows = [(theme['id'], theme['name'], theme['mode'], 'built-in' if theme['builtin'] else 'user')
            for theme in listing['themes']]
    widths = [max(len(row[index]) for row in rows + [('ID', 'NAME', 'MODE', 'SOURCE')])
              for index in range(3)]
    for row in [('ID', 'NAME', 'MODE', 'SOURCE')] + rows:
        print('  '.join(value.ljust(width) for value, width in zip(row, widths)) + '  ' + row[3])
    for entry in listing['invalid']:
        print(f'cybex theme: skipped {entry["id"]}: {entry["error"]}', file=sys.stderr)
    return 0


def command_resolve(args):
    theme = theme_packs.find(args.id)
    print(json.dumps(theme_packs.resolve(theme, args.wall_dir), separators=(',', ':')))
    return 0


def command_apply(args):
    theme = theme_packs.find(args.id)
    payload = theme_packs.resolve(theme)
    answer = ipc('theme', 'use', json.dumps(payload, separators=(',', ':')))
    if answer == 'ok':
        print(f'Applied {theme["name"]}.')
        return 0
    if answer is not None and answer.startswith('error:'):
        raise ThemeError(answer[len('error:'):].strip())
    # No shell answered (or one too old to know themes): the settings file
    # carries the theme to the next start, and a running shell watching it
    # picks the change up as well.
    theme_packs.persist(payload['patch'])
    print(f'Applied {theme["name"]}. The desktop shell is not running; '
          'it takes effect when the shell starts.')
    return 0


def command_install(args):
    theme = theme_packs.install(args.source, replace=args.replace)
    ipc('theme', 'refresh')
    print(f'Installed {theme["name"]} as {theme["id"]}. Apply it with `cybex theme apply {theme["id"]}`.')
    return 0


def command_export(args):
    wallpaper = None
    if args.id == 'CURRENT':
        settings = current_settings()
        theme = theme_packs.theme_from_settings(settings, args.name or 'My theme')
        wallpaper = theme_packs.current_wallpaper(settings)
    else:
        if args.name:
            raise ThemeError('--name only applies to CURRENT')
        theme = theme_packs.find(args.id)
    written = theme_packs.export(theme, args.directory, wallpaper)
    print(f'Exported {theme["name"]} to {written}. Install it with `cybex theme install {written}`.')
    return 0


def command_remove(args):
    theme_packs.remove(args.id)
    ipc('theme', 'refresh')
    print(f'Removed {args.id}.')
    return 0


def command_save(args):
    raw = sys.stdin.buffer.readline(MAX_STDIN + 1)
    if len(raw) > MAX_STDIN:
        raise ThemeError('the settings are too large')
    try:
        settings = json.loads(raw.decode('utf-8') or '{}')
    except (UnicodeDecodeError, ValueError):
        raise ThemeError('the settings are not valid JSON') from None
    if not isinstance(settings, dict):
        raise ThemeError('the settings are not an object')
    theme = theme_packs.save(settings, args.name)
    print(json.dumps({'id': theme['id'], 'name': theme['name']}, separators=(',', ':')))
    return 0


def parser():
    root = argparse.ArgumentParser(prog='cybex theme', description='Named appearance themes.')
    commands = root.add_subparsers(dest='command', required=True)
    listing = commands.add_parser('list', help='list built-in and user themes')
    listing.add_argument('--json', action='store_true')
    listing.set_defaults(run=command_list)
    apply = commands.add_parser('apply', help='apply a theme')
    apply.add_argument('id')
    apply.set_defaults(run=command_apply)
    install = commands.add_parser('install', help='install a theme folder, archive or https Git URL')
    install.add_argument('source')
    install.add_argument('--replace', action='store_true', help='replace an installed theme')
    install.set_defaults(run=command_install)
    export = commands.add_parser('export', help='export a theme, or CURRENT, the current appearance')
    export.add_argument('id', metavar='ID|CURRENT')
    export.add_argument('directory', nargs='?', default='.', metavar='DIR')
    export.add_argument('--name', help='the name for CURRENT (default: My theme)')
    export.set_defaults(run=command_export)
    remove = commands.add_parser('remove', help='remove a user theme')
    remove.add_argument('id')
    remove.set_defaults(run=command_remove)
    resolve = commands.add_parser('resolve')
    resolve.add_argument('id')
    resolve.add_argument('--wall-dir', type=Path)
    resolve.set_defaults(run=command_resolve)
    save = commands.add_parser('save')
    save.add_argument('--name', required=True)
    save.set_defaults(run=command_save)
    return root


def main(argv):
    args = parser().parse_args(argv)
    try:
        return args.run(args)
    except (ThemeError, OSError) as error:
        message = str(error) if isinstance(error, ThemeError) else (error.strerror or str(error))
        if args.command in ('resolve', 'save'):
            print(json.dumps({'error': message}))
        print(f'cybex theme: {message}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
