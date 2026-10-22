#!/usr/bin/env python3
"""Image module artifact admission/parity; native provider tests run via CTest."""
import importlib.util
import json
from pathlib import Path
import runpy
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'image'))
SPEC = importlib.util.find_spec('notification_images')
PAYLOAD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PAYLOAD)
BUILD = runpy.run_path(str(ROOT / PAYLOAD.RECIPE / 'build.py'))


class ImageArtifactContracts(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='nerdos-notification-images-test-')
        self.addCleanup(temporary.cleanup)
        self.build = Path(temporary.name)
        self.staged = self.build / 'notification-images-root'
        self.payload = self.build / 'payload'
        PAYLOAD.prepare_recipe(ROOT, self.staged)
        for name in PAYLOAD.ARTIFACTS:
            path = self.staged / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture artifact, not a native binary')
        self.manifest = {'v': 1, 'inputs': {'source_sha256': {
            name: PAYLOAD.sha256(ROOT / PAYLOAD.RECIPE / name) for name in PAYLOAD.SOURCES}},
            'artifacts': {name: PAYLOAD.sha256(self.staged / name) for name in PAYLOAD.ARTIFACTS}}
        self.write_manifest()

    def write_manifest(self):
        content = json.dumps(self.manifest)
        (self.staged / PAYLOAD.MANIFEST).write_text(content)
        (self.build / 'notification-images.json').write_text(content)

    def test_source_and_image_use_identical_recipe_contract(self):
        for name in ('SOURCES', 'ARTIFACTS', 'MANIFEST'):
            self.assertEqual(BUILD[name], getattr(PAYLOAD, name))
        PAYLOAD.prepare_notification_images(ROOT, self.build, self.payload)
        for name in PAYLOAD.ARTIFACTS:
            self.assertEqual((self.staged / name).read_bytes(), (self.payload / name).read_bytes())
        for name in PAYLOAD.SOURCES:
            self.assertEqual(PAYLOAD.sha256(ROOT / PAYLOAD.RECIPE / name),
                             PAYLOAD.sha256(self.payload / 'usr/share/nerdos/notification-images' / name))

    def test_changed_source_manifest_is_rejected(self):
        self.manifest['inputs']['source_sha256']['imagefingerprints.cpp'] = '0' * 64
        self.write_manifest()
        with self.assertRaisesRegex(RuntimeError, 'source revision'):
            PAYLOAD.prepare_notification_images(ROOT, self.build, self.payload)

    def test_changed_staged_recipe_is_rejected(self):
        (self.staged / 'usr/share/nerdos/notification-images/plugin.cpp').write_text('changed')
        with self.assertRaisesRegex(RuntimeError, 'recipe differs'):
            PAYLOAD.prepare_notification_images(ROOT, self.build, self.payload)

    def test_changed_or_missing_artifact_is_rejected(self):
        binary = self.staged / PAYLOAD.ARTIFACTS[0]
        binary.write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'artifact differs'):
            PAYLOAD.prepare_notification_images(ROOT, self.build, self.payload)
        binary.unlink()
        with self.assertRaises(FileNotFoundError):
            PAYLOAD.prepare_notification_images(ROOT, self.build, self.payload)

    def test_extra_artifacts_or_inconsistent_manifests_are_rejected(self):
        self.manifest['artifacts']['../../unexpected'] = '0' * 64
        self.write_manifest()
        with self.assertRaisesRegex(RuntimeError, 'source revision'):
            PAYLOAD.prepare_notification_images(ROOT, self.build, self.payload)
        del self.manifest['artifacts']['../../unexpected']
        self.write_manifest()
        (self.build / 'notification-images.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError, 'source revision'):
            PAYLOAD.prepare_notification_images(ROOT, self.build, self.payload)


if __name__ == '__main__':
    unittest.main()
