"""New-owner (OEM) setup, factory reset and first-start fixtures.

Nothing here touches a disk, an account or a boot loader: cryptsetup,
useradd, the snapshot helper and the console are stubs. The secrets are
fixture strings.
"""
import contextlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
LIBEXEC = ROOT / 'image/rootfs/usr/libexec'


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


owner = load('cybexos_new_owner', LIBEXEC / 'cybexos-new-owner')
factory = load('cybexos_factory_reset', LIBEXEC / 'cybexos-factory-reset')
first_boot = load('cybexos_first_boot', LIBEXEC / 'cybexos-first-boot')
snapshot = load('cybexos_snapshot_for_reset', ROOT / 'roles/base/files/cybexos-system-snapshot')
policy = load('installation_policy_for_reset', ROOT / 'image/installation_policy.py')
SECRETS = ('temporary handover 1', 'new owner password', 'old owner passphrase')


class Done(types.SimpleNamespace):
    pass


def done(returncode=0, stdout=''):
    return Done(returncode=returncode, stdout=stdout)


class FakeLuks:
    """A LUKS2 header: key slots hold passphrases; tokens are opaque."""

    def __init__(self, passphrase, tokens=('0',)):
        self.slots = {'0': passphrase}
        self.tokens = set(tokens)
        self.argv = []

    def __call__(self, command, **kwargs):
        self.argv.append(list(command))
        given = kwargs.get('input', b'')
        given = given.decode() if isinstance(given, bytes) else given
        if command[:2] == ['cryptsetup', 'open']:
            slot = next((item.split('=', 1)[1] for item in command if item.startswith('--key-slot=')), None)
            slots = [slot] if slot else list(self.slots)
            return done(0 if any(self.slots.get(item) == given for item in slots) else 2)
        if command[:2] == ['cryptsetup', 'luksAddKey']:
            if given not in self.slots.values():
                return done(2)
            descriptor = int(command[-1].rsplit('/', 1)[1])
            self.assert_fd(descriptor, kwargs)
            new = os.read(descriptor, 4096).decode()
            self.slots[str(max(map(int, self.slots)) + 1)] = new
            return done()
        if command[:2] == ['cryptsetup', 'luksDump']:
            return done(stdout=json.dumps({'keyslots': {slot: {} for slot in self.slots},
                                           'tokens': {token: {} for token in self.tokens}}))
        if command[:2] == ['cryptsetup', 'luksKillSlot']:
            remaining = {slot: value for slot, value in self.slots.items() if slot != command[-1]}
            if given not in remaining.values():
                return done(2)
            self.slots = remaining
            return done()
        if command[:3] == ['cryptsetup', 'token', 'remove']:
            self.tokens.discard(command[command.index('--token-id') + 1])
            return done()
        raise AssertionError(command)

    @staticmethod
    def assert_fd(descriptor, kwargs):
        assert descriptor in kwargs.get('pass_fds', ()), 'the new key must arrive through a passed pipe'


class Script:
    """Console answers, in order; secrets come from their own queue."""

    def __init__(self, answers, secrets=()):
        self.answers, self.secrets, self.said = list(answers), list(secrets), []

    def say(self, text=''):
        self.said.append(text)

    def ask(self, prompt):
        self.said.append(prompt)
        return self.answers.pop(0)

    def secret(self, prompt):
        return self.secrets.pop(0)


class RekeyTests(unittest.TestCase):
    def test_exactly_the_new_passphrase_remains_and_secrets_stay_off_argv(self):
        luks = FakeLuks('temporary handover 1', tokens=('0', '3'))
        luks.slots['1'] = 'an old recovery key'
        owner.rekey('/dev/vda3', 'temporary handover 1', 'new owner password', luks)
        self.assertEqual(list(luks.slots.values()), ['new owner password'])
        self.assertEqual(luks.tokens, set())
        self.assertFalse(owner.opens('/dev/vda3', 'temporary handover 1', luks))
        for command in luks.argv:
            for secret in SECRETS + ('an old recovery key',):
                self.assertNotIn(secret, ' '.join(command))

    def test_repeat_after_interruption_keeps_the_new_slot(self):
        luks = FakeLuks('temporary handover 1')
        luks.slots['1'] = 'new owner password'
        owner.rekey('/dev/vda3', 'temporary handover 1', 'new owner password', luks)
        self.assertEqual(luks.slots, {'1': 'new owner password'})
        self.assertFalse(any(command[1] == 'luksAddKey' for command in luks.argv))

    def test_wrong_current_passphrase_removes_nothing(self):
        luks = FakeLuks('temporary handover 1')
        with self.assertRaises(owner.SetupError):
            owner.rekey('/dev/vda3', 'not the passphrase', 'new owner password', luks)
        self.assertEqual(luks.slots, {'0': 'temporary handover 1'})

    def test_devices_are_every_luks_backing_of_the_root(self):
        def run(command, **kwargs):
            if command[0] == 'findmnt':
                return done(stdout=json.dumps({'filesystems': [
                    {'source': '/dev/mapper/luks-a[/root]', 'target': '/', 'fstype': 'btrfs'}]}))
            if command[0] == 'btrfs':
                return done(stdout='Label: fedora  uuid: 01234567-89ab-cdef-0123-456789abcdef\n'
                                   '\tTotal devices 2 FS bytes used 4096\n'
                                   '\tdevid    1 size 65536 used 4096 path /dev/mapper/luks-a\n'
                                   '\tdevid    2 size 65536 used 4096 path /dev/mapper/luks-b\n')
            name = command[-1].rsplit('-', 1)[1]
            return done(stdout=json.dumps({'blockdevices': [{'path': f'/dev/mapper/luks-{name}', 'type': 'crypt',
                'fstype': 'btrfs', 'children': [{'path': f'/dev/nvme0n1p{3 if name == "a" else 4}',
                                                 'type': 'part', 'fstype': 'crypto_LUKS'}]}]}))

        with patch.object(owner, 'LIBEXEC', ROOT / 'roles/desktop/files/login'), \
                patch.object(owner, 'load', lambda name, filename: load(name, ROOT / 'roles/desktop/files/login' / filename)):
            self.assertEqual(owner.luks_devices(run), ['/dev/nvme0n1p3', '/dev/nvme0n1p4'])


def lists(command, **kwargs):
    answers = {
        ('localectl', 'list-x11-keymap-layouts'): 'us\nde\nnl\n',
        ('localectl', 'list-x11-keymap-variants'): 'dvorak\nintl\n',
        ('localectl', 'list-locales'): 'en_US.UTF-8\nnl_NL.UTF-8\n',
        ('timedatectl', 'list-timezones'): 'Europe/Amsterdam\nAmerica/New_York\n',
    }
    return done(stdout=answers.get(tuple(command[:2]), ''))


class CollectTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.passwd = Path(self.temporary.name) / 'passwd'
        self.passwd.write_text('root:x:0:0::/root:/bin/bash\ntaken:x:1000:1000::/home/taken:/bin/bash\n')
        self.calls = []

    def fake_run(self, command, **kwargs):
        self.calls.append(command)
        return lists(command, **kwargs)

    def test_answers_are_validated_and_the_keyboard_is_applied_first(self):
        console = Script(['u', 'dv', 'nl_', 'Alice: Example', 'Alice Example', 'Root', 'taken', 'alice', 'Europe/A'],
                         ['short', 'short', 'new owner password', 'new owner password'])
        answers = owner.collect(console, self.fake_run, passwd=self.passwd)
        self.assertEqual(answers, dict(keyboard='us (dvorak)', locale='nl_NL.UTF-8', timezone='Europe/Amsterdam',
                                       full_name='Alice Example', username='alice',
                                       password='new owner password', startup=''))
        self.assertIn(['localectl', 'set-x11-keymap', 'us', '', 'dvorak'], self.calls)
        self.assertTrue(any('Use a password of 12' in line for line in console.said))
        self.assertTrue(any('System names are reserved' in line for line in console.said))

    def test_encrypted_disk_requires_the_startup_passphrase(self):
        luks = FakeLuks('temporary handover 1')

        def run(command, **kwargs):
            return luks(command, **kwargs) if command[0] == 'cryptsetup' else self.fake_run(command, **kwargs)

        console = Script(['us', '', 'en_US.UTF-8', '', 'alice', 'UTC'],
                         ['new owner password', 'new owner password', 'wrong one here', 'temporary handover 1'])
        answers = owner.collect(console, run, devices=['/dev/vda3'], passwd=self.passwd)
        self.assertEqual(answers['startup'], 'temporary handover 1')
        console = Script(['us', '', 'en_US.UTF-8', '', 'alice'],
                         ['new owner password', 'new owner password', 'a', 'b', 'c'])
        with self.assertRaises(owner.SetupError):
            owner.collect(console, run, devices=['/dev/vda3'], passwd=self.passwd)


class FakeConfig:
    def __init__(self, root):
        self.root = root

    def current(self, root):
        return {'primary_user': 'alice', 'desktop_autologin': False, 'passwordless_wheel': False}

    def render(self, values):
        return json.dumps(values)

    def write(self, text, path):
        path.write_text(text)


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'etc/cybexos').mkdir(parents=True)
        (self.root / 'etc/cybexos/oem.json').write_text('{"version": 1, "passwordless_wheel": true}\n')
        (self.root / 'etc/cybexos/install-choices.json').write_text('{"version": 1, "choices": {}}\n')
        (self.root / 'etc/cybexos/installation.json').write_text('{"oem": true, "encrypted": true}\n')
        (self.root / 'etc/vconsole.conf').write_text('KEYMAP="us"\n')
        self.luks = FakeLuks('temporary handover 1')
        self.calls = []
        self.failing = None

    def fake_run(self, command, **kwargs):
        if command[0] == 'cryptsetup':
            return self.luks(command, **kwargs)
        self.calls.append(command)
        for secret in SECRETS:
            assert secret not in ' '.join(command), command
        if command[0] == owner.CONFIGURE:
            (self.root / 'etc/cybexos/install-choices.json').unlink()
            (self.root / 'etc/cybexos/config.yml').write_text('recorded\n')
        if self.failing and command[0] == self.failing:
            raise subprocess.CalledProcessError(1, command)
        if command[0] == 'lsinitrd':
            # The installer built the initramfs with a US keymap.
            return done(stdout='KEYMAP="us"\n')
        return done()

    def answers(self):
        return dict(keyboard='us', locale='nl_NL.UTF-8', timezone='Europe/Amsterdam', full_name='Alice Example',
                    username='alice', password='new owner password', startup='temporary handover 1')

    def apply(self, answers=None):
        return owner.apply(answers or self.answers(), owner.read_state(self.root / 'etc/cybexos/oem.json'),
                           ['/dev/vda3'], self.fake_run, self.root, encrypted_root=lambda: True,
                           config=FakeConfig(self.root))

    def test_account_is_provisioned_like_an_installation_and_the_oem_state_goes_last(self):
        answers = self.answers()
        self.assertTrue(self.apply(answers))
        names = [command[0] for command in self.calls]
        # lsinitrd: the unlock prompt's keymap is checked before the re-key.
        self.assertEqual(names, ['localectl', 'timedatectl', 'useradd', 'chpasswd',
                                 owner.CONFIGURE, owner.SEED_USERS, 'lsinitrd', 'restorecon'])
        self.assertLess(names.index('useradd'), names.index(owner.CONFIGURE))
        self.assertLess(names.index(owner.CONFIGURE), names.index(owner.SEED_USERS))
        self.assertIn(['useradd', '--create-home', '--groups', 'wheel', '--comment', 'Alice Example', 'alice'], self.calls)
        self.assertIn([owner.CONFIGURE, '--offline', '--user', 'alice'], self.calls)
        self.assertEqual(self.luks.slots, {'1': 'new owner password'})
        self.assertEqual(json.loads((self.root / 'etc/cybexos/login.json').read_text()),
                         {'version': 1, 'user': 'alice', 'autologin': True, 'live': False})
        self.assertTrue(json.loads((self.root / 'etc/cybexos/config.yml').read_text())['desktop_autologin'])
        self.assertEqual((self.root / 'etc/sudoers.d/10-wheel-nopasswd').read_text(), '%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n')
        self.assertEqual((self.root / 'etc/sudoers.d/10-wheel-nopasswd').stat().st_mode & 0o777, 0o440)
        record = json.loads((self.root / 'etc/cybexos/installation.json').read_text())
        self.assertEqual((record['username'], record['oem']), ('alice', False))
        self.assertFalse((self.root / 'etc/cybexos/oem.json').exists())
        self.assertNotIn('password', answers)
        self.assertNotIn('startup', answers)
        self.assertFalse((self.root / owner.PENDING).exists())

    def test_progress_names_each_stage_and_a_new_keymap_reaches_the_unlock_prompt_first(self):
        (self.root / 'etc/vconsole.conf').write_text('KEYMAP="de-nodeadkeys"\nXKBLAYOUT=de\n')
        stages = []
        owner.apply(self.answers(), owner.read_state(self.root / 'etc/cybexos/oem.json'), ['/dev/vda3'],
                    self.fake_run, self.root, encrypted_root=lambda: True, config=FakeConfig(self.root),
                    progress=stages.append)
        self.assertEqual(stages, ['account', 'desktop', 'disk', 'finish'])
        names = [command[0] for command in self.calls]
        # The initramfs still had the installer's keymap, so it is rebuilt
        # before the new password becomes the only passphrase.
        self.assertIn(['dracut', '--regenerate-all', '--force'], self.calls)
        self.assertLess(names.index('dracut'), names.index('restorecon'))
        self.assertEqual(self.luks.slots, {'1': 'new owner password'})

    def test_an_unencrypted_disk_skips_the_disk_stage(self):
        stages = []
        owner.apply(self.answers(), owner.read_state(self.root / 'etc/cybexos/oem.json'), [], self.fake_run,
                    self.root, encrypted_root=lambda: False, config=FakeConfig(self.root), progress=stages.append)
        self.assertEqual(stages, ['account', 'desktop', 'finish'])
        self.assertNotIn('lsinitrd', [command[0] for command in self.calls])

    def test_failure_removes_the_account_and_restores_the_saved_choices(self):
        self.failing = owner.SEED_USERS
        with self.assertRaises(subprocess.CalledProcessError):
            self.apply()
        self.assertIn(['userdel', '--force', '--remove', 'alice'], self.calls)
        self.assertTrue((self.root / 'etc/cybexos/oem.json').exists())
        self.assertEqual(json.loads((self.root / 'etc/cybexos/install-choices.json').read_text())['version'], 1)
        self.assertFalse((self.root / 'etc/cybexos/config.yml').exists())
        # The disk still opens with the temporary passphrase for the next attempt.
        self.assertEqual(self.luks.slots, {'0': 'temporary handover 1'})

    def test_unit_runs_on_the_console_before_any_login(self):
        unit = (ROOT / 'image/rootfs/usr/lib/systemd/system/cybexos-new-owner.service').read_text()
        self.assertIn('ConditionPathExists=/etc/cybexos/oem.json', unit)
        self.assertIn('display-manager.service', unit.split('Before=', 1)[1].splitlines()[0])
        self.assertIn('TTYPath=/dev/tty1', unit)
        self.assertIn('ConditionKernelCommandLine=!rd.live.image', unit)


