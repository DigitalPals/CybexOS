"""Unattended seed validation, disk matching and the controller's seed path.

Source-only fixtures: no volume is mounted, no disk is touched, and the
secrets below are fixture strings, never real credentials.
"""
import json
import os
from pathlib import Path
import re
import tempfile
import time
import types
import unittest
from unittest.mock import patch

import yaml

from test_installer import DISK, FakeBackend, backend, target

ROOT = Path(__file__).resolve().parent
seed_format = backend.seed_format
HASH = '$y$j9T$SKre8868v2XV1NXxxycxM/$klea7p1t8995H5ER2f8JnqFUUOtu1t24e8W3qRBPIU3'
KEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnlyReplaceWithYourOwnPublicKey0 alice@desktop'
FILES = {'disk-passphrase': b'fixture disk phrase\n', 'tailscale-auth-key': b'tskey-auth-fixture0123456789\n'}


def documented_example():
    """The full example in INSTALLER.md must stay valid."""
    text = (ROOT / 'INSTALLER.md').read_text()
    section = text[text.index('## Unattended installation'):]
    return re.search(r'```yaml\n(.*?)```', section, re.DOTALL).group(1)


def seed(document=None, files=None, **changes):
    value = yaml.safe_load(documented_example()) if document is None else document
    value.update(changes)
    files = FILES if files is None else files

    def read(name):
        if name not in files:
            raise FileNotFoundError(name)
        return files[name]

    return seed_format.parse(yaml.safe_dump(value), read)


def errors(**changes):
    with self_assert_raises() as caught:
        seed(**changes)
    return caught.errors


class self_assert_raises:
    def __enter__(self):
        return self

    def __exit__(self, kind, value, _traceback):
        if not isinstance(value, seed_format.SeedError):
            raise AssertionError(f'expected SeedError, got {value!r}')
        self.errors = value.errors
        return True


