"""Offline release staging gates, metadata integrity and ISO reconstruction."""
import gzip
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import github_release as release

loader = importlib.machinery.SourceFileLoader('reconstruct_iso', str(Path(__file__).with_name('reconstruct-iso')))
spec = importlib.util.spec_from_loader(loader.name, loader)
reconstruct = importlib.util.module_from_spec(spec)
loader.exec_module(reconstruct)
FINGERPRINT = 'A' * 40
REPOSITORY = 'DigitalPals/CybexOS'
TAG = 'v1.2.3'
BASE = 'https://digitalpals.github.io/CybexOS/44/x86_64'


def checksums(root):
    paths = sorted(path for path in root.rglob('*') if path.is_file() and path.name != 'SHA256SUMS')
    (root / 'SHA256SUMS').write_text(''.join(f'{release.sha256(path)}  {path.relative_to(root)}\n' for path in paths))


class GitHubRelease(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.signed, self.artifacts = self.root / 'signed', self.root / 'artifacts'
        self.output = self.root / 'result'
        (self.signed / 'Packages').mkdir(parents=True)
        (self.signed / 'repodata').mkdir()
        self.artifacts.mkdir()
        self.rpm = self.signed / 'Packages/cybexos-desktop.rpm'
        self.rpm.write_bytes(b'fixture signed RPM bytes')
        self.iso = self.artifacts / 'CybexOS-fixture.iso'
        self.iso.write_bytes(b'fixture ISO image bytes')
        checksums(self.artifacts)
        self.package = {'name': 'cybexos-desktop', 'epoch': '1', 'version': '1.2.3',
                        'release': '1.fc44', 'arch': 'x86_64',
                        'file': 'Packages/' + self.rpm.name,
                        'sha256': release.sha256(self.rpm), 'unsigned_input_sha256': 'b' * 64,
                        'url': release.github_url(REPOSITORY, TAG) + '/' + self.rpm.name}
        self.manifest = {'format': 1, 'fingerprint': FINGERPRINT, 'baseurl': BASE,
                         'packages': [self.package]}
        (self.signed / 'release.json.asc').write_text('fixture detached signature')
        (self.signed / 'CYBEXOS-desktop.asc').write_text('fixture public key')
        (self.signed / 'update-channel.json').write_text(json.dumps({
            'baseurl': BASE, 'fingerprint': FINGERPRINT, 'key_file': 'CYBEXOS-desktop.asc'}))
        self.metadata()
        self.reports = []
        for scenario in ('encrypted-us', 'plain-us', 'encrypted-nl', 'plain-nl'):
            self.report(scenario, release.sha256(self.iso), ['graphical-installer'])
        self.report('upgrade', 'c' * 64, ['installed-rpm-upgrade', 'recovery-boot-restore'], 'b' * 64)

    def metadata(self, package_url=None):
        package = self.package
        primary = ('<metadata xmlns="http://linux.duke.edu/metadata/common"><package type="rpm">'
                   '<name>cybexos-desktop</name><arch>x86_64</arch>'
                   '<version epoch="1" ver="1.2.3" rel="1.fc44"/>'
                   f'<checksum type="sha256">{package["sha256"]}</checksum>'
                   f'<location href="{package_url or package["url"]}"/></package></metadata>')
        metadata = self.signed / 'repodata/primary.xml.gz'
        metadata.write_bytes(gzip.compress(primary.encode()))
        repomd = ('<repomd xmlns="http://linux.duke.edu/metadata/repo"><data type="primary">'
                  f'<checksum type="sha256">{release.sha256(metadata)}</checksum>'
                  '<location href="repodata/primary.xml.gz"/></data></repomd>')
        (self.signed / 'repodata/repomd.xml').write_text(repomd)
        (self.signed / 'repodata/repomd.xml.asc').write_text('fixture detached signature')
        self.save_manifest()

    def save_manifest(self):
        (self.signed / 'release.json').write_text(json.dumps(self.manifest))
        checksums(self.signed)

    def report(self, scenario, iso, checks, rpm=None):
        path = self.root / (scenario + '.json')
        path.write_text(json.dumps({'scenario': scenario, 'iso_sha256': iso,
                                    'status': 'passed', 'checks': checks,
                                    'candidate_rpm_sha256': rpm}))
        self.reports.append(path)
        return path

    def prepare(self):
        # These fixtures are deliberately not signed releases or VM evidence.
        # Other tests cover the fail-closed signature subprocess boundary.
        with patch.object(release, 'verify_release') as signatures, patch.object(release, 'verify_signed_rpm') as rpm:
            result = release.prepare(self.signed, self.artifacts, self.output,
                                     REPOSITORY, TAG, FINGERPRINT, self.reports)
            self.assertEqual(signatures.call_count, 2)
            rpm.assert_called_once()
            return result

    def test_stages_qualified_release_and_metadata_without_rpm_on_pages(self):
        self.assertEqual(self.prepare(), self.output)
        self.assertTrue((self.output / 'assets' / self.rpm.name).is_file())
        self.assertFalse(list((self.output / 'pages').rglob('*.rpm')))
        self.assertTrue((self.output / 'assets/reconstruct-iso.py').is_file())
        self.assertEqual(len(json.loads((self.output / 'assets/qualification-reports.json').read_text())), 5)
        release.verify_checksums(self.output / 'assets', 'desktop-SHA256SUMS')
        release.verify_checksums(self.output / 'pages/44/x86_64')

    def test_checksum_inventory_cannot_hide_unlisted_files_or_symlinks(self):
        extra = self.signed / 'repodata/unlisted'
        extra.write_text('unlisted')
        with self.assertRaisesRegex(ValueError, 'inventory'):
            self.prepare()
        extra.unlink()
        extra.symlink_to(self.iso)
        with self.assertRaisesRegex(ValueError, 'regular'):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_checksum_path_escape_is_rejected(self):
        (self.signed / 'SHA256SUMS').write_text(f'{release.sha256(self.iso)}  ../artifacts/{self.iso.name}\n')
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            self.prepare()

    def test_invalid_signature_never_publishes(self):
        with patch.object(release, 'verify_release', side_effect=subprocess.CalledProcessError(1, ['gpg'])):
            with self.assertRaises(subprocess.CalledProcessError):
                release.prepare(self.signed, self.artifacts, self.output, REPOSITORY, TAG, FINGERPRINT, self.reports)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob('.cybexos-github-*')))

    def test_asset_limit_is_enforced_before_signatures_or_copying(self):
        with patch.object(release, 'ASSET_LIMIT', self.rpm.stat().st_size):
            with self.assertRaisesRegex(ValueError, '2 GiB'):
                self.prepare()
        self.assertFalse(self.output.exists())

    def test_release_tag_and_pages_channel_must_match(self):
        self.package['version'] = '1.2.4'
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'release tag'):
            self.prepare()
        self.package['version'] = '1.2.3'
        self.manifest['baseurl'] = 'https://unrelated.example/repo'
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'GitHub Pages'):
            self.prepare()

    def test_authenticated_metadata_must_reference_the_exact_uploaded_rpm(self):
        self.metadata(package_url='https://unrelated.example/package.rpm')
        with self.assertRaisesRegex(ValueError, 'package URL'):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_repodata_hash_is_verified_independently_of_checksum_inventory(self):
        (self.signed / 'repodata/primary.xml.gz').write_bytes(b'corrupt metadata')
        checksums(self.signed)
        with self.assertRaisesRegex(ValueError, 'metadata checksum'):
            self.prepare()

    def test_missing_fresh_scenario_and_wrong_iso_are_blocked(self):
        self.reports.pop(0)
        with self.assertRaisesRegex(ValueError, 'four fresh'):
            self.prepare()
        self.report('encrypted-us', 'd' * 64, ['graphical-installer'])
        with self.assertRaisesRegex(ValueError, 'four fresh'):
            self.prepare()

    def test_upgrade_requires_different_iso_exact_candidate_and_recovery(self):
        upgrade = self.reports[-1]
        base = json.loads(upgrade.read_text())
        for changes in ({'iso_sha256': release.sha256(self.iso)},
                        {'candidate_rpm_sha256': 'd' * 64},
                        {'checks': ['installed-rpm-upgrade']}):
            upgrade.write_text(json.dumps({**base, **changes}))
            with self.assertRaisesRegex(ValueError, 'prior ISO'):
                self.prepare()
        upgrade.write_text(json.dumps({**base, 'status': 'failed'}))
        with self.assertRaisesRegex(ValueError, 'must have passed'):
            self.prepare()

    def test_signed_verification_uses_the_expected_key_and_both_signatures(self):
        work = self.root / 'verify'
        work.mkdir()
        with patch.object(release, 'public_key') as key, patch.object(release.subprocess, 'run') as run:
            release.verify_release(self.signed, FINGERPRINT, work)
        key.assert_called_once_with(self.signed / 'CYBEXOS-desktop.asc', FINGERPRINT)
        self.assertEqual(len(run.call_args_list), 3)
        signatures = [call.args[0] for call in run.call_args_list[1:]]
        self.assertTrue(all('--verify' in command for command in signatures))
        self.assertIn(str(self.signed / 'release.json.asc'), signatures[0])
        self.assertIn(str(self.signed / 'repodata/repomd.xml.asc'), signatures[1])