@contextlib.contextmanager
def fixture_store(top):
    store = snapshot.Store(top)
    for directory in (store.roots, store.boot, store.metadata, store.replaced):
        directory.mkdir(parents=True, exist_ok=True)
    yield store


class FakeSnapshot:
    """The real snapshot module's store logic over a plain directory tree."""

    def __init__(self, top, kind='btrfs', running='/root', factory_point='20260801T120000Z-1'):
        self.top, self.kind, self.running = top, kind, running
        self.layout = snapshot.Layout(kind, uuid='fixture', running=running,
                                      recovery='20260801T120000Z-1' if kind == 'recovery' else '',
                                      message='fixture layout')
        self.deleted = []
        with fixture_store(top) as store:
            for point in (factory_point, '20260901T120000Z-2', '20260902T120000Z-3'):
                if point:
                    (store.roots / point).mkdir(exist_ok=True)
                    (store.metadata / f'{point}.meta').write_text('point\n')
            if factory_point:
                (store.metadata / f'{factory_point}.factory').write_text('factory state\n')
        self.REPLACED_PATTERN = snapshot.REPLACED_PATTERN
        self.atomic_write = snapshot.atomic_write
        self.delete_point = snapshot.delete_point

    def detect_layout(self):
        return self.layout

    @contextlib.contextmanager
    def opened_store(self, layout, create):
        with fixture_store(self.top) as store:
            yield store

    def run(self, command):
        self.deleted.append(command[-1])
        shutil.rmtree(command[-1])

    def regenerate_quietly(self, layout, store):
        pass


class FactoryResetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.top = self.base / 'top'
        (self.top / 'root').mkdir(parents=True)
        self.installation = self.base / 'installation.json'
        self.installation.write_text('{"oem": false}\n')
        self.snapshot = FakeSnapshot(self.top)
        self.calls = []
        self.luks = None
        patcher = patch.dict(os.environ, {'CYBEXOS_FACTORY_RESET_TESTING': '1'})
        patcher.start()
        self.addCleanup(patcher.stop)
        snapshot_run = patch.object(snapshot, 'run', side_effect=lambda command, **kw: shutil.rmtree(command[-1]))
        snapshot_run.start()
        self.addCleanup(snapshot_run.stop)

    def fake_run(self, command, **kwargs):
        if command[0] == 'cryptsetup':
            return self.luks(command, **kwargs)
        self.calls.append(command)
        return done()

    def new_owner(self, devices=()):
        module = types.SimpleNamespace(**{name: getattr(owner, name) for name in ('opens', 'rekey', 'validate_password')})
        module.luks_devices = lambda run: list(devices)
        return module

    def reset(self, answers, secrets=(), devices=()):
        return factory.reset(Script(answers, secrets), self.fake_run, self.snapshot, self.new_owner(devices),
                             self.installation, hostname='studio')

    def test_guard_rails_refuse_before_anything_changes(self):
        cases = []
        missing = self.base / 'missing.json'
        cases.append((lambda: factory.preflight(self.snapshot, missing), 'installed from the CybexOS ISO'))
        for kind, message in (('recovery', 'temporary recovery boot'), ('none', 'standard Btrfs layout')):
            fake = FakeSnapshot(self.base / f'top-{kind}', kind=kind)
            cases.append((lambda fake=fake: factory.preflight(fake, self.installation), message))
        pending = FakeSnapshot(self.base / 'top-pending', running='/root.replaced-20260903T000000Z')
        cases.append((lambda: factory.preflight(pending, self.installation), 'waiting for a restart'))
        bare = FakeSnapshot(self.base / 'top-bare', factory_point='')
        cases.append((lambda: factory.preflight(bare, self.installation), 'no factory recovery point'))
        busy = FakeSnapshot(self.base / 'top-busy')
        journal = self.base / 'top-busy/cybexos-snapshots/transactions/run-1/transaction.json'
        journal.parent.mkdir(parents=True)
        journal.write_text('{"state": "applying"}')
        cases.append((lambda: factory.preflight(busy, self.installation), 'update has not finished'))
        for action, message in cases:
            with self.subTest(message=message), self.assertRaises(factory.Failure) as caught:
                action()
            self.assertIn(message, str(caught.exception))
        journal.write_text('{"state": "committed"}')
        self.assertEqual(factory.preflight(busy, self.installation)[1], '20260801T120000Z-1')

    def test_wrong_confirmation_changes_nothing(self):
        with self.assertRaises(factory.Failure):
            self.reset(['Studio'])
        self.assertEqual(self.calls, [])
        self.assertFalse((self.top / 'root' / factory.MARKER).exists())

    def test_confirmed_reset_restores_the_factory_point_and_marks_the_restored_root(self):
        self.assertEqual(self.reset(['studio', 'n']), 0)
        self.assertEqual(self.calls, [[str(factory.LIBEXEC / 'cybexos-system-snapshot'), 'restore', '20260801T120000Z-1']])
        marker = json.loads((self.top / 'root' / factory.MARKER).read_text())
        self.assertEqual(marker['point'], '20260801T120000Z-1')
        self.assertEqual(self.reset(['erase', 'y']), 0)
        self.assertEqual(self.calls[-1], ['systemctl', 'reboot'])

    def test_encrypted_disk_moves_to_a_temporary_passphrase_first(self):
        self.luks = FakeLuks('old owner passphrase')
        with self.assertRaises(factory.Failure):
            self.reset(['studio'], ['not it at all'], devices=['/dev/vda3'])
        self.assertEqual(self.calls, [])
        self.assertEqual(self.reset(['studio', 'n'], ['old owner passphrase', 'temporary handover 1',
                                                     'temporary handover 1'], devices=['/dev/vda3']), 0)
        self.assertEqual(list(self.luks.slots.values()), ['temporary handover 1'])
        self.assertEqual(self.calls[0][1], 'restore')

    def test_failed_restore_says_what_already_happened(self):
        def failing(command, **kwargs):
            self.calls.append(command)
            return done(returncode=1)

        with self.assertRaises(factory.Failure) as caught:
            factory.reset(Script(['studio']), failing, self.snapshot, self.new_owner(), self.installation,
                          hostname='studio')
        self.assertIn('accounts and files are unchanged', str(caught.exception))
        self.assertFalse((self.top / 'root' / factory.MARKER).exists())

    def restored_root(self):
        root = self.base / 'restored'
        for directory in ('etc/cybexos', 'etc/sudoers.d', 'etc/ssh', 'var/lib/AccountsService/users',
                          'var/lib/cybexos/first-boot', 'home/alice/Documents', 'home/bob', 'home/alice/nested/deep'):
            (root / directory).mkdir(parents=True, exist_ok=True)
        (root / 'etc/passwd').write_text('root:x:0:0::/root:/bin/bash\nalice:x:1000:1000::/home/alice:/bin/bash\n'
                                         'svc:x:1500:1500::/srv/svc:/sbin/nologin\n')
        (root / 'home/alice/Documents/private.txt').write_text('personal\n')
        (root / 'home/alice/nested/deep/file').write_text('in a nested subvolume\n')
        (root / 'var/lib/AccountsService/users/alice').write_text('[User]\n')
        (root / 'var/lib/cybexos/first-boot/tailscale-authkey').write_text('tskey-auth-fixture\n')
        (root / 'etc/ssh/ssh_host_ed25519_key').write_text('host key\n')
        (root / 'etc/sudoers.d/10-wheel-nopasswd').write_text('%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n')
        (root / 'etc/cybexos/config.yml').write_text(
            "primary_user: 'alice'\npasswordless_wheel: true\ndesktop_autologin: true\nmanage_personal_dotfiles: false\n"
            "docker_sudoless: false\nfeatures:\n  steam: false\n  docker: true\n")
        (root / 'etc/cybexos/installation.json').write_text('{"username": "alice", "encrypted": true}\n')
        (root / factory.MARKER).write_text('{"version": 1}\n')
        return root

    def test_finish_erases_people_and_history_but_keeps_choices_and_the_factory_point(self):
        root = self.restored_root()
        store = self.top / 'cybexos-snapshots'
        (self.top / 'root.replaced-20260903T000000Z').mkdir()
        (store / 'replaced/root.replaced-20260903T000000Z.json').write_text('{}')
        (store / 'transactions/run-1').mkdir(parents=True)
        (store / 'metadata/20260902T120000Z-3.pin').write_text('run-1\n')
        nested = root / 'home/alice/nested'

        def devices(path):
            return 2 if path == nested else 1
        self.assertTrue(factory.finish(root, self.fake_run, self.snapshot, policy, devices))
        self.assertIn(['btrfs', 'subvolume', 'delete', '--recursive', str(nested)], self.calls)
        self.assertEqual(list((root / 'home').iterdir()), [])
        self.assertIn(['userdel', '--force', '--remove', 'alice'], self.calls)
        self.assertNotIn('svc', json.dumps(self.calls))
        self.assertFalse((root / 'var/lib/AccountsService/users/alice').exists())
        self.assertEqual(sorted(path.name for path in (store / 'root').iterdir()), ['20260801T120000Z-1'])
        self.assertFalse((self.top / 'root.replaced-20260903T000000Z').exists())
        self.assertFalse((store / 'transactions').exists())
        self.assertEqual(list((store / 'replaced').iterdir()), [])
        self.assertEqual((store / 'latest').read_text(), '20260801T120000Z-1\n')
        choices = json.loads((root / 'etc/cybexos/install-choices.json').read_text())
        self.assertEqual(choices, {'version': 1, 'choices': {'manage_personal_dotfiles': False, 'docker_sudoless': False,
                                                             'features': {'steam': False, 'docker': True}}})
        self.assertEqual(json.loads((root / 'etc/cybexos/oem.json').read_text()),
                         {'version': 1, 'passwordless_wheel': True})
        self.assertEqual(json.loads((root / 'etc/cybexos/login.json').read_text())['user'], '')
        for gone in ('etc/cybexos/config.yml', 'etc/sudoers.d/10-wheel-nopasswd', 'etc/ssh/ssh_host_ed25519_key',
                     'var/lib/cybexos/first-boot', factory.MARKER):
            self.assertFalse((root / gone).exists(), gone)
        record = json.loads((root / 'etc/cybexos/installation.json').read_text())
        self.assertEqual((record['username'], record['oem'], record['encrypted']), ('', True, True))
        self.assertFalse(factory.finish(root, self.fake_run, self.snapshot, policy, devices))

    def test_finish_refuses_to_descend_into_another_mount(self):
        root = self.restored_root()
        mounted = root / 'home/alice/nested'

        def refuse(command, **kwargs):
            self.calls.append(command)
            return done(returncode=1 if command[0] == 'btrfs' else 0)

        with self.assertRaises(factory.Failure):
            factory.finish(root, refuse, self.snapshot, policy, lambda path: 2 if path == mounted else 1)
        self.assertTrue((mounted / 'deep/file').exists())
        self.assertTrue((root / factory.MARKER).exists())

    def test_dispatchers_offer_reset_only_on_iso_installations(self):
        iso = (ROOT / 'image/rootfs/usr/bin/cybex').read_text()
        self.assertIn('factory-reset) exec sudo /usr/libexec/cybexos-factory-reset reset "$@"', iso)
        checkout = (ROOT / 'roles/dotfiles/templates/cybex.j2').read_text()
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'cybex'
            # Render the template as Ansible does, so every helper path the
            # dispatcher names resolves, including ones other commands add.
            import jinja2
            import shlex
            environment = jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
            environment.filters['quote'] = shlex.quote
            script.write_text(environment.from_string(checkout).render(primary_home='/nonexistent'))
            result = subprocess.run(['bash', str(script), 'factory-reset'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('available only on a system installed from the CybexOS ISO', result.stderr)


class FirstBootTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.state = self.base / 'var/lib/cybexos'
        self.runtime = self.base / 'run/cybexos/first-boot'
        self.state.mkdir(parents=True)
        self.calls = []

    def fake_run(self, command, **kwargs):
        self.calls.append(command)
        return done(returncode=self.code)

    code = 0

    def test_secrets_leave_the_disk_before_the_factory_point(self):
        (self.state / 'first-boot').mkdir(mode=0o700)
        (self.state / 'first-boot/tailscale-authkey').write_text('tskey-auth-fixture')
        self.assertEqual(first_boot.move_secrets(self.state, self.runtime), ['tailscale-authkey'])
        self.assertFalse((self.state / 'first-boot').exists())
        moved = self.runtime / 'tailscale-authkey'
        self.assertEqual(moved.read_text(), 'tskey-auth-fixture')
        self.assertEqual(moved.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.runtime.stat().st_mode & 0o777, 0o700)
        self.assertEqual(first_boot.move_secrets(self.state, self.runtime), [])

    def test_factory_point_is_taken_once(self):
        self.assertEqual(first_boot.factory_point(FakeSnapshot(self.base / 'top', factory_point=''), self.state, self.fake_run), 'none')
        (self.state / first_boot.PENDING).write_text('{}')
        self.code = 1
        with self.assertRaises(RuntimeError):
            first_boot.factory_point(FakeSnapshot(self.base / 'top1', factory_point=''), self.state, self.fake_run)
        self.assertTrue((self.state / first_boot.PENDING).exists())
        self.code = 0
        self.assertEqual(first_boot.factory_point(FakeSnapshot(self.base / 'top2', factory_point=''), self.state, self.fake_run),
                         'created')
        self.assertEqual(self.calls[-1][1:], ['create', '--factory', 'factory state'])
        self.assertFalse((self.state / first_boot.PENDING).exists())
        # A restored factory root still carries the marker; the point exists.
        (self.state / first_boot.PENDING).write_text('{}')
        self.assertEqual(first_boot.factory_point(FakeSnapshot(self.base / 'top3'), self.state, self.fake_run), 'exists')
        (self.state / first_boot.PENDING).write_text('{}')
        self.assertEqual(first_boot.factory_point(FakeSnapshot(self.base / 'top4', kind='none'), self.state, self.fake_run),
                         'unsupported')
        self.assertEqual(len(self.calls), 2)

    def test_tailscale_key_is_used_from_a_file_once_and_deleted(self):
        self.runtime.mkdir(parents=True)
        key = self.runtime / 'tailscale-authkey'
        for code in (0, 1):
            key.write_text('tskey-auth-fixture')
            self.code = code
            with patch.object(first_boot, 'log'):
                self.assertEqual(first_boot.enroll_tailscale(self.runtime, self.fake_run), code == 0)
            self.assertFalse(key.exists())
            self.assertEqual(self.calls[-1][:3], ['tailscale', 'up', f'--auth-key=file:{key}'])
            self.assertNotIn('tskey-auth-fixture', ' '.join(self.calls[-1]))
        self.assertFalse(first_boot.enroll_tailscale(self.runtime, self.fake_run))

    def test_units_order_the_first_start_before_any_login(self):
        units = ROOT / 'image/rootfs/usr/lib/systemd/system'
        first = (units / 'cybexos-first-boot.service').read_text()
        self.assertIn('ConditionPathExists=|/var/lib/cybexos/factory-point.pending', first)
        self.assertIn('Before=systemd-user-sessions.service display-manager.service cybexos-new-owner.service', first)
        enroll = (units / 'cybexos-tailscale-enroll.service').read_text()
        # Started on demand only, so ordinary boots never wait for the network.
        self.assertNotIn('[Install]', enroll)
        spec = (ROOT / 'image/cybexos-desktop.spec').read_text()
        for name in ('cybexos-first-boot.service', 'cybexos-new-owner.service', 'cybexos-tailscale-enroll.service'):
            self.assertIn(f'/usr/lib/systemd/system/{name}', spec)
        self.assertIn('systemctl enable cybexos-first-boot.service cybexos-new-owner.service', spec)
        for helper in ('cybexos-first-boot', 'cybexos-new-owner', 'cybexos-factory-reset'):
            self.assertTrue(os.access(LIBEXEC / helper, os.X_OK), helper)



# ---- the graphical setup's root side ------------------------------------------------

EVDEV = """! model
  pc105           Generic 105-key PC

! layout
  us              English (US)
  nl              Dutch
  de              German

! variant
  dvorak          us: English (Dvorak)
  nodeadkeys      de: German (no dead keys)
  bad;name        us: Not a valid name
  orphan          xx: Unknown layout

! option
  grp             Switching to another layout
"""


def message(kind, **fields):
    return json.dumps({'type': kind, **fields}).encode()


class RulesTests(unittest.TestCase):
    def test_codes_and_console_messages_are_the_same_rules(self):
        self.assertEqual(owner.password_problem('short', 'short'), 'password-length')
        self.assertEqual(owner.password_problem('x' * 513, 'x' * 513), 'password-length')
        self.assertEqual(owner.password_problem('twelve chars\x7f', 'twelve chars\x7f'), 'password-control')
        self.assertEqual(owner.password_problem('twelve chars', 'twelve charz'), 'password-mismatch')
        self.assertEqual(owner.password_problem('twelve chars', 'twelve chars'), '')
        self.assertEqual(owner.validate_password('short', 'short'), 'Use a password of 12–512 characters.')
        self.assertEqual(owner.username_problem('Alice'), 'username-format')
        self.assertEqual(owner.username_problem('sddm'), 'username-reserved')
        self.assertEqual(owner.username_problem('taken', {'taken'}), 'username-taken')
        self.assertEqual(owner.username_problem('alice', {'taken'}), '')
        self.assertEqual(owner.full_name_problem('Alice: Example'), 'full-name')
        self.assertEqual(owner.full_name_problem('x' * 129), 'full-name')
        self.assertEqual(owner.full_name_problem('Alice Example'), '')

    def test_usernames_are_suggested_from_the_first_name(self):
        for full_name, expected in (('Alice Example', 'alice'), ('Jörg Smit', 'jorg'), ('  Jean-Luc Picard', 'jean-luc'),
                                    ('42 Douglas', ''), ('李 明', ''), ('', '')):
            self.assertEqual(owner.derive_username(full_name), expected, full_name)
            if expected:
                self.assertEqual(owner.username_problem(expected), '')

    def test_keyboards_come_from_xkeyboard_config_with_labels(self):
        with tempfile.TemporaryDirectory() as temporary:
            rules = Path(temporary) / 'evdev.lst'
            rules.write_text(EVDEV)
            choices = owner.keyboard_choices(rules)
            self.assertEqual(choices, [{'id': 'nl', 'label': 'Dutch'},
                                       {'id': 'us (dvorak)', 'label': 'English (Dvorak)'},
                                       {'id': 'us', 'label': 'English (US)'},
                                       {'id': 'de', 'label': 'German'},
                                       {'id': 'de (nodeadkeys)', 'label': 'German (no dead keys)'}])
            # Without the list, localed's own names.
            choices = owner.keyboard_choices(Path(temporary) / 'missing', lists)
            self.assertEqual([choice['id'] for choice in choices], ['de', 'nl', 'us'])
        self.assertEqual(owner.split_keyboard('us (dvorak)'), ('us', 'dvorak'))
        self.assertEqual(owner.split_keyboard('nl'), ('nl', ''))
        for invalid in ('us(dvorak)', 'us (a b)', '', 'us; rm', None):
            self.assertIsNone(owner.split_keyboard(invalid))

    def test_languages_are_the_installed_utf8_locales(self):
        def run(command, **kwargs):
            return done(stdout='C.UTF-8\nen_US.UTF-8\nnl_NL.UTF-8\nsr_RS.UTF-8@latin\nde_DE.ISO-8859-1\nPOSIX\n')

        self.assertEqual(owner.locale_choices(run), ['en_US.UTF-8', 'nl_NL.UTF-8', 'sr_RS.UTF-8@latin'])
        self.assertEqual(owner.timezone_choices(lists), ['America/New_York', 'Europe/Amsterdam', 'UTC'])


class ProtocolTests(unittest.TestCase):
    """What the unprivileged window may send, and what ends the conversation."""

    def submit(self, **changes):
        fields = dict(locale='en_US.UTF-8', timezone='UTC', full_name='', username='alice',
                      password='new owner password', confirm='new owner password', startup='')
        fields.update(changes)
        return message('submit', **fields)

    def test_well_formed_messages_parse(self):
        self.assertEqual(owner.parse_message(message('ready')), {'type': 'ready'})
        self.assertEqual(owner.parse_message(message('keyboard', keyboard='us', locale='en_US.UTF-8'))['keyboard'], 'us')
        self.assertEqual(owner.parse_message(self.submit())['username'], 'alice')

    def test_malformed_unknown_and_oversized_messages_are_refused(self):
        refused = [b'not json', b'\xff\xfe', b'[]', b'"ready"', message('shell', command='id'),
                   message('ready', extra='x'), self.submit()[:-1] + b', "extra": "x"}',
                   json.dumps({'type': 'submit', 'username': 'alice'}).encode(),
                   self.submit(password=7), self.submit(password=None), self.submit(password='x' * 601),
                   self.submit(full_name='x' * 201), b'{"type": "ready"}' + b' ' * owner.MAX_MESSAGE]
        for line in refused:
            with self.assertRaises(owner.ProtocolError, msg=line[:40]):
                owner.parse_message(line)

    def test_refusals_never_repeat_what_was_sent(self):
        secret = 'new owner password'
        for line in (self.submit(password=secret, confirm=secret, startup=secret)[:-2], self.submit(password=[secret])):
            with self.assertRaises(owner.ProtocolError) as raised:
                owner.parse_message(line)
            self.assertNotIn(secret, str(raised.exception))

    def reader(self, chunks):
        chunks = list(chunks)
        clock = [0.0]

        def wait(readers, writers, errors, timeout):
            if chunks and chunks[0] is None:
                chunks.pop(0)
                clock[0] += timeout or 0
                return [], [], []
            return readers, [], []

        def read(fd, size):
            return chunks.pop(0) if chunks else b''

        return owner.LineReader(3, wait=wait, read=read, clock=lambda: clock[0])

    def test_lines_are_split_capped_and_timed_out(self):
        reader = self.reader([b'{"type": "re', b'ady"}\n{"type": "active"}\n'])
        self.assertEqual(reader.receive(5), {'type': 'ready'})
        self.assertEqual(reader.receive(5), {'type': 'active'})
        with self.assertRaises(EOFError):
            reader.receive(5)
        self.assertIsNone(self.reader([None]).receive(5))
        # A line that never ends is refused once it passes the limit.
        flood = self.reader([b'x' * 4096] * (owner.MAX_MESSAGE // 4096 + 2))
        with self.assertRaises(owner.ProtocolError):
            flood.receive(5)


class FakeTerminal:
    """ioctl on a console: records modes; `vt=False` behaves like a serial line."""

    def __init__(self, vt=True, keyboard=3):
        self.vt, self.keyboard, self.calls = vt, keyboard, []

    def __call__(self, fd, request, argument=0):
        if not self.vt:
            raise OSError(25, 'Inappropriate ioctl for device')
        self.calls.append((request, argument))
        if request == owner.KDGKBMODE:
            return owner.struct.pack('i', self.keyboard)
        return 0


class CommandTests(unittest.TestCase):
    def test_the_window_runs_as_a_transient_unprivileged_user_without_secrets(self):
        command = owner.gui_command('de (nodeadkeys)')
        self.assertEqual(command[:5], [str(owner.SYSTEMD_RUN), '--quiet', '--wait', '--pipe', '--collect'])
        self.assertIn(f'--unit={owner.GUI_UNIT}', command)
        for setting in ('--property=DynamicUser=yes', '--property=SupplementaryGroups=video input render',
                        '--property=RuntimeDirectory=cybexos-new-owner-gui', '--property=RuntimeDirectoryMode=0700',
                        '--property=NoNewPrivileges=yes', '--property=RestrictAddressFamilies=AF_UNIX AF_NETLINK',
                        '--setenv=XDG_RUNTIME_DIR=/run/cybexos-new-owner-gui', '--setenv=LIBSEAT_BACKEND=noop',
                        '--setenv=XKB_DEFAULT_LAYOUT=de', '--setenv=XKB_DEFAULT_VARIANT=nodeadkeys',
                        '--setenv=QT_QUICK_BACKEND=software'):
            self.assertIn(setting, command)
        program = command[command.index('--') + 1:]
        self.assertEqual(program, [str(owner.CAGE), '-d', '--', '/usr/bin/python3', '-I', str(owner.GUI)])
        self.assertFalse(any(item.startswith(('--uid', '--property=User=')) for item in command))
        self.assertNotIn('--setenv=XKB_DEFAULT_VARIANT=', ' '.join(owner.gui_command('us')))
        # Only names from the list reach cage; anything else is the US layout.
        self.assertIn('--setenv=XKB_DEFAULT_LAYOUT=us', owner.gui_command('us; reboot'))

    def test_the_console_hands_over_screen_and_keyboard_and_gets_them_back(self):
        terminal = FakeTerminal()
        flushed = []
        with owner.graphics_mode(0, terminal, lambda fd, queue: flushed.append(queue)):
            self.assertEqual(terminal.calls[1:], [(owner.KDSETMODE, owner.KD_GRAPHICS), (owner.KDSKBMODE, owner.K_OFF)])
        self.assertEqual(terminal.calls[-2:], [(owner.KDSKBMODE, 3), (owner.KDSETMODE, owner.KD_TEXT)])
        # Anything typed meanwhile never reaches the console.
        self.assertEqual(flushed, [owner.termios.TCIFLUSH])
        terminal = FakeTerminal()
        with self.assertRaises(RuntimeError):
            with owner.graphics_mode(0, terminal, lambda fd, queue: None):
                raise RuntimeError('the window crashed')
        self.assertEqual(terminal.calls[-1], (owner.KDSETMODE, owner.KD_TEXT))
        with self.assertRaises(owner.Unavailable):
            with owner.graphics_mode(0, FakeTerminal(vt=False)):
                pass

    def test_a_session_pipes_answers_and_stops_its_unit(self):
        started, calls = [], []

        class Process:
            def __init__(self, command, **kwargs):
                started.append((command, kwargs))
                self.stdin, self.stdout = tempfile.TemporaryFile(), tempfile.TemporaryFile()

            def wait(self, timeout=None):
                # The window ignores the closed pipe until its unit is stopped.
                if len(calls) < 3:
                    raise subprocess.TimeoutExpired('systemd-run', timeout)

            def kill(self):
                calls.append('kill')

        def run(command, **kwargs):
            calls.append(command)
            return done()

        modes = []

        @contextlib.contextmanager
        def terminal():
            modes.append('graphics')
            yield
            modes.append('text')

        session = owner.Session('us', run, Process, terminal)
        session.start()
        self.assertEqual(started[0][0], owner.gui_command('us'))
        self.assertEqual(started[0][1], {'stdin': subprocess.PIPE, 'stdout': subprocess.PIPE})
        self.assertEqual(calls[:2], [['systemctl', 'stop', owner.GUI_UNIT], ['systemctl', 'reset-failed', owner.GUI_UNIT]])
        session.send({'type': 'init'})
        session.stop()
        self.assertIn(['systemctl', 'stop', owner.GUI_UNIT], calls[2:])
        self.assertEqual(modes, ['graphics', 'text'])
        session.stop()
        self.assertEqual(modes, ['graphics', 'text'], 'stopping twice is harmless')

        def missing(command, **kwargs):
            raise FileNotFoundError(command[0])

        with self.assertRaises(owner.NotStarted):
            owner.Session('us', run, missing, terminal).start()
        self.assertEqual(modes[-2:], ['graphics', 'text'])


class FallbackTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.top = Path(self.temporary.name)
        self.dev = self.top / 'dev'
        for path in ('dri/card1', 'input/event0'):
            (self.dev / path).parent.mkdir(parents=True, exist_ok=True)
            (self.dev / path).write_text('')
        self.cmdline = self.top / 'cmdline'
        self.cmdline.write_text('BOOT_IMAGE=/vmlinuz root=UUID=x quiet\n')
        self.programs = {}
        for name in ('CAGE', 'SYSTEMD_RUN', 'GUI', 'QML'):
            path = self.top / name.lower()
            path.write_text('')
            self.programs[name] = path

    def unavailable(self, find_spec=lambda name: object()):
        with patch.multiple(owner, **self.programs):
            return owner.graphical_unavailable(self.cmdline, self.dev, find_spec)

    def test_each_missing_piece_selects_the_console(self):
        self.assertEqual(self.unavailable(), '')
        self.assertIn('PySide6', self.unavailable(lambda name: None))
        self.cmdline.write_text('quiet cybexos.new-owner=console\n')
        self.assertIn('kernel command line', self.unavailable())
        self.cmdline.write_text('quiet\n')
        (self.dev / 'input/event0').unlink()
        self.assertIn('input device', self.unavailable())
        (self.dev / 'dri/card1').unlink()
        self.assertIn('graphics device', self.unavailable())
        self.programs['CAGE'].unlink()
        self.assertIn('cage', self.unavailable())

    def main(self, graphical, unavailable=lambda: ''):
        """main() with a console that answers at once; returns what happened."""
        root = self.top / 'root'
        (root / 'etc/cybexos').mkdir(parents=True, exist_ok=True)
        (root / 'etc/cybexos/oem.json').write_text('{"version": 1, "passwordless_wheel": false}\n')
        calls, logged, consoled = [], [], []

        def run(command, **kwargs):
            calls.append(command)
            return done()

        def collect(console, run, devices):
            consoled.append(devices)
            return {}

        with patch.object(owner.os, 'geteuid', return_value=0), \
                patch.object(owner, 'luks_devices', return_value=[]), \
                patch.object(owner, 'collect', collect), patch.object(owner, 'apply'), \
                patch.object(owner, 'summary', return_value=True), patch.object(owner.time, 'sleep'), \
                patch.object(owner, 'log', logged.append):
            result = owner.main(Script([]), run, graphical, unavailable, root)
        return result, calls, consoled, logged

    def test_main_uses_the_window_and_restarts_without_the_console(self):
        class Works:
            def __init__(self, state, run):
                self.state = state

            def run_window(self):
                return True

        result, calls, consoled, _ = self.main(Works)
        self.assertEqual((result, consoled), (0, []))
        self.assertEqual(calls[-1], ['systemctl', '--no-block', 'reboot'])

    def test_main_falls_back_to_the_console_when_the_window_cannot_help(self):
        class Fails:
            error = owner.Unavailable('the setup window closed')

            def __init__(self, state, run):
                pass

            def run_window(self):
                raise self.error

        for error in (owner.Unavailable('the setup window closed'), owner.ProtocolError('malformed'),
                      KeyError('a bug in the window path')):
            Fails.error = error
            result, calls, consoled, logged = self.main(Fails)
            self.assertEqual(len(consoled), 1, error)
            self.assertTrue(any('asking on the console' in line for line in logged))
        result, calls, consoled, logged = self.main(Fails, unavailable=lambda: 'there is no graphics device')
        self.assertEqual(len(consoled), 1)
        self.assertIn('asking on the console: there is no graphics device', logged)


class FakeSession:
    """A scripted window: `inbox` items are messages, None (a timeout) or EOFError."""

    def __init__(self, keyboard, inbox, sessions):
        self.keyboard, self.inbox, self.sent, self.timeouts = keyboard, list(inbox), [], []
        self.stopped = False
        sessions.append(self)

    def start(self):
        pass

    def send(self, message):
        self.sent.append(message)

    def receive(self, timeout=None):
        self.timeouts.append(timeout)
        item = self.inbox.pop(0) if self.inbox else EOFError()
        if isinstance(item, BaseException):
            raise item
        return item

    def stop(self):
        self.stopped = True


class GraphicalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'etc').mkdir()
        (self.root / 'etc/vconsole.conf').write_text('KEYMAP="us"\n')
        self.passwd = self.root / 'etc/passwd'
        self.passwd.write_text('root:x:0:0::/root:/bin/bash\ntaken:x:1000:1000::/home/taken:/bin/bash\n')
        self.rules = self.root / 'evdev.lst'
        self.rules.write_text(EVDEV)
        self.luks = FakeLuks('temporary handover 1')
        self.calls, self.applied, self.logged = [], [], []
        self.failures = []
        patcher = patch.object(owner, 'XKB_RULES', self.rules)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.object(owner, 'log', self.logged.append)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.object(owner.time, 'sleep')
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_command(self, command, **kwargs):
        if command[0] == 'cryptsetup':
            return self.luks(command, **kwargs)
        self.calls.append(command)
        if command[:2] == ['localectl', 'set-x11-keymap']:
            keymap = {'us': 'us', 'de': 'de-nodeadkeys', 'nl': ''}[command[2]]
            (self.root / 'etc/vconsole.conf').write_text(f'KEYMAP="{keymap}"\n' if keymap else '')
        return lists(command, **kwargs)

    def apply(self, answers, state, devices, run, progress):
        if self.failures:
            raise self.failures.pop(0)
        for stage in ('account', 'desktop', 'disk', 'finish'):
            progress(stage)
        self.applied.append(dict(answers))

    def setup(self, scripts, devices=('/dev/vda3',)):
        sessions = []
        scripts = list(scripts)

        def session(keyboard, run):
            return FakeSession(keyboard, scripts.pop(0), sessions)

        graphical = owner.GraphicalSetup({'version': 1}, self.run_command, session, devices, self.passwd, self.apply,
                                         {'keyboard': 'us', 'locale': 'nl_NL.UTF-8', 'timezone': 'Europe/Amsterdam'},
                                         self.root)
        return graphical, sessions

    @staticmethod
    def submit(**changes):
        fields = dict(locale='nl_NL.UTF-8', timezone='Europe/Amsterdam', full_name='Alice Example',
                      username='alice', password='new owner password', confirm='new owner password',
                      startup='temporary handover 1')
        fields.update(changes)
        return {'type': 'submit', **fields}

    def assert_no_secret_escaped(self, sessions):
        for secret in SECRETS:
            self.assertNotIn(secret, '\n'.join(self.logged))
            for command in self.calls:
                self.assertNotIn(secret, ' '.join(command))
            for session in sessions:
                self.assertNotIn(secret, json.dumps(session.sent))

    def test_a_full_setup_with_a_new_layout_and_a_wrong_passphrase_first(self):
        ready, active = {'type': 'ready'}, {'type': 'active'}
        graphical, sessions = self.setup([
            [ready, active, {'type': 'keyboard', 'keyboard': 'de (nodeadkeys)', 'locale': 'nl_NL.UTF-8'}],
            [ready, self.submit(startup='old owner passphrase'), self.submit(username='taken'),
             self.submit(confirm='new owner passworx'), self.submit(), {'type': 'restart'}],
        ])
        self.assertTrue(graphical.run_window())
        first, second = sessions
        init = first.sent[0]
        self.assertEqual((init['type'], init['encrypted'], init['keyboard'], init['locale'], init['focus']),
                         ('init', True, 'us', 'nl_NL.UTF-8', ''))
        self.assertIn({'id': 'de (nodeadkeys)', 'label': 'German (no dead keys)'}, init['keyboards'])
        self.assertEqual(init['taken'], ['root', 'taken'])
        self.assertEqual(first.timeouts, [owner.READY_TIMEOUT, owner.INPUT_TIMEOUT, None])
        # The layout is applied to the system and cage restarts with it.
        self.assertIn(['localectl', 'set-x11-keymap', 'de', '', 'nodeadkeys'], self.calls)
        self.assertEqual(first.sent[-1], {'type': 'restart'})
        self.assertEqual((second.keyboard, second.sent[0]['keyboard'], second.sent[0]['focus']),
                         ('de (nodeadkeys)', 'de (nodeadkeys)', 'keyboard-test'))
        errors = [item for item in second.sent if item['type'] == 'error']
        self.assertEqual(errors, [{'type': 'error', 'field': 'startup', 'code': 'startup-wrong'},
                                  {'type': 'error', 'field': 'username', 'code': 'username-taken'},
                                  {'type': 'error', 'field': 'confirm', 'code': 'password-mismatch'}])
        self.assertEqual([item['stage'] for item in second.sent if item['type'] == 'progress'],
                         ['account', 'desktop', 'disk', 'finish'])
        self.assertEqual(second.sent[-1], {'type': 'done'})
        self.assertEqual(self.applied, [dict(keyboard='de (nodeadkeys)', locale='nl_NL.UTF-8',
                                             timezone='Europe/Amsterdam', full_name='Alice Example',
                                             username='alice', password='new owner password',
                                             startup='temporary handover 1')])
        self.assertTrue(first.stopped and second.stopped)
        self.assert_no_secret_escaped(sessions)

    def test_failed_apply_is_reported_and_can_be_tried_again(self):
        self.failures = [owner.SetupError('The new passphrase could not be added to /dev/vda3. Nothing was removed.'),
                         subprocess.CalledProcessError(1, ['useradd', 'alice'])]
        graphical, sessions = self.setup([[{'type': 'ready'}, self.submit(), self.submit(), self.submit(), EOFError()]])
        self.assertTrue(graphical.run_window())
        errors = [item for item in sessions[0].sent if item['type'] == 'error']
        self.assertEqual(errors[0]['code'], 'failed')
        self.assertIn('could not be added', errors[0]['detail'])
        self.assertEqual(errors[1], {'type': 'error', 'field': '', 'code': 'failed', 'detail': ''})
        self.assertEqual(len(self.applied), 1)
        self.assertTrue(any('CalledProcessError' in line for line in self.logged))
        self.assert_no_secret_escaped(sessions)

    def test_a_layout_the_unlock_prompt_cannot_use_is_refused_on_an_encrypted_disk(self):
        graphical, sessions = self.setup([[{'type': 'ready'}, {'type': 'keyboard', 'keyboard': 'nl', 'locale': 'nl_NL.UTF-8'},
                                           {'type': 'keyboard', 'keyboard': 'qwerty', 'locale': 'nl_NL.UTF-8'}, EOFError()]])
        with self.assertRaises(owner.Unavailable):
            graphical.run_window()
        sent = sessions[0].sent
        self.assertEqual(sent[1:], [{'type': 'error', 'field': 'keyboard', 'code': 'boot-keymap'},
                                    {'type': 'error', 'field': 'keyboard', 'code': 'choice'}])
        # The previous layout is back.
        self.assertEqual(self.calls[-1], ['localectl', 'set-x11-keymap', 'us', '', ''])
        self.assertEqual(graphical.keyboard, 'us')
        graphical, sessions = self.setup([[{'type': 'ready'}, {'type': 'keyboard', 'keyboard': 'nl', 'locale': 'en_US.UTF-8'}],
                                          [{'type': 'ready'}, EOFError()]], devices=[])
        with self.assertRaises(owner.Unavailable):
            graphical.run_window()
        self.assertEqual(sessions[0].sent[-1], {'type': 'restart'}, 'an unencrypted disk has no unlock prompt')
        self.assertEqual(sessions[1].sent[0]['locale'], 'en_US.UTF-8', 'the language survives the restart')

    def test_a_window_that_never_appears_is_tried_twice_then_the_console_asks(self):
        graphical, sessions = self.setup([[None], [EOFError()]])
        with self.assertRaises(owner.NotStarted):
            graphical.run_window()
        self.assertEqual(len(sessions), owner.START_ATTEMPTS)
        self.assertTrue(all(session.stopped for session in sessions))

    def test_no_key_press_or_a_broken_protocol_ends_the_window(self):
        graphical, sessions = self.setup([[{'type': 'ready'}, None]])
        with self.assertRaisesRegex(owner.Unavailable, 'key press'):
            graphical.run_window()
        graphical, sessions = self.setup([[{'type': 'ready'}, owner.ProtocolError('the window sent a malformed message')]])
        with self.assertRaises(owner.ProtocolError):
            graphical.run_window()
        self.assertTrue(sessions[0].stopped)

    def test_after_setup_a_closed_window_still_counts_as_done(self):
        graphical, sessions = self.setup([[{'type': 'ready'}, self.submit(), EOFError()]])
        self.assertTrue(graphical.run_window())
        graphical, sessions = self.setup([[{'type': 'ready'}, self.submit(), None]])
        self.assertTrue(graphical.run_window())
        self.assertEqual(sessions[0].timeouts[-1], 60)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'etc/cybexos').mkdir(parents=True)
        (self.root / 'etc/cybexos/oem.json').write_text('{"version": 1}\n')
        (self.root / 'var/lib/AccountsService/users').mkdir(parents=True)
        (self.root / 'var/lib/AccountsService/users/alice').write_text('[User]\n')
        (self.root / 'etc/cybexos/config.yml').write_text('recorded\n')
        self.calls = []

    def run_command(self, command, **kwargs):
        self.calls.append(command)
        return done()

    def entry(self, uid, home):
        return lambda name: types.SimpleNamespace(pw_uid=uid, pw_dir=home)

    def record(self, username='alice'):
        (self.root / owner.PENDING).write_text(json.dumps({'version': 1, 'username': username,
                                                           'choices': '{"version": 1, "choices": {}}\n'}))

    def test_an_interrupted_attempt_is_undone_at_the_next_start(self):
        self.record()
        with patch.object(owner, 'log'):
            self.assertEqual(owner.recover_interrupted(self.root, self.run_command, self.entry(1000, '/home/alice')),
                             'alice')
        self.assertEqual(self.calls, [['userdel', '--force', '--remove', 'alice']])
        self.assertFalse((self.root / 'var/lib/AccountsService/users/alice').exists())
        self.assertFalse((self.root / 'etc/cybexos/config.yml').exists())
        self.assertEqual(json.loads((self.root / 'etc/cybexos/install-choices.json').read_text())['version'], 1)
        self.assertFalse((self.root / owner.PENDING).exists())

    def test_system_accounts_and_finished_setups_are_never_touched(self):
        self.record('chrony')
        owner.recover_interrupted(self.root, self.run_command, self.entry(1000, '/home/chrony'))
        self.record('backup')
        owner.recover_interrupted(self.root, self.run_command, self.entry(34, '/var/lib/backup'))
        self.assertEqual(self.calls, [])
        self.assertFalse((self.root / owner.PENDING).exists())
        self.record()
        (self.root / 'etc/cybexos/oem.json').unlink()
        owner.recover_interrupted(self.root, self.run_command, self.entry(1000, '/home/alice'))
        self.assertEqual(self.calls, [])

    def test_unit_hands_the_console_to_the_setup_and_logs_to_the_journal(self):
        unit = (ROOT / 'image/rootfs/usr/lib/systemd/system/cybexos-new-owner.service').read_text()
        self.assertIn('StandardInput=tty\n', unit)
        self.assertIn('StandardError=journal\n', unit)
        self.assertIn('ExecStart=/usr/libexec/cybexos-new-owner\n', unit)
        self.assertNotIn('Restart=', unit)
        self.assertIn('WantedBy=graphical.target', unit)
        # The window ships beside the service and cage comes with the RPM.
        self.assertTrue(os.access(LIBEXEC / 'cybexos-new-owner-gui', os.X_OK))
        self.assertTrue((ROOT / 'image/rootfs/usr/share/cybexos/new-owner/Main.qml').is_file())
        spec = (ROOT / 'image/cybexos-desktop.spec').read_text()
        requires = ' '.join(line.split(':', 1)[1] for line in spec.splitlines() if line.startswith('Requires:')).split()
        for package in ('cage', 'python3-pyside6', 'qt6-qtwayland', 'xkeyboard-config', 'dracut'):
            self.assertIn(package, requires)
        for path in ('/usr/libexec/cybexos-*', '/usr/share/cybexos/'):
            self.assertIn(path, spec.splitlines())


if __name__ == '__main__':
    unittest.main()
