"""Publisher-side regression checks using real isolated Ed25519 signatures."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lifecycle'))
from cybexos.common import Failure, atomic, read


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


manage = load('release_manage_checks', ROOT / 'release/manage.py')
assets = load('release_verify_assets_checks', ROOT / 'release/verify-assets.py')
REVISION = 'a' * 40
NAR = 'sha256-' + 'A' * 43 + '='


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='cybexos-release-tests-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.key = self.root / 'key'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'Ed25519', '-out', str(self.key)], check=True, capture_output=True)
        public = subprocess.check_output(['openssl', 'pkey', '-in', str(self.key), '-pubout'], text=True)
        self.trust = {'keys': {'publisher': {'publicKey': public, 'purposes': ['release', 'channel'],
                                           'notAfter': '2099-01-01T00:00:00Z'}}}

    def report(self):
        return {'revision': REVISION, 'narHash': NAR, 'kind': 'installation-update-and-physical-qualification',
                'checks': {name: {'result': 'passed', 'evidence': 'isolated-test-fixture'} for name in manage.REQUIRED}}

    def prepare(self, version):
        directory = self.root / version
        directory.mkdir()
        for name in ('cybexos-source.tar.gz', 'release-notes.md', 'SHA256SUMS', f'cybexos-{version}-x86_64-linux.iso'):
            (directory / name).write_bytes(b'regression fixture, not release evidence\n')
        atomic(directory / 'qualification.json', self.report())
        manage.manifest(directory, version, REVISION, NAR, 'Test notes', ['lanzaboote'])
        manifest = directory / 'manifest.json'
        manage.sign(manifest, self.key, 'publisher', self.trust, 'release')
        return manifest

    def published(self, manifest, sequence=5):
        previous = self.root / 'previous.json'
        document = manage.channel(manifest, 'stable', sequence, trust=self.trust)
        # Expired documents may be refreshed without lowering source/version.
        document['expires'] = '2000-01-01T00:00:00Z'
        atomic(previous, document)
        manage.sign(previous, self.key, 'publisher', self.trust, 'channel')
        data = {document['manifest']: manifest.read_bytes(),
                document['manifest'] + '.sig': Path(str(manifest) + '.sig').read_bytes()}

        class Fetch:
            def get(self, url):
                return data[url]

        return previous, Fetch()

    def test_required_assets_and_complete_same_source_qualification(self):
        directory = self.root / 'incomplete'
        directory.mkdir()
        with self.assertRaises(Failure):
            manage.manifest(directory, '1.0.0', REVISION, NAR, '', [])
        report = self.report()
        for malformed in (None, [], {'encrypted-install': 'passed'}):
            with self.subTest(malformed=malformed), self.assertRaises(Failure):
                manage.gate(report | {'checks': malformed}, REVISION, NAR)
        with self.assertRaises(Failure):
            manage.gate(report | {'narHash': 'sha256-' + 'B' * 43 + '='}, REVISION, NAR)

    def test_workflow_staged_iso_matches_authenticated_manifest_contract(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        commands = [line.strip() for line in workflow.splitlines() if line.strip().startswith('cp "$image" ')]
        self.assertEqual(len(commands), 1, 'Release workflow must stage exactly one qualified ISO')
        image = self.root / f'cybexos-{REVISION}-123-1.iso'
        image.write_bytes(b'qualified ISO fixture bytes\n')
        directory = self.root / 'release-output'
        directory.mkdir()
        subprocess.run(['bash', '-euc', commands[0]], cwd=self.root,
                       env=dict(os.environ, TAG='v1.2.3-beta.1', image=str(image)), check=True)
        for name in ('cybexos-source.tar.gz', 'release-notes.md', 'SHA256SUMS'):
            (directory / name).write_bytes(b'regression fixture, not release evidence\n')
        atomic(directory / 'qualification.json', self.report())
        manage.manifest(directory, '1.2.3-beta.1', REVISION, NAR, 'Test notes', ['lanzaboote'])
        staged = directory / 'cybexos-1.2.3-beta.1-x86_64-linux.iso'
        self.assertEqual(staged.read_bytes(), image.read_bytes())
        declared = next(asset for asset in read(directory / 'manifest.json')['assets'] if asset['name'] == staged.name)
        self.assertEqual(declared['sha256'], hashlib.sha256(image.read_bytes()).hexdigest())

    def test_local_assets_and_publisher_key_verified_before_publication(self):
        manifest = self.prepare('1.0.0')
        self.assertEqual(assets.verify_assets(manifest, self.trust, local=True)['revision'], REVISION)
        with self.assertRaises(Failure):
            assets.verify_assets(manifest, {'keys': {}}, local=True)
        (manifest.parent / 'cybexos-source.tar.gz').write_bytes(b'changed')
        with self.assertRaises(Failure):
            assets.verify_assets(manifest, self.trust, local=True)

    def test_promotion_binds_authenticated_manifest_to_selected_tag_source(self):
        manifest = self.prepare('1.0.0')
        expected = dict(expected_version='1.0.0', expected_revision=REVISION, expected_nar_hash=NAR)
        self.assertEqual(assets.verify_assets(manifest, self.trust, local=True, **expected)['version'], '1.0.0')
        # Each mismatched identity must fail before fetching an asset from the
        # stale, otherwise valid signed manifest's own release URLs.
        for field, value in (('expected_version', '2.0.0'), ('expected_revision', 'b' * 40),
                             ('expected_nar_hash', 'sha256-' + 'B' * 43 + '=')):
            with self.subTest(field=field), patch.object(assets.urllib.request, 'urlopen') as fetch:
                with self.assertRaisesRegex(Failure, 'selected tag/source'):
                    assets.verify_assets(manifest, self.trust, **(expected | {field: value}))
                fetch.assert_not_called()
        with self.assertRaisesRegex(Failure, 'together'):
            assets.verify_assets(manifest, self.trust, local=True, expected_version='1.0.0')

    def test_signing_rejects_wrong_key_id_and_purpose_before_delivery(self):
        document = self.root / 'channel.json'
        atomic(document, {'regression': True})
        with self.assertRaises(Failure):
            manage.sign(document, self.key, 'unknown', self.trust, 'channel')
        self.trust['keys']['publisher']['purposes'] = ['release']
        with self.assertRaises(Failure):
            manage.sign(document, self.key, 'publisher', self.trust, 'channel')

    def test_promotion_rejects_downgrade_and_nonadvancing_sequence(self):
        previous, fetch = self.published(self.prepare('2.0.0'))
        older = self.prepare('1.0.0')
        with self.assertRaises(Failure):
            manage.channel(older, 'stable', 6, previous, self.trust, fetch)
        newer = self.prepare('2.1.0')
        with self.assertRaises(Failure):
            manage.channel(newer, 'stable', 5, previous, self.trust, fetch)
        self.assertEqual(manage.channel(newer, 'stable', 6, previous, self.trust, fetch)['sequence'], 6)

    def test_renewal_authenticates_previous_and_candidate_bytes(self):
        manifest = self.prepare('1.0.0')
        previous, fetch = self.published(manifest)
        renewed = manage.channel(manifest, 'stable', 6, previous, self.trust, fetch)
        self.assertEqual(renewed['sha256'], hashlib.sha256(manifest.read_bytes()).hexdigest())
        atomic(previous, read(previous) | {'sequence': 1})
        with self.assertRaises(Failure):
            manage.channel(manifest, 'stable', 6, previous, self.trust, fetch)
        manifest.write_bytes(manifest.read_bytes() + b' ')
        with self.assertRaises(Failure):
            manage.channel(manifest, 'stable', 6, trust=self.trust)


class ImmutablePolicyPreflight(unittest.TestCase):
    """Exercise the real publisher guard with an isolated GitHub CLI boundary."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='cybexos-immutable-policy-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        command = self.root / 'gh'
        command.write_text('#!' + sys.executable + '\n' + '''import json,os,sys
from pathlib import Path
Path(os.environ['QA_API_RECORD']).write_text(json.dumps({'args':sys.argv[1:],'token':os.environ.get('GH_TOKEN')}))
print(os.environ.get('QA_API_RESPONSE','true'))
sys.exit(int(os.environ.get('QA_API_EXIT','0')))
''')
        command.chmod(0o755)
        self.environment = os.environ | {
            'PATH': str(self.root) + os.pathsep + os.environ.get('PATH', ''),
            'GH_TOKEN': 'fixture-publishing-credential',
            'IMMUTABILITY_CHECK_TOKEN': 'fixture-policy-credential',
            'GITHUB_REPOSITORY': 'example/cybexos',
            'QA_API_RECORD': str(self.root / 'request.json'),
        }

    def run_guard(self, **changes):
        return subprocess.run([str(ROOT / 'release/require-immutable-releases')],
                              env=self.environment | changes, text=True,
                              capture_output=True, timeout=5)

    def test_enabled_policy_uses_separate_read_only_credential(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        request = json.loads((self.root / 'request.json').read_text())
        self.assertEqual(request['args'], ['api', 'repos/example/cybexos/immutable-releases', '--jq', '.enabled'])
        self.assertEqual(request['token'], 'fixture-policy-credential')
        self.assertEqual(self.environment['GH_TOKEN'], 'fixture-publishing-credential')

    def test_disabled_or_invalid_policy_fails_closed(self):
        for response in ['false', 'null', 'True', '']:
            with self.subTest(response=response):
                result = self.run_guard(QA_API_RESPONSE=response)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Enable immutable releases', result.stderr)

    def test_api_failure_blocks_publication_with_actionable_message(self):
        result = self.run_guard(QA_API_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('publication is blocked', result.stderr)
        self.assertNotIn('fixture-policy-credential', result.stdout + result.stderr)

    def test_missing_policy_credential_does_not_fall_back_to_publisher(self):
        result = self.run_guard(IMMUTABILITY_CHECK_TOKEN='')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Administration read permission', result.stderr)
        self.assertFalse((self.root / 'request.json').exists())

    def test_workflow_checks_before_draft_and_again_before_publication(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        publish = workflow.split('- name: Publish all assets together and verify public delivery', 1)[1]
        lines = [line.strip() for line in publish.splitlines()]
        guards = [n for n, line in enumerate(lines) if line == 'release/require-immutable-releases']
        create = next(n for n, line in enumerate(lines) if line.startswith('gh release create '))
        upload = next(n for n, line in enumerate(lines) if line.startswith('gh release upload '))
        public = next(n for n, line in enumerate(lines) if line.startswith('gh release edit '))
        self.assertEqual(len(guards), 2)
        self.assertLess(guards[0], create)
        self.assertLess(upload, guards[1])
        self.assertLess(guards[1], public)


if __name__ == '__main__':
    unittest.main()