class SeedFormatTests(unittest.TestCase):
    def test_documented_example_is_valid_and_its_secrets_stay_separate(self):
        parsed = seed()
        self.assertEqual(parsed.settings['username'], 'alice')
        self.assertEqual(parsed.settings['match'], {'serial': 'S6B0NL0W123456'})
        self.assertEqual(parsed.settings['config'], {'manage_personal_dotfiles': True,
                                                     'features': {'steam': False, 'local_network_services': False}})
        self.assertEqual(parsed.secrets, {'passphrase': 'fixture disk phrase', 'password_hash': HASH,
                                          'tailscale_auth_key': 'tskey-auth-fixture0123456789'})
        summary = json.dumps(parsed.summary())
        for secret in ('fixture disk phrase', 'tskey-auth', HASH):
            self.assertNotIn(secret, summary)
        self.assertEqual(parsed.summary()['countdown'], 30)
        self.assertRegex(parsed.digest, r'^[0-9a-f]{64}$')

    def test_every_problem_is_reported_at_once_without_secrets(self):
        document = yaml.safe_load(documented_example())
        document['disk']['erase'] = False
        document['account']['password'] = 'plain text secret'
        document['account']['password_hash'] = 'plain text secret'
        document['countdown'] = 3
        document['surprise'] = True
        found = errors(document=document)
        self.assertEqual(len(found), 5, found)
        self.assertTrue(any('disk.erase: true' in message for message in found))
        self.assertTrue(any('account.password is not accepted' in message for message in found))
        self.assertTrue(any('countdown' in message for message in found))
        self.assertTrue(any('Unknown setting "surprise"' in message for message in found))
        self.assertNotIn('plain text secret', ' '.join(found))

    def test_disk_rules_need_an_identity_and_valid_sizes(self):
        for match, expected in (({'min_size': '500GB'}, 'not only a size'),
                                ({'serial': ''}, 'non-empty text'),
                                ({'path': 'sda'}, '/dev path'),
                                ({'serial': 'X', 'min_size': 'big'}, 'size such as'),
                                ({'model': 'X', 'min_size': '2T', 'max_size': '1T'}, 'larger than'),
                                ({'serial': 'X', 'colour': 'blue'}, 'disk.match.colour'),
                                ({}, 'at least one')):
            document = yaml.safe_load(documented_example())
            document['disk']['match'] = match
            with self.subTest(match=match):
                self.assertTrue(any(expected in message for message in errors(document=document)))
        self.assertEqual(seed_format.parse_size('465GiB'), 465 * 1024**3)
        self.assertEqual(seed_format.parse_size('1.5TB'), 1500 * 1000**3)
        self.assertEqual(seed_format.parse_size(1024), 1024)

    def test_secret_files_are_required_bounded_and_one_line(self):
        for files, expected in (({}, 'could not be read'),
                                ({**FILES, 'disk-passphrase': b'short\n'}, '12–512'),
                                ({**FILES, 'disk-passphrase': b'two\nlines here ok\n'}, '12–512'),
                                ({**FILES, 'disk-passphrase': b'\xff\xfe invalid utf8'}, 'UTF-8'),
                                ({**FILES, 'tailscale-auth-key': b'not-a-tailscale-key-at-all\n'}, 'tskey')):
            with self.subTest(expected=expected):
                found = errors(files=files)
                self.assertTrue(any(expected in message for message in found), found)
        document = yaml.safe_load(documented_example())
        document['encryption']['passphrase_file'] = '../escape'
        self.assertTrue(any('top of the seed volume' in message for message in errors(document=document)))
        # CRLF is an editor's line ending, not part of the passphrase.
        parsed = seed(files={**FILES, 'disk-passphrase': b'fixture disk phrase\r\n'})
        self.assertEqual(parsed.secrets['passphrase'], 'fixture disk phrase')

    def test_unencrypted_seed_needs_no_passphrase_and_refuses_one(self):
        document = yaml.safe_load(documented_example())
        document['encryption'] = {'enabled': False}
        self.assertNotIn('passphrase', seed(document=document).secrets)
        document['encryption']['passphrase_file'] = 'disk-passphrase'
        self.assertTrue(errors(document=document))

    def test_new_owner_seed_has_no_account_or_ssh(self):
        document = yaml.safe_load(documented_example())
        document['oem'] = True
        found = errors(document=document)
        self.assertTrue(any('Remove the "account" section' in message for message in found))
        self.assertTrue(any('SSH settings need an account' in message for message in found))
        del document['account'], document['ssh']
        parsed = seed(document=document)
        self.assertTrue(parsed.settings['oem'])
        self.assertEqual(parsed.secrets, {'passphrase': 'fixture disk phrase',
                                          'tailscale_auth_key': 'tskey-auth-fixture0123456789'})
        document['oem'] = False
        self.assertTrue(any('"account" section is required' in message for message in errors(document=document)))

    def test_config_uses_the_shared_installation_choices(self):
        for config, expected in (({'desktop_autologin': True}, 'not a choice'),
                                 ({'features': {'warp_drive': True}}, 'not a CybexOS feature'),
                                 ({'features': {'steam': 'no'}}, 'true or false')):
            with self.subTest(config=config):
                found = errors(config=config)
                self.assertTrue(any(expected in message for message in found), found)
        self.assertTrue(any('Tailscale feature' in message or 'features.tailscale' in message
                            for message in errors(config={'features': {'tailscale': False}})))

    def test_ssh_keys_and_hashes_are_checked(self):
        document = yaml.safe_load(documented_example())
        document['ssh']['authorized_keys'] = ['not a key']
        self.assertTrue(any('OpenSSH public keys' in message for message in errors(document=document)))
        for value in ('$1$md5$weak', '$6$short', HASH + 'x', 'plain'):
            document = yaml.safe_load(documented_example())
            document['account']['password_hash'] = value
            with self.subTest(value=value):
                self.assertTrue(any('password_hash' in message for message in errors(document=document)))
        document = yaml.safe_load(documented_example())
        document['account']['password_hash'] = ('$6$cybexosexample$l.9y43qkJ1JsT9UyxU1WWtOBsTi8N9qfXkX6zlT4cyFXbG3NDrA'
                                                'BfN.LYlo1VYJmpgsc5gbIfPIfnpSbrnXr0.')
        self.assertTrue(seed(document=document).secrets['password_hash'].startswith('$6$'))

    def test_invalid_yaml_and_non_mapping_are_explained(self):
        with self_assert_raises() as caught:
            seed_format.parse('disk: [unclosed', lambda name: b'')
        self.assertIn('not valid YAML (line', caught.errors[0])
        with self_assert_raises() as caught:
            seed_format.parse('- a list', lambda name: b'')
        self.assertIn('mapping', caught.errors[0])


