"""Run the shared session startup regressions in the image source gate too."""
import importlib.machinery
import importlib.util
from pathlib import Path


source = Path(__file__).resolve().parents[1] / 'tests/session-launcher.py'
loader = importlib.machinery.SourceFileLoader('session_start_fixtures', str(source))
spec = importlib.util.spec_from_loader(loader.name, loader)
fixtures = importlib.util.module_from_spec(spec)
loader.exec_module(fixtures)
SessionAutostartTests = fixtures.SessionAutostartTests
