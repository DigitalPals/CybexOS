"""Source-only safety checks for the real-browser VM qualification path."""
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

import browser_qualification as browser
import qualification
import upgrade_qualification as upgrade
from vm_testing import QUALIFICATION_DISK_SERIAL, QUALIFICATION_UNUSED_SERIAL, TestVM


class BrowserTransportTests(unittest.TestCase):
    def test_only_exact_guest_loopback_installer_url_is_accepted(self):
        self.assertEqual(browser.validate_guest_url(
            'http://127.0.0.1:8080/cockpit/@localhost/cybexos-installer/index.html'), 8080)
        self.assertEqual(browser.validate_guest_url(
            'http://localhost/cockpit/@localhost/cybexos-installer/index.html'), 80)
        # Anaconda passes its original URL to the wrapper, which redirects the
        # actual browser to the CybexOS page. Both use the same loopback port.
        self.assertEqual(browser.validate_guest_url(
            'http://127.0.0.1/cockpit/@localhost/anaconda-webui/index.html'), 80)
        for value in ('http://example.com/cockpit/@localhost/cybexos-installer/index.html',
                      'http://127.0.0.1@evil.invalid/cockpit/@localhost/cybexos-installer/index.html',
                      'https://127.0.0.1/cockpit/@localhost/cybexos-installer/index.html',
                      'http://127.0.0.1/cockpit/@localhost/cybexos-installer/index.html?x=1'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                browser.validate_guest_url(value)

    def test_guest_disk_names_must_match_both_fixed_serials(self):
        vm = types.SimpleNamespace(ssh=['ssh', 'guest'])
        valid = f'vda {QUALIFICATION_DISK_SERIAL}\nvdb {QUALIFICATION_UNUSED_SERIAL}\n'
        for listing, expected in ((valid, ('vda', 'vdb')),
                                  (valid.replace(QUALIFICATION_UNUSED_SERIAL, 'OTHER'), None),
                                  (valid + f'vdc {QUALIFICATION_DISK_SERIAL}\n', None)):
            with patch.object(qualification, 'run', return_value=types.SimpleNamespace(stdout=listing)):
                if expected is None:
                    with self.assertRaises(RuntimeError):
                        qualification.qualification_disks(vm)
                else:
                    self.assertEqual(qualification.qualification_disks(vm), expected)

    def test_qualification_attaches_guard_only_when_requested(self):
        with tempfile.TemporaryDirectory() as directory:
            ordinary = TestVM(Path(directory) / 'ordinary')
            guarded = TestVM(Path(directory) / 'guarded', guard_disk=True)
            self.assertFalse(ordinary.guard_disk)
            self.assertTrue(guarded.guard_disk)
            self.assertNotEqual(guarded.disk, guarded.unused_disk)


class UpgradeTests(unittest.TestCase):
    def test_user_preference_fixture_is_valid_guest_python(self):
        captured = []
        def root_script(vm, script, password):
            captured.append(script)
            return types.SimpleNamespace(stdout='bottom\n')
        self.assertEqual(upgrade.prepare_user_choices(None, 'fixture-password', root_script), 'bottom')
        guest = captured[0].split("python3 - <<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        compile(guest, '<guest-preference-fixture>', 'exec')

    def test_upgrade_rejects_same_or_older_rpm_before_dnf(self):
        vm = types.SimpleNamespace()
        for comparison in (0, -1):
            with patch.object(upgrade, 'copy_candidate', return_value='a' * 64), \
                 patch.object(upgrade, 'inspect_version', return_value={'comparison': comparison}), \
                 patch.object(upgrade, 'run') as command:
                with self.assertRaises(RuntimeError):
                    upgrade.upgrade(vm, '/fixture.rpm', 'fixture-password', lambda *args, **kwargs: None)
                command.assert_not_called()

    def test_candidate_symlink_is_refused_before_guest_transfer(self):
        with tempfile.TemporaryDirectory() as directory:
            real = Path(directory) / 'candidate.rpm'
            real.write_bytes(b'fixture')
            link = Path(directory) / 'link.rpm'
            link.symlink_to(real)
            with self.assertRaises(ValueError):
                upgrade.copy_candidate(types.SimpleNamespace(), link)


if __name__ == '__main__':
    unittest.main()
