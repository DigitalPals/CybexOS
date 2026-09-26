"""Enrollment verifies trust before mutation and retains the previous channel."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader('update_channel', str(Path(__file__).parent / 'rootfs/usr/libexec/cybexos-update-channel'))
spec = importlib.util.spec_from_loader(loader.name, loader)
channel = importlib.util.module_from_spec(spec)
loader.exec_module(channel)
FINGERPRINT = 'A' * 40


class EnrollmentTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.config = self.root / 'public.json'
        self.config.write_text(json.dumps({'baseurl': 'https://digitalpals.github.io/CybexOS/44/x86_64',
                                          'fingerprint': FINGERPRINT, 'key_file': 'public.asc'}))
        (self.root / 'etc').mkdir()
        (self.root / 'etc/os-release').write_text('ID=fedora\nVERSION_ID=44\n')
        self.public = patch.object(channel, 'public_key', return_value=b'public key')
        self.public.start()
        self.addCleanup(self.public.stop)
        self.verify = patch.object(channel, 'verify_repository')
        self.verifier = self.verify.start()
        self.addCleanup(self.verify.stop)

    def test_unenrolled_system_never_claims_desktop_updates_are_ready(self):
        result = channel.status(self.root)
        self.assertEqual(result['status'], 'desktop-channel-disabled')
        self.assertFalse(result['configured'])

    def test_fingerprint_mismatch_never_contacts_server_or_changes_files(self):
        with self.assertRaisesRegex(ValueError, 'fingerprint'):
            channel.enroll(self.config, 'B' * 40, self.root)
        self.verifier.assert_not_called()
        self.assertFalse((self.root / channel.REPO).exists())

    def test_unverified_repository_cannot_enable_channel(self):
        self.verifier.side_effect = ValueError('Bad signature')
        with self.assertRaisesRegex(ValueError, 'Bad signature'):
            channel.enroll(self.config, FINGERPRINT, self.root)
        self.assertFalse((self.root / channel.REPO).exists())

    def test_check_verifies_without_writing_and_enrollment_is_idempotent(self):
        channel.enroll(self.config, FINGERPRINT, self.root, check=True)
        self.verifier.assert_called_once()
        self.assertFalse((self.root / channel.REPO).exists())
        result = channel.enroll(self.config, FINGERPRINT, self.root)
        self.assertEqual(result['status'], 'desktop-channel-ready')
        self.assertIn('gpgcheck=1\nrepo_gpgcheck=1', (self.root / channel.REPO).read_text())
        again = channel.enroll(self.config, FINGERPRINT, self.root)
        self.assertNotIn('backup', again)
        self.assertEqual(len(list((self.root / 'var/lib/cybexos/backups').iterdir())), 1)

    def test_failure_restores_previous_files(self):
        repo = self.root / channel.REPO
        repo.parent.mkdir(parents=True)
        repo.write_text('[cybexos-desktop]\nenabled=0\n')
        real_write = channel.atomic_write

        def fail_repo(path, data):
            if path == repo and b'enabled=1' in data:
                raise OSError('fixture interrupted write')
            real_write(path, data)

        with patch.object(channel, 'atomic_write', side_effect=fail_repo):
            with self.assertRaises(OSError):
                channel.enroll(self.config, FINGERPRINT, self.root)
        self.assertEqual(repo.read_text(), '[cybexos-desktop]\nenabled=0\n')
        self.assertFalse((self.root / channel.KEY).exists())
        self.assertFalse((self.root / channel.CONFIG).exists())

    def test_failure_after_publication_restores_in_flight_destination(self):
        repo = self.root / channel.REPO
        repo.parent.mkdir(parents=True)
        original = b'[cybexos-desktop]\nenabled=0\n'
        repo.write_bytes(original)
        real_write = channel.atomic_write

        def fail_after_rename(path, data):
            real_write(path, data)
            if path == repo and b'enabled=1' in data:
                raise OSError('fixture directory fsync failure')

        with patch.object(channel, 'atomic_write', side_effect=fail_after_rename):
            with self.assertRaises(OSError):
                channel.enroll(self.config, FINGERPRINT, self.root)
        self.assertEqual(repo.read_bytes(), original)
        self.assertFalse((self.root / channel.KEY).exists())
        self.assertFalse((self.root / channel.CONFIG).exists())

    def test_disabled_or_broken_repo_cannot_bypass_existing_key_pin(self):
        record = self.root / channel.CONFIG
        record.parent.mkdir(parents=True)
        record.write_text(json.dumps({'fingerprint': 'B' * 40}))
        repo = self.root / channel.REPO
        repo.parent.mkdir(parents=True)
        for content in ('[cybexos-desktop]\nenabled=0\n',
                        '[cybexos-desktop]\nenabled=1\ngpgcheck=0\n'):
            repo.write_text(content)
            with self.assertRaisesRegex(ValueError, 'rotation'):
                channel.enroll(self.config, FINGERPRINT, self.root)
            self.assertEqual(repo.read_text(), content)
        self.verifier.assert_not_called()

    def test_enabled_but_incomplete_channel_is_visible(self):
        repo = self.root / channel.REPO
        repo.parent.mkdir(parents=True)
        repo.write_text('[cybexos-desktop]\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\n')
        self.assertEqual(channel.status(self.root)['status'], 'desktop-channel-invalid')

    def test_enrollment_rejects_symlink_targets_without_modifying_referent(self):
        repo = self.root / channel.REPO
        repo.parent.mkdir(parents=True)
        protected = self.root / 'protected'
        protected.write_text('preserved')
        repo.symlink_to(protected)
        with self.assertRaisesRegex(ValueError, 'non-regular'):
            channel.enroll(self.config, FINGERPRINT, self.root)
        self.assertEqual(protected.read_text(), 'preserved')


if __name__ == '__main__':
    unittest.main()
