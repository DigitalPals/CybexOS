"""Inert admission, transfer and transaction tests; never boot or install a guest."""
from copy import deepcopy
from contextlib import ExitStack, nullcontext
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from build_support import digest
import offline_upgrade_inputs as inputs
import qualification
import upgrade_qualification as upgrade


SIGNATURE = {'tag': 'RSAHEADER', 'value': 'RSA/SHA256, Wed Oct 21 2026, Key ID 0123456789abcdef'}


class DependencyInputs(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / 'dependencies'
        self.directory.mkdir()
        self.artifacts = {}
        for arg, filename in (('baseline_iso', 'baseline.iso'), ('candidate_rpm', 'desktop.rpm'),
                              ('candidate_offline_rpm', 'offline.rpm')):
            path = self.root / filename
            path.write_bytes(filename.encode())
            self.artifacts[arg] = path
        self.rpm = self.directory / 'patch-2.8-1.fc44.x86_64.rpm'
        self.rpm.write_bytes(b'inert RPM fixture')
        self.record = {'filename': self.rpm.name, 'name': 'patch', 'nevra': 'patch-0:2.8-1.fc44.x86_64',
                       'architecture': 'x86_64', 'sha256': digest(self.rpm), 'size': self.rpm.stat().st_size,
                       'signature': SIGNATURE, 'repository': {'id': 'fedora', 'url': 'https://example.org/fedora/44/'}}
        self.manifest = {'schema': 1, **{arg + '_sha256': digest(path) for arg, path in self.artifacts.items()},
                         'rpms': [self.record]}
        self.write_manifest()

    def write_manifest(self, manifest=None):
        (self.directory / inputs.MANIFEST).write_text(json.dumps(self.manifest if manifest is None else manifest))

    def bundle(self):
        return inputs.load_bundle(self.directory, **self.artifacts)

    def test_identity_binds_all_inputs_and_exact_manifest_bytes(self):
        bundle = self.bundle()
        self.assertEqual(bundle.manifest_sha256, digest(self.directory / inputs.MANIFEST))
        self.assertEqual(bundle.evidence()['rpms'], [self.record])
        self.assertEqual(bundle.evidence()['total_bytes'], len(self.rpm.read_bytes()))
        for argument in self.artifacts:
            with self.subTest(argument=argument):
                wrong = {**self.artifacts, argument: self.rpm}
                with self.assertRaisesRegex(ValueError, 'binding mismatch'):
                    inputs.load_bundle(self.directory, **wrong)
        with self.assertRaisesRegex(ValueError, 'both first-party'):
            inputs.load_bundle(self.directory, baseline_iso=self.artifacts['baseline_iso'])

    def test_extra_missing_traversal_and_symlinks_are_rejected(self):
        extra = self.directory / 'unlisted.rpm'
        extra.write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, 'extra or missing'):
            self.bundle()
        extra.unlink()
        saved = self.rpm.read_bytes()
        self.rpm.unlink()
        with self.assertRaisesRegex(ValueError, 'extra or missing'):
            self.bundle()
        outside = self.root / 'outside.rpm'
        outside.write_bytes(saved)
        self.rpm.symlink_to(outside)
        with self.assertRaises(OSError):
            self.bundle()
        self.rpm.unlink()
        self.rpm.write_bytes(saved)
        for filename in ('../outside.rpm', '/outside.rpm', 'nested/file.rpm', '-option.rpm', 'line\nbreak.rpm'):
            manifest = deepcopy(self.manifest)
            manifest['rpms'][0]['filename'] = filename
            self.write_manifest(manifest)
            with self.subTest(filename=filename), self.assertRaisesRegex(ValueError, 'filename'):
                self.bundle()
        self.write_manifest()
        link = self.root / 'linked-directory'
        link.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlinks'):
            inputs.load_bundle(link, **self.artifacts)
        manifest_path = self.directory / inputs.MANIFEST
        outside.write_bytes(manifest_path.read_bytes())
        manifest_path.unlink()
        manifest_path.symlink_to(outside)
        with self.assertRaises(OSError):
            self.bundle()

    def test_malformed_and_duplicate_records_never_reach_transfer(self):
        mutations = [
            lambda m: m.update(schema=True),
            lambda m: m.update(unchecked='extra'),
            lambda m: m.update(candidate_rpm_sha256='bad'),
            lambda m: m.update(rpms=[]),
            lambda m: m['rpms'].append(deepcopy(m['rpms'][0])),
            lambda m: m['rpms'][0].update(sha256='A' * 64),
            lambda m: m['rpms'][0].update(size=True),
            lambda m: m['rpms'][0].update(size=inputs.MAX_RPM_BYTES + 1),
            lambda m: m['rpms'][0].update(architecture='aarch64'),
            lambda m: m['rpms'][0].update(nevra='patch-2.8-1.fc44.x86_64'),
            lambda m: m['rpms'][0].update(name='cybexos-desktop'),
            lambda m: m['rpms'][0].update(name='gpg-pubkey'),
            lambda m: m['rpms'][0].update(signature={'tag': 'RSAHEADER', 'value': '(none)'}),
            lambda m: m['rpms'][0].update(signature={'tag': 'OTHER', 'value': SIGNATURE['value']}),
            lambda m: m['rpms'][0].update(repository={'id': 'fedora', 'url': 'http://example.org/'}),
            lambda m: m['rpms'][0].update(repository={'id': 'fedora', 'url': 'https://user:secret@example.org/'}),
            lambda m: m['rpms'][0].update(repository={'id': 'fedora', 'url': 'https://example.org:bad/'}),
            lambda m: m['rpms'][0].update(repository={}),
        ]
        for mutation in mutations:
            manifest = deepcopy(self.manifest)
            mutation(manifest)
            self.write_manifest(manifest)
            with self.subTest(manifest=manifest), self.assertRaises(ValueError):
                self.bundle()
        (self.directory / inputs.MANIFEST).write_text('{"schema": 1, "schema": 1}')
        with self.assertRaisesRegex(ValueError, 'Duplicate manifest key'):
            self.bundle()

    def test_hash_size_total_count_manifest_bounds_and_fifo(self):
        self.rpm.write_bytes(b'x' * self.record['size'])
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.bundle()
        self.rpm.write_bytes(b'x')
        with self.assertRaisesRegex(ValueError, 'size mismatch'):
            self.bundle()
        self.rpm.unlink()
        os.mkfifo(self.rpm)
        with self.assertRaisesRegex(ValueError, 'regular file'):
            self.bundle()
        with patch.object(inputs, 'MAX_TOTAL_BYTES', 1):
            with self.assertRaisesRegex(ValueError, 'total size'):
                self.bundle()
        self.manifest['rpms'] *= inputs.MAX_RPMS + 1
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'count'):
            self.bundle()
        (self.directory / inputs.MANIFEST).write_bytes(b' ' * (inputs.MAX_MANIFEST_BYTES + 1))
        with self.assertRaisesRegex(ValueError, 'bounded regular file'):
            self.bundle()

    def test_changed_inputs_fail_revalidation_and_snapshot_before_transfer(self):
        bundle = self.bundle()
        with inputs.transfer_stream(bundle, self.record) as stream:
            self.assertEqual(stream.read(), self.rpm.read_bytes())
        self.rpm.write_bytes(b'x' * self.record['size'])
        with self.assertRaisesRegex(ValueError, 'checksum changed'):
            with inputs.transfer_stream(bundle, self.record):
                self.fail('Changed bytes must never reach transport')
        self.rpm.write_bytes(b'inert RPM fixture')
        self.manifest['rpms'][0]['repository']['id'] = 'updates'
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'manifest changed'):
            bundle.revalidate()

    def test_creator_produces_the_verifiable_contract_without_replacing_manifest(self):
        with self.assertRaisesRegex(ValueError, 'replace'):
            inputs.create_manifest(self.directory, *self.artifacts.values(), {})
        (self.directory / inputs.MANIFEST).unlink()
        identity = {key: self.record[key] for key in ('name', 'nevra', 'architecture', 'signature')}
        with patch.object(inputs, 'rpm_identity', return_value=identity):
            bundle = inputs.create_manifest(self.directory, *self.artifacts.values(),
                                            {self.rpm.name: self.record['repository']})
        self.assertEqual(bundle.evidence(), self.bundle().evidence())
        self.assertEqual(bundle.manifest['rpms'], [self.record])

    def test_rpm_identity_generator_uses_exact_metadata_and_signature_header(self):
        output = '\n'.join(['patch', '0', '2.8', '1.fc44', 'x86_64', SIGNATURE['value'],
                            '(none)', '(none)', '(none)']) + '\n'
        with patch.object(inputs.subprocess, 'run', return_value=SimpleNamespace(stdout=output)) as command:
            identity = inputs.rpm_identity(self.rpm)
        self.assertEqual(identity, {key: self.record[key] for key in ('name', 'nevra', 'architecture', 'signature')})
        self.assertEqual(command.call_args.kwargs['env']['LC_ALL'], 'C')
        self.assertEqual(command.call_args.kwargs['env']['TZ'], 'UTC')
        with patch.object(inputs.subprocess, 'run', return_value=SimpleNamespace(stdout=output.replace(SIGNATURE['value'], '(none)'))):
            with self.assertRaisesRegex(ValueError, 'unsigned'):
                inputs.rpm_identity(self.rpm)

    def raw_fixture(self):
        (self.directory / inputs.MANIFEST).unlink()
        provenance = self.root / 'provenance.json'
        provenance.write_text(json.dumps({self.rpm.name: self.record['repository']}))
        identity = {key: self.record[key] for key in ('name', 'nevra', 'architecture', 'signature')}
        return provenance, self.root / 'private-stage', identity

    def test_raw_snapshot_preserves_source_and_binds_only_after_candidates_exist(self):
        provenance, stage, identity = self.raw_fixture()
        original_rpm, original_provenance = self.rpm.read_bytes(), provenance.read_bytes()
        source_mode = self.rpm.stat().st_mode
        with patch.object(inputs, 'rpm_identity', return_value=identity):
            fixture = inputs.snapshot_raw_dependencies(self.directory, provenance, stage)
            self.assertEqual(fixture.records, [self.record])
            self.assertEqual(self.rpm.read_bytes(), original_rpm)
            self.assertEqual(self.rpm.stat().st_mode, source_mode)
            self.assertEqual(provenance.read_bytes(), original_provenance)
            self.assertNotEqual((stage / self.rpm.name).stat().st_ino, self.rpm.stat().st_ino)
            self.assertEqual(stage.stat().st_mode & 0o777, 0o700)
            self.assertEqual((stage / self.rpm.name).stat().st_mode & 0o777, 0o400)
            self.assertFalse((stage / inputs.MANIFEST).exists())
            evidence = fixture.evidence()
            self.assertEqual(evidence['provenance_sha256'], digest(provenance))
            self.assertEqual(evidence['total_bytes'], self.record['size'])
            self.assertEqual(len(evidence['fixture_sha256']), 64)
            self.assertNotIn('candidate_rpm_sha256', evidence)
            self.rpm.unlink()
            self.rpm.symlink_to(provenance)
            provenance.write_text('{}')
            for path in self.artifacts.values():
                path.write_bytes(b'fresh build: ' + path.name.encode())
            bundle = fixture.bind(*self.artifacts.values())
        self.assertEqual(bundle.manifest['rpms'], [self.record])
        self.assertEqual(bundle.manifest['candidate_rpm_sha256'], digest(self.artifacts['candidate_rpm']))
        with inputs.transfer_stream(bundle, self.record) as stream:
            self.assertEqual(stream.read(), original_rpm)
        self.assertFalse((self.directory / inputs.MANIFEST).exists())

    def test_raw_snapshot_rejects_symlink_and_fifo_before_rpm_parser(self):
        provenance, stage, _ = self.raw_fixture()
        original = self.rpm.read_bytes()
        for kind in ('rpm-link', 'rpm-fifo', 'directory-link', 'provenance-link'):
            self.rpm.unlink()
            self.rpm.write_bytes(original)
            directory, source = self.directory, provenance
            if kind == 'rpm-link':
                self.rpm.unlink()
                self.rpm.symlink_to(provenance)
            elif kind == 'rpm-fifo':
                self.rpm.unlink()
                os.mkfifo(self.rpm)
            elif kind == 'directory-link':
                directory = self.root / 'linked-directory'
                directory.symlink_to(self.directory, target_is_directory=True)
            else:
                source = self.root / 'linked-provenance'
                source.symlink_to(provenance)
            with self.subTest(kind=kind), patch.object(inputs, 'rpm_identity') as parser, \
                 self.assertRaises((ValueError, OSError)):
                inputs.snapshot_raw_dependencies(directory, source, stage)
            parser.assert_not_called()
            self.assertFalse(stage.exists())

    def test_raw_snapshot_bounds_provenance_rpm_count_size_and_total_before_parser(self):
        provenance, stage, _ = self.raw_fixture()
        for limit, value in (('MAX_MANIFEST_BYTES', 1), ('MAX_RPMS', 0),
                             ('MAX_RPM_BYTES', self.record['size'] - 1), ('MAX_TOTAL_BYTES', self.record['size'] - 1)):
            with self.subTest(limit=limit), patch.object(inputs, limit, value), \
                 patch.object(inputs, 'rpm_identity') as parser, self.assertRaises(ValueError):
                inputs.snapshot_raw_dependencies(self.directory, provenance, stage)
            parser.assert_not_called()
            self.assertFalse(stage.exists())

    def test_raw_provenance_rejects_duplicate_keys_traversal_unknown_and_missing_entries(self):
        provenance, stage, _ = self.raw_fixture()
        valid = {self.rpm.name: self.record['repository']}
        malformed = [
            '{"same": {}, "same": {}}', '[]', '{}',
            json.dumps({**valid, 'extra.rpm': self.record['repository']}),
            json.dumps({'../outside.rpm': self.record['repository']}),
            json.dumps({self.rpm.name: {**self.record['repository'], 'unchecked': 'extra'}}),
            json.dumps({self.rpm.name: {'id': 'fedora', 'url': 'https://user:secret@example.org/'}}),
        ]
        for value in malformed:
            provenance.write_text(value)
            with self.subTest(value=value), patch.object(inputs, 'rpm_identity') as parser, self.assertRaises(ValueError):
                inputs.snapshot_raw_dependencies(self.directory, provenance, stage)
            parser.assert_not_called()
            self.assertFalse(stage.exists())

    def test_duplicate_or_unsigned_raw_rpms_remove_partial_snapshot(self):
        provenance, stage, identity = self.raw_fixture()
        second = self.directory / 'patch-2.9-1.fc44.x86_64.rpm'
        second.write_bytes(b'another inert RPM')
        provenance.write_text(json.dumps({name: self.record['repository'] for name in (self.rpm.name, second.name)}))
        with patch.object(inputs, 'rpm_identity', return_value=identity), \
             self.assertRaisesRegex(ValueError, 'Duplicate raw dependency'):
            inputs.snapshot_raw_dependencies(self.directory, provenance, stage)
        self.assertFalse(stage.exists())
        self.assertTrue(second.exists())
        with patch.object(inputs, 'rpm_identity', side_effect=[identity, ValueError('Dependency RPM is unsigned')]), \
             self.assertRaisesRegex(ValueError, 'unsigned'):
            inputs.snapshot_raw_dependencies(self.directory, provenance, stage)
        self.assertFalse(stage.exists())

    def test_raw_fixture_that_cannot_fit_bound_manifest_fails_during_admission(self):
        provenance, stage, identity = self.raw_fixture()
        with patch.object(inputs, 'rpm_identity', return_value=identity), \
             patch.object(inputs, 'MAX_MANIFEST_BYTES', provenance.stat().st_size + 1), \
             self.assertRaisesRegex(ValueError, 'Raw dependency manifest exceeds size limit'):
            inputs.snapshot_raw_dependencies(self.directory, provenance, stage)
        self.assertFalse(stage.exists())

    def test_raw_snapshot_never_adopts_existing_stage_or_stages_in_caller_directory(self):
        provenance, stage, identity = self.raw_fixture()
        stage.mkdir()
        sentinel = stage / 'caller-file'
        sentinel.write_bytes(b'keep')
        with patch.object(inputs, 'rpm_identity', return_value=identity), self.assertRaises(FileExistsError):
            inputs.snapshot_raw_dependencies(self.directory, provenance, stage)
        self.assertEqual(sentinel.read_bytes(), b'keep')
        with self.assertRaisesRegex(ValueError, 'outside the caller'):
            inputs.snapshot_raw_dependencies(self.directory, provenance, self.directory / 'stage')
        self.assertFalse((self.directory / 'stage').exists())

    def test_guest_script_executes_identity_hash_and_trusted_signature_checks(self):
        # Real generated guest Python, with only the RPM executable replaced.
        tools = self.root / 'bin'
        tools.mkdir()
        rpm = tools / 'rpm'
        log = self.root / 'rpm.log'
        rpm.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['RPM_LOG'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
if '-qp' in sys.argv:
    print(os.environ['RPM_IDENTITY'])
else:
    print(os.environ['RPM_CHECKSIG'])
    raise SystemExit(int(os.environ.get('RPM_STATUS', '0')))
''')
        rpm.chmod(0o755)
        identity = '\n'.join((self.record['nevra'], self.record['architecture'], SIGNATURE['value']))
        environment = {**os.environ, 'PATH': str(tools) + ':' + os.environ['PATH'], 'RPM_LOG': str(log),
                       'RPM_IDENTITY': identity, 'RPM_CHECKSIG': 'Header V4 RSA/SHA256 Signature, key ID 0123456789abcdef: OK'}
        script = inputs.guest_verification_script(self.directory, [self.record])
        # The guest directory contains RPMs only; manifest stays on the host.
        (self.directory / inputs.MANIFEST).unlink()
        result = subprocess.run(['bash', '-e', '-s'], input=script, text=True, capture_output=True, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertIn('--checksig', calls[1])
        self.assertNotIn('--import', str(calls))
        self.assertNotIn('--dbpath', str(calls))
        for changes in ({'RPM_CHECKSIG': 'Payload SHA256 digest: OK'},
                        {'RPM_CHECKSIG': 'Header V4 RSA Signature, key ID 0123456789abcdef: NOKEY', 'RPM_STATUS': '1'},
                        {'RPM_CHECKSIG': 'Header V4 RSA Signature, key ID 0123456789abcdef: BAD', 'RPM_STATUS': '1'},
                        {'RPM_IDENTITY': identity.replace('patch-0:', 'patch-1:')},
                        {'RPM_IDENTITY': identity.replace('Key ID 0123456789abcdef', 'Key ID fedcba9876543210')}):
            with self.subTest(changes=changes):
                result = subprocess.run(['bash', '-e', '-s'], input=script, text=True, capture_output=True,
                                        env={**environment, **changes})
                self.assertNotEqual(result.returncode, 0)
        self.rpm.write_bytes(b'x' * self.record['size'])
        result = subprocess.run(['bash', '-e', '-s'], input=script, text=True, capture_output=True, env=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum mismatch', result.stderr)

    def test_copy_dependencies_uses_bounded_snapshot_and_always_cleans_up(self):
        bundle = self.bundle()
        vm = SimpleNamespace(ssh=['ssh', 'fixture'])
        directory = '/tmp/cybexos-qualification-dependencies.0123456789'
        calls = []
        def command(args, **kwargs):
            calls.append(args[-1])
            if args[-1].startswith('mktemp'):
                return SimpleNamespace(stdout=directory + '\n')
            if args[-1].startswith('cat >'):
                self.assertEqual(kwargs['stdin'].read(), self.rpm.read_bytes())
            return SimpleNamespace(stdout='')
        sealed_directory = '/tmp/cybexos-qualification-sealed-01234567'
        sealed = {'directory': sealed_directory, 'candidate': sealed_directory + '/candidates/candidate.rpm',
                  'offline_candidate': sealed_directory + '/candidates/offline_candidate.rpm',
                  'dependencies': [sealed_directory + '/dependencies/' + self.rpm.name]}
        for failure in (None, 'signature', 'cleanup'):
            root_calls = []
            def verifier(vm, script, password, **kwargs):
                root_calls.append(script)
                if script.startswith('rm -rf'):
                    if failure == 'cleanup':
                        raise RuntimeError('root cleanup failed')
                elif failure == 'signature':
                    raise RuntimeError('guest signature failed')
                return SimpleNamespace(stdout=json.dumps(sealed))
            with self.subTest(failure=failure), patch.object(upgrade, 'run', side_effect=command):
                if failure:
                    expected = 'signature failed' if failure == 'signature' else 'Could not remove root-owned.*01234567'
                    with self.assertRaisesRegex(RuntimeError, expected):
                        with upgrade.copy_dependencies(vm, bundle, 'password', verifier):
                            if failure == 'signature':
                                self.fail('Invalid signature reached installation')
                else:
                    with upgrade.copy_dependencies(vm, bundle, 'password', verifier) as paths:
                        self.assertEqual(paths, sealed)
            self.assertIn('seal_guest_inputs(', root_calls[0])
            if failure != 'signature':
                self.assertEqual(root_calls[-1], 'rm -rf -- ' + sealed_directory + '\n')
            self.assertEqual(calls[-1], 'rm -rf -- ' + directory)

    def root_fixture(self, program):
        """Only bounded temporary files/processes; no RPM installs or VM resources."""
        prefix = []
        if os.geteuid() != 0:
            if not shutil.which('sudo') or subprocess.run(['sudo', '-n', 'true'], capture_output=True).returncode:
                self.skipTest('Root file-ownership regression requires noninteractive sudo')
            prefix = ['sudo', '-n']
        firstparty = {key: {'source': str(self.artifacts[arg]), 'size': self.artifacts[arg].stat().st_size,
                            'sha256': digest(self.artifacts[arg])}
                      for key, arg in (('candidate', 'candidate_rpm'), ('offline_candidate', 'candidate_offline_rpm'))}
        setup = f'''import sys
sys.path.insert(0, {str(Path(inputs.__file__).parent)!r})
import offline_upgrade_inputs as inputs
root = {str(self.root)!r}
source_directory = {str(self.directory)!r}
record = {self.record!r}
firstparty = {firstparty!r}
adversary_uid = {os.getuid() if os.getuid() else 65534}
adversary_gid = {os.getgid() if os.getgid() else 65534}
'''
        result = subprocess.run([*prefix, sys.executable, '-B', '-c', setup + program], text=True,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_root_sealed_inodes_resist_original_replacement_and_retained_writer(self):
        self.root_fixture(r'''
from contextlib import redirect_stdout
import io, json, os, shutil, stat, subprocess
from pathlib import Path
from unittest.mock import patch

for path in (Path(root), Path(source_directory), *(Path(item['source']) for item in firstparty.values()),
             Path(source_directory) / record['filename']):
    os.chown(path, adversary_uid, adversary_gid)
originals = [firstparty['candidate']['source'], firstparty['offline_candidate']['source'],
             str(Path(source_directory) / record['filename'])]
# Represents an fd the account opened before root began the copy.
writer = os.open(originals[0], os.O_WRONLY)
rpm_paths = []
def rpm_command(command, **kwargs):
    copied = Path(command[-1])
    assert copied.stat().st_uid == 0
    assert stat.S_IMODE(copied.stat().st_mode) == 0o400
    assert 'cybexos-qualification-sealed-' in str(copied)
    rpm_paths.append(str(copied))
    output = (record['nevra'] + '\n' + record['architecture'] + '\n' + record['signature']['value'] + '\n'
              if '-qp' in command else 'Header V4 RSA/SHA256 Signature: OK\n')
    return subprocess.CompletedProcess(command, 0, output)

sealed = None
try:
    script = inputs.guest_sealing_script(source_directory, [record], firstparty)
    guest = script.split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
    output = io.StringIO()
    with patch.object(inputs.subprocess, 'run', side_effect=rpm_command):
        with redirect_stdout(output):
            exec(compile(guest, '<guest-root-sealing>', 'exec'), {})
    sealed = json.loads(output.getvalue())
    directory = Path(sealed['directory'])
    assert directory.stat().st_uid == 0 and stat.S_IMODE(directory.stat().st_mode) == 0o700
    paths = [sealed['candidate'], sealed['offline_candidate'], *sealed['dependencies']]
    expected = [firstparty['candidate']['sha256'], firstparty['offline_candidate']['sha256'], record['sha256']]
    for original, copied in zip(originals, paths):
        assert Path(copied).stat().st_ino != Path(original).stat().st_ino
        assert Path(copied).stat().st_uid == 0 and stat.S_IMODE(Path(copied).stat().st_mode) == 0o400

    # Simulated recovery interval: the original account changes all sources,
    # including through the fd it retained before root verified the new inodes.
    attack = r"""
import json, os, sys
from pathlib import Path
originals, sealed, writer = json.loads(sys.argv[1]), json.loads(sys.argv[2]), int(sys.argv[3])
os.write(writer, b'changed via retained fd')
for original in originals[1:]:
    path = Path(original)
    replacement = path.with_suffix('.evil')
    replacement.write_bytes(b'different malicious RPM')
    path.unlink()
    path.symlink_to(replacement)
for copied in sealed:
    try:
        Path(copied).write_bytes(b'overwrite sealed input')
    except PermissionError:
        pass
    else:
        raise AssertionError('Account could write sealed RPM')
directory = Path(sealed[0]).parent.parent
try:
    directory.rename(str(directory) + '-stolen')
except PermissionError:
    pass
else:
    raise AssertionError('Account could replace root staging directory')
"""
    subprocess.run([sys.executable, '-c', attack, json.dumps(originals), json.dumps(paths), str(writer)],
                   user=adversary_uid, group=adversary_gid, extra_groups=[], pass_fds=(writer,), check=True)
    assert all(inputs.digest(path) != sha for path, sha in zip(originals, expected))
    # These are the paths the DNF transaction reopens; all retain verified bytes.
    assert [inputs.digest(path) for path in paths] == expected
    assert rpm_paths == [sealed['dependencies'][0], sealed['dependencies'][0]]
finally:
    os.close(writer)
    if sealed:
        shutil.rmtree(sealed['directory'])
        assert not Path(sealed['directory']).exists()
''')

    def test_root_sealing_rejects_symlink_size_hash_and_signature_failures_and_cleans(self):
        self.root_fixture(r'''
import os, shutil, tempfile
from pathlib import Path
from unittest.mock import patch

created = []
mkdtemp = tempfile.mkdtemp
def remember(*args, **kwargs):
    directory = mkdtemp(*args, **kwargs)
    created.append(Path(directory))
    return directory

original = Path(firstparty['candidate']['source'])
saved = original.read_bytes()
dependency = Path(source_directory) / record['filename']
for failure in ('candidate-symlink', 'dependency-symlink', 'candidate-hash', 'candidate-size', 'signature'):
    candidate = {key: dict(value) for key, value in firstparty.items()}
    replacement = Path(root) / 'substituted.rpm'
    replacement.write_bytes(saved)
    if failure == 'candidate-symlink':
        original.unlink()
        original.symlink_to(replacement)
    elif failure == 'dependency-symlink':
        dependency.unlink()
        dependency.symlink_to(replacement)
    elif failure == 'candidate-hash':
        candidate['candidate']['sha256'] = '0' * 64
    elif failure == 'candidate-size':
        candidate['candidate']['size'] += 1
    try:
        with patch.object(tempfile, 'mkdtemp', side_effect=remember), \
             patch.object(inputs, 'verify_guest', side_effect=ValueError('signature rejected')):
            try:
                inputs.seal_guest_inputs(source_directory, [record], candidate)
            except (OSError, ValueError):
                pass
            else:
                raise AssertionError('Invalid input reached recovery/installation')
        assert created and not any(directory.exists() for directory in created)
    finally:
        if original.is_symlink():
            original.unlink()
            original.write_bytes(saved)
        if dependency.is_symlink():
            dependency.unlink()
            dependency.write_bytes(b'inert RPM fixture')
''')

    def test_invalid_bundle_and_missing_companion_fail_before_vm_creation(self):
        base = ['qualify', str(self.artifacts['baseline_iso']), '--output', str(self.root / 'output'),
                '--execute-vm', '--erase-disposable-disk', '--candidate-dependencies', str(self.directory)]
        for candidates in ([], ['--candidate-rpm', str(self.artifacts['candidate_rpm']),
                               '--candidate-offline-rpm', str(self.artifacts['candidate_offline_rpm'])]):
            if candidates:
                self.rpm.write_bytes(b'tampered')
            with self.subTest(candidates=candidates), patch('sys.argv', base + candidates), \
                    patch.object(qualification.signal, 'signal'), \
                    patch.object(qualification, 'require_test_iso', return_value=self.artifacts['baseline_iso']), \
                    patch.object(qualification, 'TestVM') as vm, patch('sys.stderr', new_callable=io.StringIO):
                with self.assertRaises(SystemExit):
                    qualification.main()
                vm.assert_not_called()

    def test_cli_verifier_reports_exact_bundle_without_requiring_host_rpm(self):
        command = ['python3', str(Path(inputs.__file__)), 'verify', str(self.directory)]
        for key, path in self.artifacts.items():
            command += ['--' + key.replace('_', '-'), str(path)]
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), self.bundle().evidence())

    def test_qualification_records_fixture_and_fresh_iso_api_still_works(self):
        for with_dependencies in (True, False):
            with self.subTest(with_dependencies=with_dependencies), ExitStack() as stack:
                output = self.root / ('upgrade' if with_dependencies else 'fresh')
                vm = Mock(owned=True, work=self.root, unused_disk=self.artifacts['baseline_iso'], ssh=['ssh', 'fixture'])
                vm.prepare.side_effect = lambda: output.mkdir()
                versions = {'candidate_offline_rpm_sha256': self.manifest['candidate_offline_rpm_sha256'],
                            'recovery_point': 'recovery123'}
                result = (self.manifest['candidate_rpm_sha256'], versions)
                arguments = ['qualify', str(self.artifacts['baseline_iso']), '--output', str(output),
                             '--execute-vm', '--erase-disposable-disk', '--scenario', 'plain-us']
                if with_dependencies:
                    arguments += ['--candidate-rpm', str(self.artifacts['candidate_rpm']), '--candidate-offline-rpm',
                                  str(self.artifacts['candidate_offline_rpm']), '--candidate-dependencies', str(self.directory),
                                  '--legacy-installer']
                stack.enter_context(patch('sys.argv', arguments))
                stack.enter_context(patch('sys.stdout', new_callable=io.StringIO))
                stack.enter_context(patch.object(qualification.signal, 'signal'))
                stack.enter_context(patch.object(qualification, 'require_test_iso', return_value=self.artifacts['baseline_iso']))
                stack.enter_context(patch.object(qualification, 'TestVM', return_value=vm))
                stack.enter_context(patch.object(qualification.subprocess, 'run',
                                             return_value=SimpleNamespace(returncode=0 if with_dependencies else 1)))
                for name in ('browser_dependencies', 'run', 'ensure_installer_started', 'boot_installed',
                             'verify_installed_audit', 'poweroff_guest', 'verify_user_choices'):
                    stack.enter_context(patch.object(qualification, name))
                stack.enter_context(patch.object(qualification, 'qualification_disks', return_value=('vda', 'vdb')))
                stack.enter_context(patch.object(qualification, 'qualify_browser', return_value={'boot_keyboard': 'us'}))
                stack.enter_context(patch.object(qualification, 'prepare_user_choices', return_value='bottom'))
                point = stack.enter_context(patch.object(qualification, 'create_recovery_point'))
                upgrade_call = stack.enter_context(patch.object(qualification, 'upgrade', return_value=result))
                qualification.main()
                report = json.loads((output / 'qualification.json').read_text())
                self.assertEqual(report['status'], 'passed')
                point.assert_not_called()  # Dependency upgrades own their pre-transaction point.
                if with_dependencies:
                    evidence = report['candidate_dependencies']
                    self.assertEqual(evidence['manifest_sha256'], self.bundle().manifest_sha256)
                    self.assertEqual(evidence['rpms'], [self.record])
                    self.assertIs(evidence['guest_signatures_verified'], True)
                    self.assertEqual(report['pre_upgrade_recovery_point'], 'recovery123')
                    self.assertIn('candidate_dependencies', upgrade_call.call_args.kwargs)
                else:
                    upgrade_call.assert_not_called()
                    self.assertNotIn('candidate_dependencies', report)


class UpgradeTransaction(unittest.TestCase):
    def exercise(self, bundle=True, failure=None, offline_comparison=0):
        events = []
        scripts = []
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        desktop_path = Path(temporary.name) / 'desktop.rpm'
        offline_path = Path(temporary.name) / 'offline.rpm'
        desktop_path.write_bytes(b'desktop')
        offline_path.write_bytes(b'offline')
        vm = SimpleNamespace(ssh=['ssh', 'fixture'])
        candidate = {'name': 'cybexos-desktop', 'epoch': '0', 'version': '2', 'release': '1'}
        versions = {'comparison': 1, 'installed': {**candidate, 'version': '1'}, 'candidate': candidate}
        offline = {'comparison': offline_comparison, 'installed': {}, 'candidate': {}}
        dependencies = SimpleNamespace(manifest={'candidate_rpm_sha256': 'a' * 64,
                                                'candidate_offline_rpm_sha256': 'b' * 64, 'rpms': []},
                                       revalidate=lambda: events.append('admission')) if bundle else None
        if dependencies:
            dependencies.manifest['rpms'] = [{'filename': 'patch.rpm'}]
        sealed_directory = '/tmp/cybexos-qualification-sealed-01234567'
        sealed = {'directory': sealed_directory, 'candidate': sealed_directory + '/candidates/candidate.rpm',
                  'offline_candidate': sealed_directory + '/candidates/offline_candidate.rpm',
                  'dependencies': [sealed_directory + '/dependencies/patch.rpm']}
        def command(args, **kwargs):
            if args[-1].startswith('mktemp'):
                return SimpleNamespace(stdout='/tmp/cybexos-qualification-dependencies.0123456789\n')
            if args[-1].startswith('rm -rf'):
                events.append('cleanup-user')
            return SimpleNamespace(stdout='')
        def root_script(vm, script, password, **kwargs):
            scripts.append(script)
            if 'seal_guest_inputs(' in script:
                events.append('signatures')
                if failure == 'signature':
                    raise RuntimeError('untrusted dependency')
                return SimpleNamespace(stdout=json.dumps(sealed))
            if script.startswith('rm -rf'):
                events.append('cleanup-root')
            if script.startswith('dnf '):
                events.append('install')
                if failure == 'install':
                    raise RuntimeError('DNF rejected transaction')
            if 'sha256sum' in script:
                return SimpleNamespace(stdout='configsha file\n')
            return SimpleNamespace(stdout=json.dumps({'state': 'ready', 'pending': False, 'version': '2',
                'desiredVersion': '2', 'accounts': {'qualification': {'state': 'ready'}}}))
        def recovery(*args, **kwargs):
            events.append('recovery')
            if failure == 'recovery':
                raise RuntimeError('recovery unavailable')
            return 'recovery123'
        with patch.object(upgrade, 'copy_candidate', side_effect=['a' * 64, 'b' * 64]), \
                patch.object(upgrade, 'inspect_version', side_effect=[versions, offline, {'installed': candidate}]) as inspect, \
                patch.object(upgrade, 'create_recovery_point', side_effect=recovery), \
                patch.object(upgrade, 'transfer_stream', return_value=nullcontext(object())), \
                patch.object(upgrade, 'run', side_effect=command):
            if failure or offline_comparison < 0:
                with self.assertRaises(RuntimeError):
                    upgrade.upgrade(vm, desktop_path, 'password', root_script, offline_path,
                                    candidate_dependencies=dependencies)
                result = None
            else:
                result = upgrade.upgrade(vm, desktop_path, 'password', root_script, offline_path,
                                         candidate_dependencies=dependencies)
            self.inspections = inspect.call_args_list
        return events, scripts, result

    def test_recovery_precedes_single_transaction_and_no_network_or_preinstall(self):
        events, scripts, result = self.exercise()
        self.assertEqual(events, ['admission', 'signatures', 'recovery', 'install', 'cleanup-root', 'cleanup-user'])
        transactions = [script for script in scripts if script.startswith('dnf ')]
        self.assertEqual(len(transactions), 1)
        self.assertIn("--disablerepo='*' install", transactions[0])
        self.assertIn('/tmp/cybexos-qualification-sealed-01234567/candidates/candidate.rpm', transactions[0])
        self.assertIn('/tmp/cybexos-qualification-sealed-01234567/candidates/offline_candidate.rpm', transactions[0])
        self.assertIn('/tmp/cybexos-qualification-sealed-01234567/dependencies/patch.rpm', transactions[0])
        self.assertNotIn(upgrade.CANDIDATE, transactions[0])
        self.assertNotIn(upgrade.OFFLINE_CANDIDATE, transactions[0])
        for call in self.inspections:
            candidate_path = call.kwargs['candidate'] if 'candidate' in call.kwargs else call.args[2]
            self.assertIn('/cybexos-qualification-sealed-', candidate_path)
            self.assertIn('root_script', call.kwargs)
        self.assertNotIn('--skip-broken', '\n'.join(scripts))
        self.assertNotIn('--nogpgcheck', '\n'.join(scripts))
        self.assertEqual(result[1]['candidate_offline_rpm_sha256'], 'b' * 64)
        self.assertEqual(result[1]['recovery_point'], 'recovery123')

    def test_signature_recovery_and_transaction_failures_clean_staging(self):
        for failure in ('signature', 'recovery', 'install'):
            with self.subTest(failure=failure):
                events, scripts, _ = self.exercise(failure=failure)
                if failure != 'install':
                    self.assertNotIn('install', events)
                if failure != 'signature':
                    self.assertEqual(events[-2:], ['cleanup-root', 'cleanup-user'])

    def test_companion_downgrade_fails_and_no_dependency_path_keeps_existing_api(self):
        events, _, _ = self.exercise(offline_comparison=-1)
        self.assertNotIn('recovery', events)
        self.assertNotIn('install', events)
        self.assertEqual(events[-2:], ['cleanup-root', 'cleanup-user'])
        events, scripts, result = self.exercise(bundle=False)
        self.assertEqual(events, ['install'])
        self.assertNotIn('recovery_point', result[1])
        self.assertEqual(result[0], 'a' * 64)


if __name__ == '__main__':
    unittest.main()
