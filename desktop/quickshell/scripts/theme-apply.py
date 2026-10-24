#!/usr/bin/env python3
"""Carry the shell's appearance to the rest of the desktop.

Common/SystemTheme.qml pipes its resolved tokens (theme_tokens.py) to
`theme-apply.py apply` whenever they change. Each target module renders its
files into ~/.local/state/cybexos/theme and, only when one of them changed,
reloads its application. `--force` reloads every target regardless, for the
`theme apply` IPC call. `render` rewrites the files from the saved tokens
without reloading anything.

Every target renders at least one file, even one that configures its
application through another channel (gsettings), because an unchanged file is
how a target knows its application is already up to date.

Usage: theme-apply.py apply [--force] < tokens.json   (one line of JSON)
       theme-apply.py render
Prints one JSON report: {"success": bool, "error"?: str,
                         "targets": {name: {"changed": bool, "error": str|null}}}
"""
import fcntl
import json
import os
import sys
import tempfile

import theme_tokens
import theme_gtk
import theme_hyprland
import theme_hyprlock
import theme_kitty

TARGETS = (theme_kitty, theme_hyprland, theme_gtk, theme_hyprlock)
TOKENS_FILE = 'tokens.json'
MAX_INPUT = 65536


def write_if_changed(directory, name, content):
    """Atomically replaces directory/name with content; False when identical."""
    path = os.path.join(directory, name)
    try:
        with open(path, encoding='utf-8') as handle:
            if handle.read() == content:
                return False
    except (FileNotFoundError, UnicodeDecodeError):
        pass
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=f'.{name}.')
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
            handle.write(content)
        # The shell runs with umask 0077; applications read these as the same
        # user, but 0644 keeps them inspectable like every other config file.
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    return True


def run_targets(tokens, directory, reload, force):
    report = {}
    for target in TARGETS:
        entry = {'changed': False, 'error': None}
        report[target.NAME] = entry
        try:
            changed = False
            for name, content in target.render(tokens).items():
                changed = write_if_changed(directory, name, content) or changed
            entry['changed'] = changed
            if reload and (changed or force):
                target.reload(tokens, directory)
        except Exception as error:  # one target never stops the others
            entry['error'] = str(error) or type(error).__name__
    return report


def main(argv):
    command = argv[1] if len(argv) > 1 else ''
    force = argv[2:] == ['--force']
    if command not in ('apply', 'render') or (argv[2:] and not (command == 'apply' and force)):
        print(json.dumps({'success': False, 'error': 'usage: apply [--force] | render'}))
        return 2
    directory = theme_tokens.state_dir()
    try:
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, '.lock'), 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if command == 'apply':
                # One line: Quickshell's Process keeps stdin open after write().
                raw = sys.stdin.buffer.readline(MAX_INPUT + 1)
                if len(raw) > MAX_INPUT:
                    raise theme_tokens.TokenError('tokens are too large')
                raw = raw.decode('utf-8')
            else:
                with open(os.path.join(directory, TOKENS_FILE), encoding='utf-8') as handle:
                    raw = handle.read(MAX_INPUT + 1)
            tokens = theme_tokens.validate(json.loads(raw))
            write_if_changed(directory, TOKENS_FILE,
                             json.dumps(tokens, indent=2, sort_keys=True) + '\n')
            targets = run_targets(tokens, directory, command == 'apply', force)
    except (OSError, ValueError) as error:  # JSONDecodeError and TokenError are ValueErrors
        print(json.dumps({'success': False, 'error': str(error)}))
        return 1
    success = all(entry['error'] is None for entry in targets.values())
    print(json.dumps({'success': success, 'targets': targets}))
    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
