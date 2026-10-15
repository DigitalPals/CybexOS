"""No network: count requests by credential and exercise concurrent completion."""
import json
import os
from pathlib import Path
import sys
import time

kind = 'quota' if '--providers' in sys.argv else 'activity'
key = sys.argv[sys.argv.index('--cliproxy-key-file') + 1]
marker = Path(os.environ['MODEL_USAGE_REQUEST_MARKER'])
previous = [json.loads(line) for line in marker.read_text().splitlines()] if marker.exists() else []
attempt = sum(row['kind'] == kind and row['key'] == key for row in previous) + 1
with marker.open('a') as stream:
    stream.write(json.dumps({'kind': kind, 'key': key, 'attempt': attempt}) + '\n')
time.sleep(0.15)
print(json.dumps({'schemaVersion': 1, 'generatedAt': '', 'proxyImplementation': 'go',
                  'attempt': attempt, 'providers': [{'id': 'codex', 'attempt': attempt}]}))
