#!/usr/bin/env python3
"""Negative transitions for the PUBLIC distribution gate; no builds or network."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'image'))
import distribution_review as gate  # noqa: E402


class DistributionReview(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cybexos-distribution-review.')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.payload = self.root / 'payload'
        self.payload.mkdir()
        (self.payload / 'LICENSE').write_text('fixture original license\n')
        (self.payload / 'wallpaper.png').write_bytes(b'fixture original art')
        self.archive = self.root / 'source.tar.zst'
        self.archive.write_bytes(b'fixture archive')
        self.evidence = self.root / 'rights.txt'
        self.evidence.write_text('Test fixture decision only; this grants no real approval.\n')

    def capture(self, channel='source'):
        return gate.capture(channel, root=self.payload, artifacts=[self.archive])

    def review(self, inventory):
        return {'schema': 1, 'publication': 'PUBLIC', 'reviews': [{
            'channel': inventory['channel'], 'inventorySha256': gate.identity(inventory),
            'decision': 'approved', 'reviewedBy': 'Fixture owner',
            'reviewedAt': '2026-10-21T12:00:00Z', 'components': [{
                'name': 'Fixture only', 'license': 'MIT', 'decision': 'approved',
                'obligations': 'Retain fixture notice', 'trademarks': 'not-applicable',
                'evidence': {'path': 'rights.txt', 'sha256': gate.digest(self.evidence)},
                'items': list(inventory['items'])}]}]}

    def test_complete_review_passes_and_empty_repository_review_fails(self):
        inventory = self.capture()
        result = gate.verify(inventory, self.review(inventory), self.root)
        self.assertEqual(result['inventorySha256'], gate.identity(inventory))
        with self.assertRaisesRegex(ValueError, 'No unique reviewed'):
            gate.verify(inventory, json.loads((ROOT / 'assets/distribution-review.json').read_text()))

    def test_added_missing_or_changed_shipped_assets_invalidate_review(self):
        original = self.capture()
        review = self.review(original)
        for transition in ('changed', 'missing', 'added'):
            with self.subTest(transition=transition):
                wallpaper = self.payload / 'wallpaper.png'
                wallpaper.write_bytes(b'fixture original art')
                if transition == 'changed':
                    wallpaper.write_bytes(b'different art')
                elif transition == 'missing':
                    wallpaper.unlink()
                else:
                    (self.payload / 'unreviewed.svg').write_text('new third-party mark')
                with self.assertRaisesRegex(ValueError, 'No unique reviewed'):
                    gate.verify(self.capture(), review, self.root)

    def test_changed_artifact_or_channel_invalidates_review(self):
        review = self.review(self.capture())
        self.archive.write_bytes(b'replaced archive')
        with self.assertRaisesRegex(ValueError, 'No unique reviewed'):
            gate.verify(self.capture(), review, self.root)
        self.archive.write_bytes(b'fixture archive')
        with self.assertRaisesRegex(ValueError, 'No unique reviewed'):
            gate.verify(self.capture('web'), review, self.root)

    def test_matching_inventory_cannot_hide_unresolved_or_missing_review(self):
        inventory = self.capture()
        for failure in ('coverage', 'license', 'trademark', 'decision', 'reviewer', 'timestamp', 'evidence', 'duplicate'):
            with self.subTest(failure=failure):
                review = self.review(inventory)
                entry = review['reviews'][0]
                component = entry['components'][0]
                if failure == 'coverage':
                    component['items'].remove('file:wallpaper.png')
                elif failure == 'license':
                    component['license'] = 'NOASSERTION'
                elif failure == 'trademark':
                    component['trademarks'] = 'unverified'
                elif failure == 'decision':
                    component['decision'] = 'unresolved'
                elif failure == 'reviewer':
                    entry['reviewedBy'] = ''
                elif failure == 'timestamp':
                    entry['reviewedAt'] = '2026-10-21'
                elif failure == 'evidence':
                    component['evidence']['sha256'] = '0' * 64
                else:
                    entry['components'].append(copy.deepcopy(component))
                with self.assertRaises(ValueError):
                    gate.verify(inventory, review, self.root)

    def test_compact_review_groups_bind_exact_inventory_and_require_full_coverage(self):
        inventory = self.capture()
        review = self.review(inventory)
        component = review['reviews'][0]['components'][0]
        component['items'] = {'prefixes': ['file:', 'artifact:']}
        gate.verify(inventory, review, self.root)
        component['items']['excludePrefixes'] = ['file:wallpaper']
        with self.assertRaisesRegex(ValueError, 'Unreviewed shipped'):
            gate.verify(inventory, review, self.root)

    def test_changed_evidence_invalidates_review(self):
        inventory = self.capture()
        review = self.review(inventory)
        self.evidence.write_text('changed owner decision')
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            gate.verify(inventory, review, self.root)

    def test_artifact_symlink_is_rejected_and_payload_link_is_bound(self):
        self.archive.unlink()
        self.archive.symlink_to(self.evidence)
        with self.assertRaisesRegex(ValueError, 'regular file'):
            self.capture()
        self.archive.unlink()
        self.archive.write_bytes(b'fixture archive')
        link = self.payload / 'link'
        link.symlink_to('wallpaper.png')
        original = self.capture()
        link.unlink()
        link.symlink_to('/outside/personally-owned.png')
        with self.assertRaisesRegex(ValueError, 'No unique reviewed'):
            gate.verify(self.capture(), self.review(original), self.root)

    def test_rpm_capture_requires_exact_payload_and_artifact_identity(self):
        rpm = self.root / 'cybexos-desktop-1.0.x86_64.rpm'
        rpm.write_bytes(b'fixture RPM')
        with patch.object(gate.subprocess, 'check_output', side_effect=[
                '8', '/usr/share/art.png\t' + 'a' * 64 + '\t\t100644\n']):
            record = gate.capture('desktop-rpm', artifacts=[rpm])
        review = self.review(record)
        gate.verify(record, review, self.root)
        with patch.object(gate.subprocess, 'check_output', side_effect=[
                '8', '/usr/share/art.png\t' + 'b' * 64 + '\t\t100644\n']):
            changed = gate.capture('desktop-rpm', artifacts=[rpm])
        with self.assertRaisesRegex(ValueError, 'No unique reviewed'):
            gate.verify(changed, review, self.root)
        with self.assertRaisesRegex(ValueError, 'channel-specific RPM'):
            gate.capture('offline-rpm', artifacts=[rpm])

    def iso_fixture(self):
        from sbom import build_document
        import hashlib
        iso = b'fixture ISO'
        checksum = hashlib.sha256(iso).hexdigest()
        facts = self.payload / 'source-build-provenance.json'
        facts.write_text('[]\n')
        document = build_document(rpms=[], flatpaks=[], pins=[],
                                  provenance={'source_revision': 'a' * 40, 'build_id': 'fixture',
                                              'utc': '2026-10-21T12:00:00Z'}, version='1.0.0',
                                  iso=('live.iso', checksum), source_build_provenance_sha256=gate.digest(facts))
        sbom = self.payload / 'live.spdx.json'
        sbom.write_text(json.dumps(document))
        (self.payload / 'live.iso.sha256').write_text(checksum + '  live.iso\n')
        (self.payload / 'live.iso.part-000').write_bytes(iso)
        (self.payload / 'live.iso.parts.json').write_text(json.dumps({
            'format': 1, 'file': 'live.iso', 'sha256': checksum, 'bytes': len(iso),
            'parts': [{'file': 'live.iso.part-000', 'sha256': checksum, 'bytes': len(iso)}]}))
        return sbom

    def test_rpm_header_capture_is_bound_to_later_publication_bytes(self):
        rpm = self.root / 'cybexos-desktop-1.0.x86_64.rpm'
        rpm.write_bytes(b'fixture RPM')
        with patch.object(gate.subprocess, 'check_output', side_effect=[
                '8', '/usr/share/art.png\t' + 'a' * 64 + '\t\t100644\n']):
            inventory = gate.capture('desktop-rpm', artifacts=[rpm])
        gate.revalidate_artifacts(inventory, self.root)
        rpm.write_bytes(b'replaced signed RPM')
        with self.assertRaisesRegex(ValueError, 'Artifact changed after payload capture'):
            gate.revalidate_artifacts(inventory, self.root)

    def test_iso_needs_current_raw_inventories_not_historic_audit(self):
        sbom = self.iso_fixture()
        with self.assertRaisesRegex(ValueError, 'actual build evidence'):
            gate.capture('iso', root=self.payload, sbom=sbom)
        for name in ('rpm-inventory.tsv', 'flatpak-inventory.tsv', 'package-manifest.json', 'build-provenance.json'):
            (self.payload / name).write_text('fixture')
        inventory = gate.capture('iso', root=self.payload, sbom=sbom)
        self.assertIn('package:SPDXRef-CybexOS', inventory['items'])
        review = self.review(inventory)
        (self.payload / 'rpm-inventory.tsv').write_text('different actual package version')
        with self.assertRaisesRegex(ValueError, 'No unique reviewed'):
            gate.verify(gate.capture('iso', root=self.payload, sbom=sbom), review, self.root)
        (self.payload / 'live.iso.part-000').write_bytes(b'changed ISO bytes')
        with self.assertRaisesRegex(ValueError, 'changed ISO part'):
            gate.capture('iso', root=self.payload, sbom=sbom)

    def test_iso_rejects_unbound_or_changed_toolchain_evidence(self):
        sbom = self.iso_fixture()
        for name in ('rpm-inventory.tsv', 'flatpak-inventory.tsv', 'package-manifest.json', 'build-provenance.json'):
            (self.payload / name).write_text('fixture')
        (self.payload / 'source-build-provenance.json').write_text('["different compiler"]')
        with self.assertRaisesRegex(ValueError, 'toolchain evidence is not bound'):
            gate.capture('iso', root=self.payload, sbom=sbom)

    def test_internal_capture_stays_available_when_publication_is_blocked(self):
        output = self.root / 'inventory.json'
        args = [sys.executable, '-B', str(ROOT / 'image/distribution_review.py'),
                '--channel', 'web', '--root', str(self.payload), '--output', str(output)]
        capture = subprocess.run([*args[:3], 'capture', *args[3:]], text=True, capture_output=True)
        self.assertEqual(capture.returncode, 0, capture.stderr)
        public = subprocess.run([*args[:3], 'check-public', *args[3:]], text=True, capture_output=True)
        self.assertEqual(public.returncode, 1)
        self.assertIn('No unique reviewed', public.stderr)
        self.assertTrue(output.is_file())

    def test_real_publication_shell_stops_before_receipts_when_review_is_unresolved(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/release.yml').read_text())
        step = next(step for step in workflow['jobs']['publish']['steps']
                    if step.get('name') == 'Require reviewed PUBLIC distribution for every channel')
        work = self.root / 'workflow'
        (work / 'dist/distribution-inventories').mkdir(parents=True)
        (work / 'assets').mkdir()
        (work / 'image').symlink_to(ROOT / 'image', target_is_directory=True)
        (work / 'assets/distribution-review.json').write_text(
            (ROOT / 'assets/distribution-review.json').read_text())
        inventory = self.capture()
        (work / 'dist/distribution-inventories/source-distribution-inventory.json').write_text(json.dumps(inventory))
        sums = work / 'dist/SHA256SUMS'
        sums.write_text('untouched before approval\n')
        result = subprocess.run(['bash', '-c', step['run']], cwd=work,
                                env={**os.environ, 'PUBLIC_REVIEW': ''}, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('No unique reviewed source inventory', result.stderr)
        self.assertFalse((work / 'dist/distribution-review.json').exists())
        self.assertEqual(sums.read_text(), 'untouched before approval\n')

    def test_original_generator_is_reproducible_without_external_assets(self):
        spec = importlib.util.spec_from_file_location('wallpapers', ROOT / 'scripts/generate-wallpapers.py')
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        first = generator.render('moon-mountains', 320)
        self.assertEqual(first, generator.render('moon-mountains', 320))
        self.assertNotEqual(first, generator.render('quiet-fjord', 320))
        self.assertTrue(first.startswith(b'\x89PNG\r\n\x1a\n'))


if __name__ == '__main__':
    unittest.main()
