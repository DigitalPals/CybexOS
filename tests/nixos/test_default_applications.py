"""Real GIO associations and argv-safe launches in disposable XDG directories."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'assets/scripts/cybexos-apps'
loader = importlib.machinery.SourceFileLoader('default_applications', str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
apps = importlib.util.module_from_spec(spec); loader.exec_module(apps)
try:
    apps.libraries()
    HAS_GIO = True
except ImportError:
    HAS_GIO = False


@unittest.skipUnless(HAS_GIO and shutil.which('xdg-terminal-exec'), 'GIO and xdg-terminal-exec are provided by nix develop')
class DefaultApplicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.data = self.base / 'data'; (self.data / 'applications').mkdir(parents=True)
        self.log = self.base / 'launch.json'
        self.capture = self.base / 'capture'
        self.capture.write_text('#!' + sys.executable + '\nimport os,sys,json\nfrom pathlib import Path\nPath(os.environ["APPLICATION_LOG"]).write_text(json.dumps(sys.argv[1:]))\n')
        self.capture.chmod(0o755)
        self.env = os.environ | {'HOME':str(self.base), 'XDG_CONFIG_HOME':str(self.base / 'config'),
             'XDG_DATA_HOME':str(self.data), 'XDG_DATA_DIRS':str(self.base / 'empty'),
             'XDG_CONFIG_DIRS':str(self.base / 'empty-config'), 'XDG_CURRENT_DESKTOP':'Hyprland',
             'XDG_CACHE_HOME':str(self.base / 'cache'), 'APPLICATION_LOG':str(self.log),
             'DBUS_SESSION_BUS_ADDRESS':'unix:path=/nonexistent-cybexos-test-bus', 'VISUAL':'', 'EDITOR':''}
        self.desktop('browser.desktop', 'Browser', 'MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;\nActions=new-private-window;\n\n[Desktop Action new-private-window]\nName=Private\nExec=' + str(self.capture) + ' --private\n')
        self.desktop('editor.desktop', 'Editor', 'MimeType=text/plain;text/html;\n')
        self.desktop('terminal.desktop', 'Terminal', 'Categories=System;TerminalEmulator;\nX-TerminalArgExec=-e\nX-TerminalArgTitle=--title=\n')
        subprocess.run(['update-desktop-database', str(self.data / 'applications')], check=True, capture_output=True, env=self.env)

    def desktop(self, identifier, name, extra):
        (self.data / 'applications' / identifier).write_text('[Desktop Entry]\nType=Application\nName=' + name + '\nExec=' + str(self.capture) + (' %U\n' if name == 'Browser' else ' %F\n') + extra)

    def run_apps(self, *arguments):
        result = subprocess.run([sys.executable, str(SCRIPT), *arguments], env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def captured(self):
        for _ in range(100):
            if self.log.exists(): return json.loads(self.log.read_text())
            time.sleep(.02)
        self.fail('Application did not launch')

    def test_associations_preserve_other_mime_choices_and_update_browser_launches(self):
        config = self.base / 'config'; config.mkdir()
        (config / 'mimeapps.list').write_text('[Default Applications]\napplication/x-personal=personal.desktop;\n')
        result = self.run_apps('set', 'browser', 'browser.desktop')
        self.assertEqual(result['roles']['browser']['selected'], 'browser.desktop')
        self.assertNotIn('editor.desktop', [row['value'] for row in result['roles']['browser']['choices']])
        self.assertIn('application/x-personal=personal.desktop;', (config / 'mimeapps.list').read_text())
        self.run_apps('browser', 'https://example.invalid/a?x=two%20words')
        self.assertEqual(self.captured(), ['https://example.invalid/a?x=two%20words'])
        self.log.unlink()
        self.run_apps('browser', '--private')
        self.assertEqual(self.captured(), ['--private'])

    def test_terminal_preferences_and_arguments_with_spaces(self):
        self.run_apps('set', 'terminal', 'terminal.desktop')
        self.run_apps('terminal', '--title=Two words', '--', 'printf', 'literal $(touch no-file)')
        self.assertEqual(self.captured(), ['--title=Two words', '-e', 'printf', 'literal $(touch no-file)'])
        self.assertFalse((self.base / 'no-file').exists())

    def test_explicit_editor_override_and_removed_application_choice_survive(self):
        self.run_apps('set', 'editor', 'editor.desktop')
        self.env['EDITOR'] = str(self.capture) + ' --personal'
        self.run_apps('edit', 'a file.txt')
        self.assertEqual(self.captured(), ['--personal', 'a file.txt'])
        (self.data / 'applications/editor.desktop').unlink()
        state = self.run_apps('status')
        self.assertTrue(state['roles']['editor']['unavailable'])
        self.assertEqual(state['roles']['editor']['selected'], 'editor.desktop')
        saved = json.loads((self.base / 'config/cybexos/default-applications.json').read_text())
        self.assertEqual(saved['choices']['editor'], 'editor.desktop')

    def test_external_mime_selection_takes_precedence_over_missing_saved_choice(self):
        self.run_apps('set', 'editor', 'editor.desktop')
        self.desktop('other.desktop', 'Other', 'MimeType=text/plain;\n')
        (self.data / 'applications/editor.desktop').unlink()
        path = self.base / 'config/mimeapps.list'
        path.write_text(path.read_text().replace('editor.desktop', 'other.desktop'))
        role = self.run_apps('status')['roles']['editor']
        self.assertFalse(role['unavailable'])
        self.assertEqual(role['selected'], 'other.desktop')

    def test_selected_browser_handles_webapps_and_terminal_editor_gets_file_uris(self):
        self.run_apps('set', 'browser', 'browser.desktop')
        self.run_apps('webapp', 'https://example.invalid/app')
        self.assertEqual(self.captured(), ['https://example.invalid/app'])
        self.log.unlink()
        self.run_apps('set', 'terminal', 'terminal.desktop')
        self.desktop('console-editor.desktop', 'Console editor', 'MimeType=text/plain;\nTerminal=true\n')
        path = self.data / 'applications/console-editor.desktop'
        path.write_text(path.read_text().replace(' %F', ' %U'))
        self.run_apps('set', 'editor', 'console-editor.desktop')
        target = self.base / 'a file.txt'
        self.run_apps('edit', str(target))
        self.assertEqual(self.captured(), ['-e', str(self.capture), target.as_uri()])