class IsoReconstruction(unittest.TestCase):
    def test_chunks_reconstruct_exact_bytes_and_preserve_existing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, assets = root / 'CybexOS.iso', root / 'assets'
            assets.mkdir()
            source.write_bytes(bytes(range(256)) * 17)
            record = release.split_iso(source, assets, chunk_size=127)
            self.assertTrue(all(part['bytes'] <= 127 for part in record['parts']))
            manifest = assets / 'CybexOS.iso.parts.json'
            result = reconstruct.reconstruct(manifest)
            self.assertEqual(result.read_bytes(), source.read_bytes())
            self.assertEqual(release.sha256(result), record['sha256'])
            with self.assertRaisesRegex(ValueError, 'already exists'):
                reconstruct.reconstruct(manifest)
            self.assertFalse(list(assets.glob('.cybexos-iso-*')))

    def test_corruption_missing_parts_and_path_traversal_leave_no_partial_iso(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, assets = root / 'CybexOS.iso', root / 'assets'
            assets.mkdir()
            source.write_bytes(b'123456789')
            release.split_iso(source, assets, chunk_size=3)
            manifest = assets / 'CybexOS.iso.parts.json'
            record = json.loads(manifest.read_text())
            part = assets / record['parts'][0]['file']
            part.write_bytes(b'bad')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                reconstruct.reconstruct(manifest)
            part.unlink()
            with self.assertRaisesRegex(ValueError, 'regular'):
                reconstruct.reconstruct(manifest)
            record['parts'][0]['file'] = '../outside'
            manifest.write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'Invalid'):
                reconstruct.reconstruct(manifest)
            self.assertFalse((assets / 'CybexOS.iso').exists())
            self.assertFalse(list(assets.glob('.cybexos-iso-*')))

    def test_invalid_chunk_sizes_fail_before_creating_parts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'CybexOS.iso'
            source.write_bytes(b'image')
            for size in (0, -1, release.ASSET_LIMIT):
                with self.assertRaisesRegex(ValueError, 'part size'):
                    release.split_iso(source, root, size)
            self.assertEqual(list(root.iterdir()), [source])


if __name__ == '__main__':
    unittest.main()