DISKS = [
    dict(DISK, name='vda', path='/dev/vda', serial='SERIAL-A', model='Samsung  SSD 980', size=1000 * 1000**3),
    dict(DISK, name='vdb', path='/dev/vdb', serial='SERIAL-B', model='Samsung SSD 980', size=500 * 1000**3),
    dict(DISK, name='sdc', path='/dev/sdc', serial='USB-SEED', model='USB Stick', size=128 * 1000**3),
]


class InstalledLayoutTests(unittest.TestCase):
    def test_module_loads_from_the_installed_libexec_path(self):
        """Installed as /usr/libexec/cybexos-installer-seed the file has only
        three parents. Every installer command imports this module, so a
        source-layout lookup that indexes past them broke the whole installer
        in the live image while checkout tests passed (2026-10-14 VM run)."""
        source = (ROOT / 'live-rootfs/usr/libexec/cybexos-installer-seed').read_text()
        namespace = {'__file__': '/usr/libexec/cybexos-installer-seed', '__name__': 'installed_seed'}
        saved = list(os.sys.path)
        os.sys.path.insert(0, str(ROOT))  # stands in for /usr/share/cybexos/lib
        try:
            exec(compile(source, '/usr/libexec/cybexos-installer-seed', 'exec'), namespace)
            self.assertIn('/usr/share/cybexos/lib', os.sys.path)
        finally:
            os.sys.path[:] = saved
        self.assertTrue(callable(namespace['discover']))


class DiskMatchTests(unittest.TestCase):
    def select(self, rule, **options):
        return seed_format.select_disk(rule, DISKS, **options)['name']

    def test_exactly_one_disk_must_match_every_key(self):
        self.assertEqual(self.select({'serial': 'SERIAL-B'}), 'vdb')
        self.assertEqual(self.select({'model': 'samsung ssd 980', 'min_size': 800 * 1000**3}), 'vda')
        self.assertEqual(self.select({'path': '/dev/disk/by-id/fixture'},
                                     resolve=lambda path: '/dev/vdb'), 'vdb')
        with self_assert_raises() as caught:
            self.select({'model': 'Samsung SSD 980'})
        self.assertIn('2 disks match', caught.errors[0])
        self.assertIn('SERIAL-A', caught.errors[0])
        with self_assert_raises() as caught:
            self.select({'serial': 'serial-b'})  # Serials are exact.
        self.assertIn('No disk matches', caught.errors[0])
        with self_assert_raises():
            self.select({'serial': 'SERIAL-A', 'max_size': 900 * 1000**3})

    def test_the_seed_volumes_own_disk_is_never_a_target(self):
        with self_assert_raises():
            self.select({'serial': 'USB-SEED'}, excluded={'/dev/sdc'})
        self.assertEqual(self.select({'serial': 'USB-SEED'}), 'sdc')


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.labels = self.base / 'by-label'
        self.labels.mkdir()
        self.mount = self.base / 'mount'
        self.mount.mkdir()
        self.calls = []

    def fake_run(self, command, **kwargs):
        self.calls.append(command)
        if command[0] == 'lsblk':
            return types.SimpleNamespace(stdout='sdc\n', returncode=0)
        return types.SimpleNamespace(stdout='', returncode=0)

    def label(self, name, device='seed-device'):
        (self.base / device).write_text('')
        (self.labels / name).symlink_to(self.base / device)

    def test_no_label_or_no_seed_file_is_not_a_seed(self):
        self.assertEqual(seed_format.discover(self.mount, self.labels, self.fake_run), (None, None))
        self.assertEqual(self.calls, [])
        self.label('CIDATA')
        self.assertEqual(seed_format.discover(self.mount, self.labels, self.fake_run), (None, '/dev/sdc'))

    def test_volume_is_mounted_read_only_read_and_unmounted(self):
        self.label('CYBEXOS-SEED')
        (self.mount / 'cybexos-seed.yml').write_text(documented_example())
        for name, data in FILES.items():
            (self.mount / name).write_bytes(data)
        found, disk = seed_format.discover(self.mount, self.labels, self.fake_run)
        self.assertEqual(found.settings['username'], 'alice')
        self.assertEqual(disk, '/dev/sdc')
        mount = next(command for command in self.calls if command[0] == 'mount')
        self.assertEqual(mount[1:3], ['-o', 'ro,nosuid,nodev,noexec'])
        self.assertEqual(self.calls[-2][0], 'umount')

    def test_unmounts_even_when_the_seed_is_invalid_and_refuses_symlinks(self):
        self.label('CYBEXOS-SEED')
        (self.mount / 'cybexos-seed.yml').write_text(documented_example())
        (self.mount / 'secret-elsewhere').write_text('fixture disk phrase\n')
        (self.mount / 'disk-passphrase').symlink_to(self.mount / 'secret-elsewhere')
        (self.mount / 'tailscale-auth-key').write_bytes(FILES['tailscale-auth-key'])
        with self_assert_raises() as caught:
            seed_format.discover(self.mount, self.labels, self.fake_run)
        self.assertTrue(any('disk-passphrase' in message for message in caught.errors))
        self.assertIn('umount', [command[0] for command in self.calls])

    def test_two_seed_volumes_are_refused(self):
        self.label('CYBEXOS-SEED', 'one')
        self.label('CIDATA', 'two')
        with self_assert_raises() as caught:
            seed_format.discover(self.mount, self.labels, self.fake_run)
        self.assertIn('More than one', caught.errors[0])

    def test_check_command_validates_a_folder(self):
        (self.mount / 'cybexos-seed.yml').write_text(documented_example())
        for name, data in FILES.items():
            (self.mount / name).write_bytes(data)
        with patch('builtins.print') as printed:
            self.assertEqual(seed_format.main(['check', str(self.mount)]), 0)
        self.assertNotIn('fixture disk phrase', str(printed.call_args_list))
        (self.mount / 'disk-passphrase').unlink()
        with patch('builtins.print'):
            self.assertEqual(seed_format.main(['check', str(self.mount)]), 1)


