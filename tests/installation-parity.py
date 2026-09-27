#!/usr/bin/env python3
"""Run the cross-installer contract in the required source gate as well."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'image'))

if __name__ == '__main__':
    unittest.main(module='test_installation_parity')
