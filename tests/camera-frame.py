#!/usr/bin/env python3
"""Reject loopback splash buffers and truncated captures without camera access."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[1]
checker = root / "roles/xps-2026/files/camera/xps-ipu7-camera-frame-check"
with tempfile.TemporaryDirectory(prefix="cybexos-camera-frame-test-") as directory:
    command = Path(directory) / "v4l2-ctl"
    command.write_text("""#!/usr/bin/env python3
import os, sys
if '--get-fmt-video' in sys.argv:
    print('Size Image : 128')
else:
    assert '--stream-skip=30' in sys.argv
    assert '--stream-count=3' in sys.argv
    assert '--stream-to=-' in sys.argv
    scenario = os.environ['FRAME_SCENARIO']
    if scenario == 'error':
        sys.exit(1)
    frames = [bytes(128)] * 3
    if scenario == 'fresh':
        frames = [bytes([value]) * 128 for value in (17, 25, 42)]
    elif scenario == 'truncated':
        frames.pop()
    sys.stdout.buffer.write(b''.join(frames))
""")
    command.chmod(0o755)
    for scenario in ("fresh", "splash", "truncated", "error"):
        result = subprocess.run(
            [sys.executable, str(checker)], capture_output=True, text=True,
            env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                     FRAME_SCENARIO=scenario),
        )
        assert (result.returncode == 0) == (scenario == "fresh"), (
            scenario, result.returncode, result.stdout, result.stderr,
        )
print("camera fresh-frame, splash, truncation, and capture-error fixtures passed")
