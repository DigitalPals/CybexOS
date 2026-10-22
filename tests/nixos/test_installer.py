"""Installer safety and hardware detection regression fixtures, not ISO tests."""
import base64
import contextlib
import copy
import hashlib
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
import urllib.request
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lifecycle'))
loader = importlib.machinery.SourceFileLoader('nerdos_installer', str(ROOT / 'installer/nerdos-install'))
spec = importlib.util.spec_from_loader(loader.name, loader)
installer = importlib.util.module_from_spec(spec)
loader.exec_module(installer)


# The vendor checkout's own lock is the tested-Nixpkgs fixture.
VENDOR_LOCK = json.loads((ROOT / 'flake.lock').read_text())
TESTED_NIXPKGS = VENDOR_LOCK['nodes'][VENDOR_LOCK['nodes'][VENDOR_LOCK['root']]['inputs']['nixpkgs']]
STORE_SOURCE = '/nix/store/' + 'c' * 32 + '-source'


def nix_lock(config, nixpkgs=None):
    """Fixture for nix flake lock: reuse the seeded root entry (or simulate a
    refresh to `nixpkgs`) and add the vendor input that follows it."""
    lock = json.loads((config / 'flake.lock').read_text())
    if nixpkgs is not None:
        lock['nodes']['nixpkgs'] = nixpkgs
    lock['nodes']['root']['inputs']['nerdos'] = 'nerdos'
    lock['nodes']['nerdos'] = {'inputs': {'nixpkgs': ['nixpkgs']},
                                'locked': {'type': 'path', 'path': str(ROOT), 'narHash': 'sha256-' + 'C' * 43 + '='},
                                'original': {'type': 'path', 'path': str(ROOT)}}
    (config / 'flake.lock').write_text(json.dumps(lock))


def plan():
    return {'disk': '/dev/vda', 'serial': 'QA-DISK', 'hostname': 'nerdos-test', 'username': 'tester',
            'timezone': 'UTC', 'locale': 'en_US.UTF-8', 'keyboard': 'us',
            'encrypted': True, 'autoLogin': True, 'secureBoot': False, 'nvidiaOpen': True}


