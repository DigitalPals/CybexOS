#!/usr/bin/env python3
"""Lossless settings writes and actual application include precedence."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def load(name, relative):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / relative))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


STORE = load('settings_store', 'roles/desktop/files/quickshell/scripts/settings-store')
MANAGED = load('managed_file', 'image/library/cybexos_managed_file.py')
INCLUDE = load('user_include', 'image/library/cybexos_user_include.py')


class SettingsOwnership(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cybexos-settings-ownership-')
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.path = self.home / 'shell.json'

    def test_independent_concurrent_edit_survives(self):
        base = {'v': 27, 'unit': 'c', 'themeMode': 'dark', 'future': {'data': [1]}}
        local = {**base, 'unit': 'f'}
        other = {**base, 'themeMode': 'light', 'future': {'data': [2]}}
        self.path.write_text(json.dumps(other))
        saved = json.loads(STORE.commit(self.path, json.dumps(base), json.dumps(local), 27))
        self.assertEqual(saved, {**other, 'unit': 'f'})
        self.assertEqual(json.loads(self.path.read_text()), saved)

    def test_conflict_preserves_disk_and_pending_candidate(self):
        base = {'v': 27, 'barHeight': 36}
        desired = {'v': 27, 'barHeight': 40}
        current = json.dumps({'v': 27, 'barHeight': 44})
        self.path.write_text(current)
        with self.assertRaisesRegex(ValueError, '/barHeight'):
            STORE.commit(self.path, json.dumps(base), json.dumps(desired), 27)
        self.assertEqual(self.path.read_text(), current)
        copies = list(self.home.glob('shell.json.conflict-*'))
        self.assertEqual(len(copies), 1)
        self.assertEqual(json.loads(copies[0].read_text()), desired)

    def test_newer_schema_blocks_writes_even_if_loaded_file_was_older(self):
        future = '{"v":28,"future":{"opaque":true}}'
        self.path.write_text(future)
        with self.assertRaisesRegex(ValueError, 'newer shell'):
            STORE.commit(self.path, '{"v":27}', '{"v":27,"unit":"f"}', 27)
        self.assertEqual(self.path.read_text(), future)

    def test_migration_keeps_exact_original_and_unknown_fields(self):
        original = '{ "v": 3, "barHeight":30, "unknown":{"unparsed":true} }\n'
        self.path.write_text(original)
        candidate = json.loads(original)
        candidate.update(v=27, unit='f')
        STORE.commit(self.path, original, json.dumps(candidate), 27)
        backups = list(self.home.glob('shell.json.before-migration-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), original)
        self.assertEqual(json.loads(self.path.read_text())['unknown'], {'unparsed': True})

    def test_nested_merge_and_explicit_reset_preserve_other_edits(self):
        base = {'v': 27, 'unit': 'c', 'modOpts': {'weather': {'place': 'Home', 'pollMins': 10}}}
        local = {'v': 27, 'modOpts': {'weather': {'place': 'Home', 'pollMins': 20}}}
        other = {'v': 27, 'unit': 'c', 'modOpts': {'weather': {'place': 'Away', 'pollMins': 10}}}
        merged = STORE.merge(base, local, other)
        self.assertNotIn('unit', merged)
        self.assertEqual(merged['modOpts']['weather'], {'place': 'Away', 'pollMins': 20})

    def test_owned_fragments_update_but_customization_and_deletion_survive(self):
        ledger = self.home / 'state/ownership.json'
        target = self.home / 'kitty/cybexos.conf'
        self.assertTrue(MANAGED.manage(target, b'first\n', ledger)['changed'])
        self.assertTrue(MANAGED.manage(target, b'second\n', ledger)['changed'])
        target.write_bytes(b'custom\n')
        self.assertTrue(MANAGED.manage(target, b'third\n', ledger)['preserved'])
        self.assertEqual(target.read_bytes(), b'custom\n')
        target.unlink()
        self.assertTrue(MANAGED.manage(target, b'third\n', ledger)['preserved'])
        self.assertFalse(target.exists())
        self.assertEqual(len(list((ledger.parent / 'backups').rglob('*/*'))), 1)

    def test_user_edited_include_block_is_not_replaced_or_removed(self):
        original = INCLUDE.BEGIN + '\ninclude personal.conf\n' + INCLUDE.END + '\n'
        self.path.write_text(original)
        self.assertTrue(INCLUDE.update(self.path, 'kitty')['preserved'])
        self.assertTrue(INCLUDE.update(self.path, 'kitty', absent=True)['preserved'])
        self.assertEqual(self.path.read_text(), original)

    def test_relocation_is_idempotent_and_preserves_the_original(self):
        old = 'font_size 17\n' + INCLUDE.BEGIN + '\ninclude cybexos.conf\n' + INCLUDE.END + '\n'
        self.path.write_text(old)
        self.assertTrue(INCLUDE.update(self.path, 'kitty')['changed'])
        self.assertFalse(INCLUDE.update(self.path, 'kitty')['changed'])
        self.assertTrue(self.path.read_text().startswith(INCLUDE.BEGIN))
        self.assertEqual(next(self.home.glob('shell.json.cybexos-before-*')).read_text(), old)

    def test_git_user_values_win_in_the_actual_parser(self):
        vendor = self.home / '.config/cybexos/gitconfig'
        vendor.parent.mkdir(parents=True)
        vendor.write_text('[core]\n pager = delta\n')
        target = self.home / '.gitconfig'
        target.write_text('[core]\n pager = personal-pager\n[user]\n name = Personal\n')
        INCLUDE.update(target, 'git')
        target.write_text(target.read_text().replace('~/.config', str(self.home / '.config')))
        self.assertEqual(subprocess.check_output(['git', 'config', '--file', str(target), '--includes',
                                                '--get', 'core.pager'], text=True).strip(), 'personal-pager')

    def test_personal_git_helper_chain_is_detected_through_nested_includes(self):
        vendor = self.home / '.config/cybexos/gitconfig'
        vendor.parent.mkdir(parents=True)
        vendor.write_text('[credential "https://github.com"]\n helper = vendor-helper\n')
        target = self.home / '.gitconfig'
        target.write_text('[include]\n path = ' + str(vendor) + '\n')
        self.assertFalse(INCLUDE.personal_git_credentials(target))
        personal = self.home / 'personal.gitconfig'
        personal.write_text('[credential "https://github.com"]\n helper = personal-helper\n')
        target.write_text(target.read_text() + '[include]\n path = ' + str(personal) + '\n')
        self.assertTrue(INCLUDE.personal_git_credentials(target))

    def test_ssh_user_first_value_and_final_host_scope(self):
        vendor = self.home / '.config/cybexos/ssh.conf'
        vendor.parent.mkdir(parents=True)
        vendor.write_text('Host *\n IdentityAgent /vendor/agent.sock\n ServerAliveInterval 17\n')
        target = self.home / '.ssh/config'
        target.parent.mkdir()
        target.write_text('Host example\n IdentityAgent /personal/agent.sock\nHost different\n User custom\n')
        INCLUDE.update(target, 'ssh')
        target.write_text(target.read_text().replace('~/.config', str(self.home / '.config')))
        actual = subprocess.check_output(['ssh', '-G', '-F', str(target), 'example'], text=True,
                                         stderr=subprocess.DEVNULL)
        self.assertIn('identityagent /personal/agent.sock\n', actual)
        self.assertIn('serveraliveinterval 17\n', actual)

    @unittest.skipUnless(shutil.which('kitty'), 'Kitty config parser is not installed')
    def test_kitty_user_last_value_in_the_actual_parser(self):
        target = self.home / 'kitty.conf'
        (self.home / 'cybexos.conf').write_text('font_size 12\n')
        target.write_text('font_size 17\n')
        INCLUDE.update(target, 'kitty')
        code = 'from kitty.config import load_config; print(load_config(' + repr(str(target)) + ').font_size)'
        self.assertEqual(float(subprocess.check_output(['kitty', '+runpy', code], text=True).strip()), 17)

    def test_checkout_and_image_share_the_same_personal_policy(self):
        personal = yaml.safe_load((ROOT / 'roles/dotfiles/tasks/personal.yml').read_text())
        by_name = {task['name']: task for task in personal}
        xdg = by_name['Configure XDG user directories']['ansible.builtin.copy']
        self.assertFalse(xdg['force'])
        for task in personal:
            if 'cybexos_managed_file' in task:
                self.assertEqual(task['become_user'], '{{ primary_user }}')
                self.assertIn('/.local/state/cybexos/defaults/', task['cybexos_managed_file']['ledger'])
        provision = (ROOT / 'image/provision.yml').read_text()
        self.assertIn('tasks_from: personal', provision)
        self.assertIn('library = image/library', (ROOT / 'ansible.cfg').read_text())


if __name__ == '__main__':
    unittest.main()
