#!/usr/bin/env python3
"""Import one vendor wallpaper without overwriting a user's existing file.

Both source and installed runtimes use this path resolver. An exclusive link
publishes the complete copy; a name collision gets a content-derived suffix.
The resulting basename joins the normal folder, rotation and Matugen flow.
"""
from hashlib import sha256
import json
from pathlib import Path
import os
import sys
import tempfile

NAMES = ('moon-mountains.png', 'quiet-fjord.png', 'dusk-ridges.png',
         'copper-horizon.png', 'forest-distance.png', 'blue-hour.png', 'winter-silence.png')


def collection_dir(shell_dir):
    for directory in (shell_dir.parent / 'wallpapers', shell_dir.parent.parent / 'assets/wallpapers'):
        if (directory / 'moon-mountains.png').is_file():
            return directory
    raise FileNotFoundError('Bundled wallpapers are missing')


def import_image(source_dir, name, destination):
    if name not in NAMES:
        raise ValueError('Unknown bundled wallpaper')
    data = (source_dir / name).read_bytes()
    destination.mkdir(parents=True, exist_ok=True)
    digest = sha256(data).hexdigest()
    stem = 'cybexos-' + Path(name).stem
    with tempfile.NamedTemporaryFile(dir=destination, prefix='.cybexos-import-', delete=False) as temporary:
        temporary.write(data)
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    try:
        for candidate in (stem + '.png', stem + '-' + digest[:12] + '.png'):
            target = destination / candidate
            try:
                os.link(temporary_path, target)
                target.chmod(0o644)
                return candidate
            except FileExistsError:
                if not target.is_symlink() and target.is_file() and target.read_bytes() == data:
                    return candidate
        raise FileExistsError('Both bundled wallpaper names are occupied')
    finally:
        temporary_path.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        shell_dir = Path(__file__).resolve().parent.parent
        name = import_image(collection_dir(shell_dir), sys.argv[1], Path(sys.argv[2]))
        print(json.dumps({'fileName': name}))
    except (OSError, ValueError, IndexError):
        print(json.dumps({'error': 'import'}))
        sys.exit(1)
