"""Fixture checks for the installed doctor; no live services or capture devices."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).parent / 'rootfs/usr/libexec/cybexos-doctor'
loader = importlib.machinery.SourceFileLoader('cybexos_doctor', str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)


class DoctorTests(unittest.TestCase):
    def fixture(self, root, home):
        def write(path, value):
            target = root / path.lstrip('/')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(value))
        write('/usr/share/cybexos/build.json', {'source_revision': 'a' * 40})
        write('/etc/cybexos/hardware.json', {'xps_2026': True})
        write('/var/lib/cybexos/hardware-status.json', {'state': 'pending', 'reason': 'reboot required for camera validation'})
        for path in ('/etc/grub.d/42_cybexos_recovery',
                     '/usr/lib/systemd/system/cybexos-recovery-refresh.service'):
            target = root / path.lstrip('/')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.touch()
        state = home / '.local/state/cybexos'
        state.mkdir(parents=True)
        (state / 'seed-progress.json').write_text('{"state":"copying"}')

    def command(self, *argv):
        if argv[0] == 'rpm':
            return 0, 'cybexos-desktop-1.0'
        if argv[0].endswith('cybexos-update-channel'):
            return 0, '{"status":"desktop-channel-disabled"}'
        if argv[0].endswith('cybexos-reconcile'):
            return 0, '{"state":"ready"}'
        if argv[:3] == ('systemctl', '--user', 'is-active'):
            return 0, 'active'
        if argv[:2] == ('systemctl', 'is-active'):
            return 0, 'active'
        if argv[:2] == ('systemctl', 'is-enabled'):
            return 0, 'enabled'
        if argv[0] == 'nmcli':
            return 0, 'connected'
        return 0, ''

    def test_pending_reboot_and_seed_are_explicit_warnings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'root'
            home = Path(temporary) / 'home'
            self.fixture(root, home)
            result = doctor.collect(root, home, self.command)
            checks = {entry['name']: entry for entry in result['checks']}
            self.assertEqual(result['overall'], 'warning')
            self.assertEqual(checks['hardware']['state'], 'pending')
            self.assertIn('Reboot', checks['hardware']['action'])
            self.assertEqual(checks['seeded_apps']['state'], 'pending')
            self.assertEqual(checks['desktop_channel']['state'], 'warning')

    def test_malformed_helper_json_is_reported_and_retry_uses_installed_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, home = Path(temporary) / 'root', Path(temporary) / 'home'
            self.fixture(root, home)
            def command(*argv):
                if argv[0].endswith('cybexos-update-channel'):
                    return 0, '[]'
                if argv[0].endswith('cybexos-reconcile'):
                    return 0, '{"state":"blocked"}'
                return self.command(*argv)
            checks = {entry['name']: entry for entry in doctor.collect(root, home, command)['checks']}
            self.assertEqual(checks['desktop_channel']['state'], 'fail')
            self.assertIn('/usr/libexec/cybexos-reconcile --retry', checks['reconciliation']['action'])
            def malformed(*argv):
                if argv[0].endswith('cybexos-reconcile'):
                    return 0, '[]'
                return self.command(*argv)
            checks = {entry['name']: entry for entry in doctor.collect(root, home, malformed)['checks']}
            self.assertEqual(checks['reconciliation']['state'], 'warning')

    def test_missing_package_failure_and_qml_error_are_reported_without_journal_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'root'
            home = Path(temporary) / 'home'
            self.fixture(root, home)
            secret = 'private-widget-value'
            def command(*argv):
                if argv[0] == 'rpm':
                    return 1, ''
                if argv[0] == 'journalctl':
                    return 0, 'QML error ' + secret
                if argv[:2] == ('systemctl', '--failed'):
                    return 0, 'bad.service loaded failed failed'
                return self.command(*argv)
            result = doctor.collect(root, home, command)
            checks = {entry['name']: entry for entry in result['checks']}
            self.assertEqual(result['overall'], 'fail')
            self.assertEqual(checks['build']['state'], 'fail')
            self.assertEqual(checks['failed_units']['state'], 'fail')
            self.assertEqual(checks['qml']['state'], 'warning')
            self.assertNotIn(secret, json.dumps(result))


if __name__ == '__main__':
    unittest.main()