class PlanTests(unittest.TestCase):
    def setUp(self):
        timezone = patch.object(installer, 'known_timezone', return_value=True)
        timezone.start(); self.addCleanup(timezone.stop)

    def test_typed_choices_and_encryption_gate(self):
        self.assertEqual(installer.validate(plan()), plan())
        invalid = [('autoLogin', 'true'), ('encrypted', False), ('hostname', '../etc'),
                   ('username', 'root'), ('disk', '/dev/vda1'), ('timezone', '../../etc'), ('timezone', '/etc/passwd'), ('locale', 'en/US'),
                   ('features', {'unknown': True}), ('features', {'steam': 1}),
                   ('desktopKeyboard', 'us;echo unsafe'), ('serial', 'a\nb'), ('locale', None)]
        for key, value in invalid:
            choice = plan(); choice[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(installer.Failure):
                installer.validate(choice)
        with self.assertRaises(installer.Failure):
            installer.validate([])

    def test_independent_console_and_desktop_layout(self):
        choice = plan(); choice.update(keyboard='uk', desktopKeyboard='gb')
        self.assertEqual(installer.validate(choice)['desktopKeyboard'], 'gb')


class HardwareTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='nerdos-installer-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.sys = Path(self.directory.name)
        self.cpu = self.sys / 'cpuinfo'; self.cpu.write_text('Intel Core Ultra')

    def pci(self, address, vendor, display_class='0x030000', device='0x1234'):
        path = self.sys / 'bus/pci/devices' / address; path.mkdir(parents=True)
        for key, value in {'vendor':vendor, 'class':display_class, 'device':device}.items():
            (path / key).write_text(value)

    def test_hybrid_prime_uses_display_class_and_decimal_pci_ids(self):
        self.pci('0000:00:02.0', '0x8086')
        self.pci('0000:0a:1f.2', '0x10de')
        self.pci('0000:0a:1f.3', '0x10de', display_class='0x040300')
        found = installer.detect(self.sys, self.cpu)
        self.assertTrue(found['nvidia'])
        self.assertEqual(found['nvidiaPrime'], {'enable':True, 'intelBusId':'PCI:0:2:0',
                                             'amdgpuBusId':'', 'nvidiaBusId':'PCI:10:31:2'})

    def test_multiple_or_nonzero_domain_gpus_require_explicit_choice(self):
        self.pci('0000:00:02.0', '0x1002')
        self.pci('0001:01:00.0', '0x10de')
        self.assertFalse(installer.detect(self.sys, self.cpu)['nvidiaPrime']['enable'])
        self.pci('0000:01:00.0', '0x10de')
        self.pci('0000:02:00.0', '0x10de')
        self.assertFalse(installer.detect(self.sys, self.cpu)['nvidiaPrime']['enable'])

    def test_camera_requires_exact_dmi_sku_acpi_and_pci(self):
        dmi = self.sys / 'class/dmi/id'; dmi.mkdir(parents=True)
        for key, value in {'sys_vendor':'Dell Inc.', 'product_name':'Dell XPS 14 DA14260', 'product_sku':'0DB9'}.items():
            (dmi / key).write_text(value)
        (self.sys / 'bus/acpi/devices/OVTI08F4:00').mkdir(parents=True)
        self.pci('0000:00:05.0', '0x8086', '0x048000', '0xb05d')
        self.assertTrue(installer.detect(self.sys, self.cpu)['camera'])
        (dmi / 'product_sku').write_text('unreviewed')
        self.assertFalse(installer.detect(self.sys, self.cpu)['camera'])


class DiskSafetyTests(unittest.TestCase):
    def trusted_install_directory(self):
        # Exercise the installer with ordinary fixture storage while requiring
        # the real invocation to select /run, never world-writable /tmp.
        create = tempfile.TemporaryDirectory
        def temporary(*args, **kwargs):
            self.assertEqual(kwargs.pop('dir', None), '/run')
            return create(*args, **kwargs)
        return patch.object(installer.tempfile, 'TemporaryDirectory', side_effect=temporary)

    def setUp(self):
        timezone = patch.object(installer, 'known_timezone', return_value=True)
        timezone.start(); self.addCleanup(timezone.stop)

    def disk(self):
        return {'path':'/dev/vda','type':'disk','ro':False,'serial':'QA-DISK',
                'size':40 * 1024**3,'mountpoints':[None], 'children':[]}

    def test_mounted_readonly_wrong_identity_and_small_disks_rejected(self):
        invalid = [{'serial':'OTHER'}, {'ro':True}, {'size':1024},
                   {'children':[{'mountpoints':['/home'], 'children':[]}]}]
        for change in invalid:
            disk = self.disk(); disk.update(change)
            with self.subTest(change=change), patch.object(installer, 'disks', return_value=[disk]), self.assertRaises(installer.Failure):
                installer.disk_guard(plan())

    def test_active_swap_is_rejected(self):
        swap = Mock(); swap.read_text.return_value = 'Filename Type Size Used Priority\n/dev/vda2 partition 100 0 -2\n'
        real_path = Path
        def path(value, *args):
            return swap if value == '/proc/swaps' else real_path(value, *args)
        with patch.object(installer, 'disks', return_value=[self.disk()]), patch.object(installer, 'Path', side_effect=path), patch.object(installer.subprocess, 'check_output', return_value='/dev/vda\n/dev/vda2\n'), self.assertRaises(installer.Failure):
            installer.disk_guard(plan())

    def test_secure_boot_rejected_before_any_disk_command(self):
        efi = Mock(); efi.exists.return_value = True
        variables = Mock(); flag = Mock(); flag.read_bytes.return_value = b'\x07\x00\x00\x00\x01'
        variables.glob.return_value = [flag]
        real_path = Path
        def path(value, *args):
            return {'/sys/firmware/efi':efi, '/sys/firmware/efi/efivars':variables}.get(value, real_path(value, *args))
        run = Mock()
        with patch.object(installer, 'disk_guard'), patch.object(installer, 'Path', side_effect=path), self.assertRaisesRegex(installer.Failure, 'will not be disabled'):
            installer.install(plan(), {'password':'not-used'}, 'path:/source', 'revision', 'nar', run, channel='beta')
        run.assert_not_called()

    def test_authenticated_source_precedes_disk_work_and_vendor_evaluation(self):
        efi = Mock(); efi.exists.return_value = True
        variables = Mock(); variables.glob.return_value = []
        real_path = Path
        def path(value, *args):
            return {'/sys/firmware/efi':efi, '/sys/firmware/efi/efivars':variables, STORE_SOURCE:ROOT}.get(value, real_path(value, *args))
        revision = 'a' * 40
        nar = 'sha256-' + 'A' * 43 + '='
        source = 'github:DigitalPals/NerdOS/' + revision
        choice = plan(); choice.update(encrypted=False, autoLogin=False)
        for fetched in ({'hash': nar, 'storePath': STORE_SOURCE}, {'hash': nar}, {'hash': nar, 'storePath': '../source'},
                        {'hash': 'sha256-' + 'B' * 43 + '='}, {}):
            calls = []
            def run(*args, **kwargs):
                calls.append(args)
                if args[:3] == ('nix', 'flake', 'prefetch'):
                    return json.dumps(fetched)
                raise installer.Failure('stop before any destructive fixture command')
            with self.subTest(fetched=fetched), self.trusted_install_directory(), patch.object(installer, 'disk_guard', side_effect=lambda _: calls.append(('disk-guard',))), patch.object(installer, 'detect', return_value={'camera':False}), patch.object(installer, 'Path', side_effect=path), self.assertRaises(installer.Failure):
                installer.install(choice, {'password':'qualification-password-123'}, source, revision, nar, run, channel='beta')
            self.assertEqual(calls[0][:4], ('nix', 'flake', 'prefetch', '--json'))
            self.assertIn(revision + '?narHash=sha256-', calls[0][-1])
            if fetched.get('storePath') == STORE_SOURCE:
                self.assertEqual(calls[1], ('disk-guard',))
                self.assertEqual(calls[2], ('sgdisk', '--zap-all', '/dev/vda'))
            else:
                self.assertEqual(len(calls), 1, 'unauthenticated source reached disk work or vendor evaluation')

    def test_new_filesystem_mount_does_not_use_stale_udev_type(self):
        efi = Mock(); efi.exists.return_value = True
        variables = Mock(); variables.glob.return_value = []
        real_path = Path
        def path(value, *args):
            return {'/sys/firmware/efi':efi, '/sys/firmware/efi/efivars':variables}.get(value, real_path(value, *args))
        calls = []
        def run(*args, **kwargs):
            calls.append(args)
            if args[0] == 'mount':
                raise installer.Failure('stop before mounting fixture')
            return ''
        choice = plan(); choice.update(encrypted=False, autoLogin=False)
        hardware = {'camera':False}
        with self.trusted_install_directory(), patch.object(installer, 'disk_guard'), patch.object(installer, 'detect', return_value=hardware), patch.object(installer, 'Path', side_effect=path), self.assertRaisesRegex(installer.Failure, 'stop before mounting'):
            installer.install(choice, {'password':'qualification-password-123'}, f'path:{ROOT}', 'revision', 'nar', run, channel='beta')
        mount = next(args for args in calls if args[0] == 'mount')
        self.assertEqual(mount[:4], ('mount', '-t', 'ext4', '/dev/vda2'))


    def test_install_public_ancestry_is_traversable_with_private_secrets(self):
        efi = Mock(); efi.exists.return_value = True
        variables = Mock(); variables.glob.return_value = []
        real_path = Path
        def path(value, *args):
            return {'/sys/firmware/efi':efi, '/sys/firmware/efi/efivars':variables}.get(value, real_path(value, *args))
        def run(*args, **kwargs):
            if args[0] == 'nixos-generate-config':
                config = real_path(args[-1])
                (config / 'hardware-configuration.nix').write_text('{}')
                (config / 'configuration.nix').write_text('{}')
            elif args[:3] == ('nix', 'flake', 'lock'):
                nix_lock(real_path(str(args[-1]).removeprefix('path:')))
            elif args[0] == 'nixos-install':
                self.assertIn('--no-channel-copy', args)
                target = real_path(args[2])
                for directory in (target.parent, target, target / 'var', target / 'var/lib',
                                  target / 'var/lib/nerdos', target / 'var/lib/nerdos/working', target / 'etc'):
                    self.assertEqual(directory.stat().st_mode & 0o777, 0o755, str(directory))
                self.assertEqual((target / 'var/lib/nerdos/secrets').stat().st_mode & 0o777, 0o700)
                self.assertEqual((target / 'var/lib/nerdos/working/initial/flake.nix').stat().st_mode & 0o777, 0o644)
                raise installer.Failure('stop before fixture system build')
            return 'unused-credential-hash'
        choice = plan(); choice.update(encrypted=False, autoLogin=False)
        hardware = {'camera':False, 'nvidia':False, 'nvidiaPrime':{'enable':False}, 'xps':False}
        previous_umask = os.umask(0o077)
        try:
            with self.trusted_install_directory(), patch.dict(os.environ, {'NERDOS_UPDATER_SHARE':str(ROOT / 'templates')}), patch.object(installer, 'disk_guard'), patch.object(installer, 'detect', return_value=hardware), patch.object(installer, 'Path', side_effect=path), patch('nerdos.inputs.validate_machine'), patch('nerdos.inputs.identity', return_value={}), self.assertRaisesRegex(installer.Failure, 'stop before fixture system build'):
                installer.install(choice, {'password':'qualification-password-123'}, f'path:{ROOT}', 'revision', 'nar', run, channel='beta')
        finally:
            os.umask(previous_umask)

    def test_machine_owns_medium_channel_choice(self):
        efi = Mock(); efi.exists.return_value = True
        variables = Mock(); variables.glob.return_value = []
        real_path = Path
        def path(value, *args):
            return {'/sys/firmware/efi':efi, '/sys/firmware/efi/efivars':variables}.get(value, real_path(value, *args))
        choice = plan(); choice.update(encrypted=False, autoLogin=False)
        hardware = {'camera':False, 'nvidia':False, 'nvidiaPrime':{'enable':False}, 'xps':False}
        for channel in ('beta', 'stable'):
            machine = []
            def run(*args, **kwargs):
                if args[0] == 'nixos-generate-config':
                    (real_path(args[-1]) / 'hardware-configuration.nix').write_text('{}')
                elif args[:3] == ('nix', 'flake', 'lock'):
                    nix_lock(real_path(str(args[-1]).removeprefix('path:')))
                elif args[0] == 'nixos-install':
                    machine.append((real_path(args[2]) / 'var/lib/nerdos/working/initial/machine.nix').read_text())
                    raise installer.Failure('stop before fixture system build')
                return 'unused-credential-hash'
            with self.subTest(channel=channel), self.trusted_install_directory(), patch.dict(os.environ, {'NERDOS_UPDATER_SHARE':str(ROOT / 'templates')}), patch.object(installer, 'disk_guard'), patch.object(installer, 'detect', return_value=hardware), patch.object(installer, 'Path', side_effect=path), patch('nerdos.inputs.validate_machine'), patch('nerdos.inputs.identity', return_value={}), self.assertRaisesRegex(installer.Failure, 'stop before fixture system build'):
                installer.install(choice, {'password':'qualification-password-123'}, f'path:{ROOT}', 'revision', 'nar', run, channel=channel)
            # A later vendor release changes only the version-derived default;
            # the machine keeps the explicit channel it was installed with.
            self.assertEqual(machine[0].count('updates.channel'), 1)
            self.assertIn(f'    updates.channel = "{channel}";\n', machine[0])
        for channel in (None, '', 'nightly', ['beta']):
            run = Mock()
            with self.subTest(channel=channel), patch.object(installer, 'disk_guard') as guard, self.assertRaisesRegex(installer.Failure, 'supported release channel'):
                installer.install(choice, {'password':'qualification-password-123'}, f'path:{ROOT}', 'revision', 'nar', run, channel=channel)
            run.assert_not_called(); guard.assert_not_called()


class TestedNixpkgsTests(unittest.TestCase):
    def setUp(self):
        timezone = patch.object(installer, 'known_timezone', return_value=True)
        timezone.start(); self.addCleanup(timezone.stop)
        directory = tempfile.TemporaryDirectory(prefix='nerdos-installer-nixpkgs-')
        self.addCleanup(directory.cleanup)
        self.base = Path(directory.name)

    def source(self, lock=None, raw=None):
        source = self.base / 'source'
        source.mkdir(exist_ok=True)
        (source / 'flake.lock').write_text(raw if raw is not None else json.dumps(lock))
        return source

    def test_vendor_lock_supplies_exact_tested_nixpkgs_and_branch(self):
        node = installer.vendor_nixpkgs(ROOT)
        self.assertEqual(node, {'original': TESTED_NIXPKGS['original'], 'locked': TESTED_NIXPKGS['locked']})
        self.assertEqual(node['original'], {'type': 'github', 'owner': 'NixOS', 'repo': 'nixpkgs', 'ref': 'nixos-26.05'})
        self.assertRegex(node['locked']['rev'], '^[0-9a-f]{40}$')

    def test_malformed_or_moving_vendor_nixpkgs_is_rejected(self):
        def changed(update):
            lock = copy.deepcopy(VENDOR_LOCK)
            update(lock, lock['nodes'][lock['nodes'][lock['root']]['inputs']['nixpkgs']])
            return lock
        cases = {
            'missing': None, 'not json': '{', 'duplicate field': '{"version":7,"version":7}', 'list': '[]',
            'version': changed(lambda lock, node: lock.update(version=6)),
            'follows': changed(lambda lock, node: lock['nodes'][lock['root']]['inputs'].update(nixpkgs=['other'])),
            'no root input': changed(lambda lock, node: lock['nodes'][lock['root']]['inputs'].pop('nixpkgs')),
            'unstable branch': changed(lambda lock, node: node['original'].update(ref='nixos-unstable')),
            'no branch': changed(lambda lock, node: node['original'].pop('ref')),
            'pinned selector': changed(lambda lock, node: node['original'].update(rev='a' * 40)),
            'fork': changed(lambda lock, node: node['locked'].update(owner='someone')),
            'moving rev': changed(lambda lock, node: node['locked'].update(rev='nixos-26.05')),
            'no content identity': changed(lambda lock, node: node['locked'].pop('narHash')),
            'bad content identity': changed(lambda lock, node: node['locked'].update(narHash='sha256:abc')),
            'path source': changed(lambda lock, node: node['locked'].update(type='path')),
            'extra locked field': changed(lambda lock, node: node['locked'].update(url='https://example.invalid')),
            'extra node field': changed(lambda lock, node: node.update(inputs={})),
            'lastModified type': changed(lambda lock, node: node['locked'].update(lastModified='1')),
        }
        for name, lock in cases.items():
            with self.subTest(name):
                if lock is None:
                    source = self.base / 'empty'; source.mkdir(exist_ok=True)
                else:
                    source = self.source(raw=lock if isinstance(lock, str) else json.dumps(lock))
                with self.assertRaisesRegex(installer.Failure, 'exact tested stable Nixpkgs lock'):
                    installer.vendor_nixpkgs(source)

    def efi(self):
        efi = Mock(); efi.exists.return_value = True
        variables = Mock(); variables.glob.return_value = []
        real_path = Path
        def path(value, *args):
            return {'/sys/firmware/efi':efi, '/sys/firmware/efi/efivars':variables}.get(value, real_path(value, *args))
        return patch.object(installer, 'Path', side_effect=path)

    def test_unusable_vendor_nixpkgs_stops_before_disk_work(self):
        lock = copy.deepcopy(VENDOR_LOCK)
        lock['nodes']['nixpkgs']['original']['ref'] = 'nixos-unstable'
        source = self.source(lock)
        choice = plan(); choice.update(encrypted=False, autoLogin=False)
        run = Mock()
        with self.efi(), patch.object(installer, 'disk_guard') as guard, patch.object(installer, 'detect', return_value={'camera': False}), \
                self.assertRaisesRegex(installer.Failure, 'No disk has been erased'):
            installer.install(choice, {'password': 'qualification-password-123'}, f'path:{source}', 'revision', 'nar', run, channel='beta')
        run.assert_not_called(); guard.assert_not_called()

    def test_machine_lock_is_seeded_with_tested_nixpkgs_and_checked_after_locking(self):
        choice = plan(); choice.update(encrypted=False, autoLogin=False)
        hardware = {'camera': False, 'nvidia': False, 'nvidiaPrime': {'enable': False}, 'xps': False}
        refreshed = copy.deepcopy(TESTED_NIXPKGS)
        refreshed['locked'].update(rev='f' * 40, narHash='sha256-' + 'F' * 43 + '=')
        create = tempfile.TemporaryDirectory
        for name, result in {'reused': None, 'refreshed': refreshed}.items():
            seen = {}
            def run(*args, **kwargs):
                if args[0] == 'nixos-generate-config':
                    (Path(args[-1]) / 'hardware-configuration.nix').write_text('{}')
                elif args[:3] == ('nix', 'flake', 'lock'):
                    config = Path(str(args[-1]).removeprefix('path:'))
                    seen['seed'] = json.loads((config / 'flake.lock').read_text())
                    seen['flake'] = (config / 'flake.nix').read_text()
                    nix_lock(config, result)
                elif args[0] == 'nixos-install':
                    seen['installed'] = True
                    raise installer.Failure('stop before fixture system build')
                return 'unused-credential-hash'
            with self.subTest(name), patch.object(installer.tempfile, 'TemporaryDirectory', side_effect=lambda *a, **k: create(*a, **{x: y for x, y in k.items() if x != 'dir'})), \
                    patch.dict(os.environ, {'NERDOS_UPDATER_SHARE': str(ROOT / 'templates')}), self.efi(), patch.object(installer, 'disk_guard'), \
                    patch.object(installer, 'detect', return_value=hardware), self.assertRaises(installer.Failure) as raised:
                installer.install(choice, {'password': 'qualification-password-123'}, f'path:{ROOT}', 'revision', 'nar', run, channel='beta')
            # Only the root Nixpkgs node is seeded; its branch selector stays.
            self.assertEqual(seen['seed'], {'version': 7, 'root': 'root', 'nodes': {
                'root': {'inputs': {'nixpkgs': 'nixpkgs'}},
                'nixpkgs': {'original': TESTED_NIXPKGS['original'], 'locked': TESTED_NIXPKGS['locked']}}})
            self.assertIn('nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";', seen['flake'])
            if result is None:
                self.assertIn('stop before fixture system build', str(raised.exception))
            else:
                self.assertIn('differs from the tested release Nixpkgs', str(raised.exception))
                self.assertNotIn('installed', seen)


REVISION, OTHER_REVISION = '1' * 40, '3' * 40
NAR, OTHER_NAR = 'sha256-' + 'A' * 43 + '=', 'sha256-' + 'B' * 43 + '='
RELEASES = 'https://github.com/DigitalPals/NerdOS/releases/download/'


def manifest(version='1.0.0-beta.1', **changes):
    release = {'schema':1, 'version':version, 'revision':REVISION, 'narHash':NAR,
               'architectures':['x86_64-linux'], 'nixos':['26.05'], 'configurationApi':1, 'pluginApi':1,
               'minUpdater':1, 'notes':'Qualified medium', 'vendorInputs':['lanzaboote'],
               'assets':[{'name':f'nerdos-{version}-x86_64-linux.iso', 'url':f'{RELEASES}v{version}/nerdos-{version}-x86_64-linux.iso',
                          'sha256':'f' * 64, 'bytes':1}]}
    release.update(changes)
    return release


class MediaAuthenticationTests(unittest.TestCase):
    """Production media selection with real Ed25519 signatures and the real
    Fetcher. Only the network transport is replaced by a loopback server."""

    def setUp(self):
        timezone = patch.object(installer, 'known_timezone', return_value=True)
        timezone.start(); self.addCleanup(timezone.stop)
        directory = tempfile.TemporaryDirectory(prefix='nerdos-installer-media-')
        self.addCleanup(directory.cleanup)
        self.base = Path(directory.name)
        self.keys = {}
        for name in ('publisher', 'untrusted'):
            key = self.base / name
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'Ed25519', '-out', str(key)], check=True, capture_output=True)
            self.keys[name] = key
        public = subprocess.check_output(['openssl', 'pkey', '-in', str(self.keys['publisher']), '-pubout'], text=True)
        self.trust = {'schema':1, 'keys':{'publisher':{'publicKey':public, 'notAfter':'2099-01-01T00:00:00Z',
                                                         'purposes':['release', 'channel']}}}
        self.etc = self.base / 'etc'; self.etc.mkdir()
        (self.etc / 'installer').write_text('fresh-install-only\n')
        self.medium(version='1.0.0-beta.1', channel='beta')
        self.served, self.requests = {}, []
        self.publish(manifest())
        # A channel that has since advanced must never select what this
        # medium installs; serve it so any request for it is observable.
        newer = manifest('1.0.0-beta.2', revision=OTHER_REVISION, narHash=OTHER_NAR)
        self.publish(newer)
        moved = json.dumps({'schema':1, 'channel':'beta', 'sequence':9, 'expires':'2099-01-01T00:00:00Z',
                            'manifest':RELEASES + 'v1.0.0-beta.2/manifest.json',
                            'sha256':hashlib.sha256(json.dumps(newer).encode()).hexdigest()}).encode()
        channel = 'https://digitalpals.github.io/NerdOS/channels/beta.json'
        self.served[channel], self.served[channel + '.sig'] = moved, self.sign(moved)
        self.transport()

    def medium(self, channel='beta', **changes):
        release = {'version':'1.0.0-beta.1', 'revision':REVISION, 'narHash':NAR, 'configurationApi':1, 'pluginApi':1,
                   'updaterApi':1, 'nixos':'26.05', 'architecture':'x86_64-linux'}
        release.update(changes)
        (self.etc / 'release.json').write_text(json.dumps(release))
        (self.etc / 'update.json').write_text(json.dumps({'schema':1, 'channel':channel, 'branch':'nixos-26.05'}))
        (self.etc / 'trust.json').write_text(json.dumps(self.trust))

    def sign(self, body, key='publisher', key_id='publisher'):
        document = self.base / 'signed-body'; document.write_bytes(body)
        raw = subprocess.check_output(['openssl', 'pkeyutl', '-sign', '-rawin', '-inkey', str(self.keys[key]), '-in', str(document)])
        return json.dumps({'keyId':key_id, 'signature':base64.b64encode(raw).decode()}).encode()

    def publish(self, release, at=None, body=None, signature=None):
        url = RELEASES + f'v{at or release["version"]}/manifest.json'
        body = json.dumps(release).encode() if body is None else body
        self.served[url] = body
        self.served[url + '.sig'] = self.sign(body) if signature is None else signature

    def transport(self):
        served = self.served
        class Release(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = served.get(urllib.parse.unquote(self.path[1:]))
                self.send_response(200 if body is not None else 404)
                self.send_header('Content-Length', str(len(body or b'')))
                self.end_headers()
                self.wfile.write(body or b'')
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Release)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def stop():
            server.shutdown(); server.server_close(); thread.join(timeout=5)
        self.addCleanup(stop)
        real_urlopen = urllib.request.urlopen
        def urlopen(request, timeout=30):
            self.requests.append(request.full_url)
            local = urllib.request.Request(f'http://127.0.0.1:{server.server_port}/' + urllib.parse.quote(request.full_url, safe=''),
                                           headers=dict(request.header_items()))
            response = real_urlopen(local, timeout=timeout)
            # Adapt only the test transport. Production endpoint checks,
            # bounded reads and cache publication remain in the path.
            response.url = request.full_url
            return response
        transport = patch('nerdos.trust.urllib.request.urlopen', side_effect=urlopen)
        transport.start(); self.addCleanup(transport.stop)

    def main(self, *arguments, runner=None):
        plan_file = self.base / 'plan.json'
        plan_file.write_text(json.dumps(plan()))
        read_end, write_end = os.pipe()
        os.write(write_end, json.dumps({'password':'qualification-password-123', 'passphrase':'qualification-passphrase-123'}).encode())
        os.close(write_end)
        output = io.StringIO()
        argv = ['nerdos-install', '--plan-file', str(plan_file), '--secrets-fd', str(read_end), *arguments]
        try:
            with patch.object(installer, 'ETC', self.etc), patch.object(installer, 'CACHE', self.base / 'cache'), \
                    patch.object(installer.os, 'geteuid', return_value=0), patch.object(installer, 'Runner', return_value=runner or Mock()), \
                    patch.object(installer, 'install') as install, patch.object(sys, 'argv', argv), contextlib.redirect_stdout(output):
                installer.main()
        finally:
            with contextlib.suppress(OSError):
                os.close(read_end)
        return install, output.getvalue()

    def assert_rejected(self, pattern, network=True):
        runner = Mock()
        with self.assertRaisesRegex(installer.Failure, pattern) as raised:
            self.main(runner=runner)
        self.assertIn('erased', str(raised.exception))
        runner.assert_not_called()
        if network:
            self.assertEqual(self.requests[:1], [RELEASES + 'v1.0.0-beta.1/manifest.json'])
        else:
            self.assertEqual(self.requests, [], 'blocked medium contacted a release endpoint')
        return raised.exception

    def test_production_medium_installs_its_exact_authenticated_release(self):
        install, output = self.main()
        install.assert_called_once()
        args, kwargs = install.call_args
        self.assertEqual(args[2:5], ('github:DigitalPals/NerdOS/' + REVISION, REVISION, NAR))
        self.assertEqual(kwargs['channel'], 'beta')
        self.assertEqual(args[0], plan())
        self.assertIn('Authenticated NerdOS 1.0.0-beta.1 • beta channel • exact revision ' + REVISION, output)
        # Only this medium's immutable manifest is consulted; the moved
        # channel and its newer release are never fetched or selected.
        self.assertEqual(self.requests, [RELEASES + 'v1.0.0-beta.1/manifest.json', RELEASES + 'v1.0.0-beta.1/manifest.json.sig'])

    def test_differing_identity_is_rejected_before_installation(self):
        for change in ({'revision':OTHER_REVISION}, {'narHash':OTHER_NAR}):
            with self.subTest(change=change):
                self.requests.clear()
                self.publish(manifest(**change))
                self.assert_rejected('differs from this installation medium')
        # A validly signed newer release served at this medium's tag is still
        # a different identity, never a substitute.
        self.requests.clear()
        self.publish(manifest('1.0.0-beta.2'), at='1.0.0-beta.1')
        self.assert_rejected('differs from this installation medium')

    def test_invalid_signatures_and_unsupported_metadata_are_rejected(self):
        body = json.dumps(manifest()).encode()
        cases = [(dict(body=body + b' ', signature=self.sign(body)), 'Invalid publisher signature'),
                 (dict(signature=self.sign(body, key='untrusted')), 'Invalid publisher signature'),
                 (dict(signature=self.sign(body, key='untrusted', key_id='untrusted')), 'not trusted'),
                 (dict(signature=b'{"keyId":"publisher"}'), 'signature envelope'),
                 (dict(body=json.dumps(manifest(schema=2)).encode()), 'newer updater'),
                 (dict(body=json.dumps(manifest(minUpdater=2)).encode()), 'newer updater'),
                 (dict(body=json.dumps(manifest(channel='beta')).encode()), 'Unsupported or incomplete'),
                 (dict(body=json.dumps(manifest(architectures=['aarch64-linux'])).encode()), 'architecture'),
                 (dict(body=b'{"schema":1,"schema":1}'), 'Duplicate metadata')]
        for options, pattern in cases:
            with self.subTest(pattern=pattern, options=sorted(options)):
                self.requests.clear()
                self.publish(manifest(), **options)
                self.assert_rejected(pattern)
        self.requests.clear()
        del self.served[RELEASES + 'v1.0.0-beta.1/manifest.json']
        self.assert_rejected('HTTP 404')

    def test_unauthenticatable_media_are_blocked_without_network(self):
        keys, self.trust['keys'] = self.trust['keys'], {}
        self.medium()
        self.assert_rejected('no owner-controlled publisher trust keys', network=False)
        self.trust['keys'] = keys
        for changes, pattern in (({'revision':'uncommitted'}, 'exact committed release'),
                                 ({'narHash':'unavailable'}, 'exact committed release'),
                                 ({'architecture':None}, 'exact committed release'),
                                 ({'version':'1.0'}, 'semantic release version')):
            with self.subTest(changes=changes):
                self.requests.clear()
                self.medium(**changes)
                self.assert_rejected(pattern, network=False)
        self.requests.clear()
        self.medium(channel='nightly')
        self.assert_rejected('supported release channel', network=False)

    def test_channel_policy_applies_to_the_medium_release(self):
        # The stable channel never authenticates a prerelease medium.
        self.medium(channel='stable')
        self.assert_rejected('Stable channel contains a prerelease')
        for medium_channel in ('stable', 'beta'):
            with self.subTest(channel=medium_channel):
                self.requests.clear()
                self.medium(version='1.0.0', channel=medium_channel)
                self.publish(manifest('1.0.0'))
                release, channel = installer.authenticate_media(installer.Fetcher(self.base / 'cache'), self.etc)
                self.assertEqual((release['version'], release['revision'], channel), ('1.0.0', REVISION, medium_channel))
                self.assertEqual(self.requests, [RELEASES + 'v1.0.0/manifest.json', RELEASES + 'v1.0.0/manifest.json.sig'])

    def test_development_source_keeps_medium_channel_without_release_lookup(self):
        runner = Mock(return_value=json.dumps({'path':'/nix/store/' + 'a' * 32 + '-source', 'locked':{'narHash':NAR}}))
        install, output = self.main('--development-source', str(self.base), runner=runner)
        args, kwargs = install.call_args
        self.assertEqual(args[2], 'path:/nix/store/' + 'a' * 32 + '-source')
        self.assertEqual(kwargs['channel'], 'beta')
        self.assertIn('UNRELEASED TEST INSTALLATION', output)
        self.assertEqual(self.requests, [])


if __name__ == '__main__':
    unittest.main()
