#!/usr/bin/env python3
"""Run the targeted-release and CI preview contract in the required source gate."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'image'))

if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromNames(['test_fedora_release'])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
