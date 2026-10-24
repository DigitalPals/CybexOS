#!/usr/bin/env python3
"""Inventory retired NerdOS product/CLI references, including tracked paths.

Use check_leftovers.py for the allowlist-enforced check. This report includes
historical evidence and upstream Nerd Font names so they can be reviewed.
"""
import collections
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()
names = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z',
                                 '--cached', '--others', '--exclude-standard']).decode().split('\0')
pattern = re.compile(r'(?i)nerdos|\bnerd\b')
counts = collections.Counter()
for name in sorted(set(names)):
    path = root / name
    if not path.is_file():
        continue
    if pattern.search(name):
        print(f'{name} [path]')
    try:
        text = path.read_text()
    except (OSError, UnicodeError):
        continue
    for number, line in enumerate(text.splitlines(), 1):
        hits = pattern.findall(line)
        if hits:
            counts.update(hits)
            print(f'{name}:{number}: {line.strip()[:160]}')
print('\nSpelling counts:', dict(counts))