class FakeSeeds:
    def __init__(self, parsed, disk='/dev/sdc'):
        self.parsed, self.disk = parsed, disk

    def discover(self):
        if isinstance(self.parsed, Exception):
            raise self.parsed
        return self.parsed, self.disk


class ControllerSeedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = backend.State(Path(self.temporary.name))
        self.adapter = FakeBackend()
        self.adapter.choices['disks'][0]['serial'] = 'S6B0NL0W123456'
        self.parsed = seed()
        self.installer = backend.Installer(self.adapter, self.state, seeds=FakeSeeds(self.parsed))

    def test_seed_report_is_display_safe_and_names_the_matched_disk(self):
        report = self.installer.seed()
        self.assertTrue(report['valid'], report)
        self.assertEqual(report['seed']['disk']['name'], 'vda')
        self.assertNotIn('fixture disk phrase', json.dumps(report))
        self.assertNotIn('tskey', json.dumps(report))
        self.adapter.choices['disks'][0]['serial'] = 'OTHER'
        report = self.installer.seed()
        self.assertFalse(report['valid'])
        self.assertIn('No disk matches', report['errors'][0])
        self.installer.seeds = FakeSeeds(seed_format.SeedError(['fixture problem']))
        self.assertEqual(self.installer.seed(), {'found': True, 'valid': False, 'errors': ['fixture problem']})
        self.installer.seeds = FakeSeeds(None, None)
        self.assertEqual(self.installer.seed(), {'found': False})

    def test_unavailable_system_choices_are_reported(self):
        self.adapter.choices['timezones'] = ['UTC']
        report = self.installer.seed()
        self.assertFalse(report['valid'])
        self.assertIn('timezone', report['errors'][0])

    def test_plan_uses_the_hash_and_passphrase_and_persists_neither(self):
        plan = self.installer.plan({'seed': self.parsed.digest})
        self.assertEqual(self.adapter.credentials, {'password_hash': seed().secrets['password_hash'],
                                                    'passphrase': 'fixture disk phrase'})
        account = plan['account']
        self.assertTrue(account['unattended'])
        self.assertEqual(account['ssh_authorized_keys'], [KEY])
        self.assertEqual(account['config']['features'], {'steam': False, 'local_network_services': False})
        stored = (self.state.directory / 'state.json').read_text()
        for secret in ('fixture disk phrase', 'tskey-auth', '$y$j9T'):
            self.assertNotIn(secret, stored)
        staged = self.state.directory / 'staged/tailscale-authkey'
        self.assertEqual(staged.read_text(), 'tskey-auth-fixture0123456789')
        self.assertEqual(staged.stat().st_mode & 0o777, 0o600)
        self.installer.reset()
        self.assertFalse(staged.exists())

    def test_a_changed_seed_is_refused(self):
        with self.assertRaises(backend.Invalid):
            self.installer.plan({'seed': '0' * 64})
        self.assertEqual(self.state.read()['phase'], 'failed-plan')
        self.assertFalse(self.adapter.started)

    def test_countdown_is_enforced_by_the_backend(self):
        plan = self.installer.plan({'seed': self.parsed.digest})
        confirmation = {'token': plan['token'], 'confirmed_disk': 'vda', 'erase_confirmed': True}
        with self.assertRaises(backend.Invalid) as caught:
            self.installer.install(dict(confirmation))
        self.assertIn('countdown', str(caught.exception))
        self.assertFalse(self.adapter.started)
        with patch.object(backend.time, 'time', return_value=time.time() + 31):
            self.installer.install(dict(confirmation))
        self.assertTrue(self.adapter.started)

    def test_a_cancelled_seed_is_not_offered_again_until_it_changes(self):
        with self.assertRaises(backend.Invalid):
            self.installer.cancel_seed({'seed': 'not a digest'})
        self.installer.plan({'seed': self.parsed.digest})
        self.assertEqual(self.installer.cancel_seed({'seed': self.parsed.digest}), {'phase': 'setup'})
        self.assertFalse((self.state.directory / 'staged/tailscale-authkey').exists())
        report = self.installer.seed()
        self.assertTrue(report['cancelled'])
        self.assertFalse(report['valid'])
        with self.assertRaises(backend.Invalid):
            self.installer.plan({'seed': self.parsed.digest})
        changed = seed(countdown=60)
        self.installer.seeds = FakeSeeds(changed)
        self.assertTrue(self.installer.seed()['valid'])

    def test_reserved_seed_usernames_are_refused(self):
        document = yaml.safe_load(documented_example())
        document['account']['username'] = 'sddm'
        self.installer.seeds = FakeSeeds(seed(document=document))
        self.assertFalse(self.installer.seed()['valid'])


class TargetSeedAndOwnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'sysroot'
        (self.root / 'etc/cybexos').mkdir(parents=True)
        (self.root / 'etc/shadow').write_text('root:!:1::::::\n')
        self.staged = Path(self.temporary.name) / 'staged'
        self.staged.mkdir()
        self.commands = []

    def fake_run(self, command, **kwargs):
        self.commands.append(command)
        return types.SimpleNamespace(returncode=0, stdout='')

    def account(self, **changes):
        return {'account': {'username': 'alice', 'encrypted': True, 'passwordless_wheel': False, **changes}}

    def with_user(self):
        uid, gid = os.getuid(), os.getgid()
        (self.root / 'etc/passwd').write_text(f'root:x:0:0::/root:/bin/bash\nalice:x:{uid}:{gid}::/home/alice:/bin/bash\n')
        (self.root / 'home/alice').mkdir(parents=True)
        (self.root / 'etc/cybexos/config.yml').write_text(
            "primary_user: 'alice'\ndesktop_autologin: false\npasswordless_wheel: false\n")

    def test_stage_records_only_explicit_choices(self):
        target.stage(self.root, self.account())
        self.assertFalse((self.root / 'etc/cybexos/install-choices.json').exists())
        target.stage(self.root, self.account(config={'features': {'steam': False}}))
        self.assertEqual(json.loads((self.root / 'etc/cybexos/install-choices.json').read_text()),
                         {'version': 1, 'choices': {'features': {'steam': False}}})

    def test_seeded_account_gets_keys_server_and_one_time_key(self):
        if os.getuid() >= 65534 or os.getuid() < 1000:
            self.skipTest('the fixture account needs a regular uid')
        self.with_user()
        (self.staged / 'tailscale-authkey').write_text('tskey-auth-fixture0123456789')
        policy = self.account(ssh_authorized_keys=[KEY], ssh_server=True, unattended=True)
        target.finalize(self.root, policy, True, staged=self.staged, run=self.fake_run)
        keys = self.root / 'home/alice/.ssh/authorized_keys'
        self.assertEqual(keys.read_text(), KEY + '\n')
        self.assertEqual(keys.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / 'home/alice/.ssh').stat().st_mode & 0o777, 0o700)
        self.assertIn(['systemctl', f'--root={self.root}', 'enable', 'sshd.service'], self.commands)
        moved = self.root / 'var/lib/cybexos/first-boot/tailscale-authkey'
        self.assertEqual(moved.read_text(), 'tskey-auth-fixture0123456789')
        self.assertEqual(moved.stat().st_mode & 0o777, 0o600)
        self.assertEqual(moved.parent.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.staged / 'tailscale-authkey').exists())
        record = json.loads((self.root / 'etc/cybexos/installation.json').read_text())
        self.assertTrue(record['unattended'] and record['tailscaleEnrollment'])
        self.assertFalse(record['passwordsInitiallyShared'])
        self.assertTrue((self.root / 'var/lib/cybexos/factory-point.pending').is_file())

    def test_new_owner_target_has_no_account_and_no_autologin(self):
        (self.root / 'etc/passwd').write_text('root:x:0:0::/root:/bin/bash\n')
        policy = {'account': {'username': '', 'oem': True, 'encrypted': True, 'passwordless_wheel': True}}
        target.finalize(self.root, policy, True, staged=self.staged, run=self.fake_run)
        self.assertEqual(json.loads((self.root / 'etc/cybexos/login.json').read_text()),
                         {'version': 1, 'user': '', 'autologin': False, 'live': False})
        self.assertEqual(json.loads((self.root / 'etc/cybexos/oem.json').read_text()),
                         {'version': 1, 'passwordless_wheel': True})
        # The sudo choice is applied to the new owner's account, not now.
        self.assertFalse((self.root / 'etc/sudoers.d/10-wheel-nopasswd').exists())
        self.assertTrue(json.loads((self.root / 'etc/cybexos/installation.json').read_text())['oem'])
        uid = os.getuid() if 1000 <= os.getuid() < 65534 else 1000
        (self.root / 'etc/passwd').write_text(f'root:x:0:0::/root:/bin/bash\nbob:x:{uid}:{uid}::/home/bob:/bin/bash\n')
        with self.assertRaises(RuntimeError):
            target.finalize(self.root, policy, True, staged=self.staged, run=self.fake_run)
        with self.assertRaises(RuntimeError):
            target.finalize(self.root, {'account': {**policy['account'], 'oem': 'yes'}}, True,
                            staged=self.staged, run=self.fake_run)

    def test_alongside_shows_the_menu_and_records_other_systems(self):
        (self.root / 'etc/passwd').write_text('root:x:0:0::/root:/bin/bash\n')
        grub = self.root / 'boot/grub2/grub.cfg'
        grub.parent.mkdir(parents=True)
        grub.write_text('### BEGIN /etc/grub.d/30_os-prober ###\n'
                        "menuentry 'Windows Boot Manager (on /dev/vda1)' --class windows {\n}\n"
                        '### END /etc/grub.d/30_os-prober ###\n')
        policy = {'account': {'username': '', 'oem': True, 'encrypted': False}, 'layout': {'mode': 'alongside'}}
        target.finalize(self.root, policy, False, staged=self.staged, run=self.fake_run)
        self.assertIn(['chroot', str(self.root), 'grub2-editenv', '-', 'unset', 'menu_auto_hide'], self.commands)
        record = json.loads((self.root / 'etc/cybexos/installation.json').read_text())
        self.assertEqual((record['layout'], record['otherSystemsInBootMenu']), ('alongside', True))
        grub.write_text('### BEGIN /etc/grub.d/30_os-prober ###\n### END /etc/grub.d/30_os-prober ###\n')
        self.assertFalse(target.other_systems_in_menu(self.root))


if __name__ == '__main__':
    unittest.main()
