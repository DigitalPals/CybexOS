#!/usr/bin/env python3
"""Read local wallpaper metadata without decoding the full-size image."""
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urlparse
from PIL import Image

if __name__ == '__main__':
    try:
        value = sys.argv[1]
        path = Path(unquote(urlparse(value).path) if value.startswith('file:') else value)
        with Image.open(path) as image:
            width, height = image.size
        print(json.dumps(dict(width=width, height=height, size=path.stat().st_size)))
    except (OSError, ValueError, IndexError):
        print('{}')
