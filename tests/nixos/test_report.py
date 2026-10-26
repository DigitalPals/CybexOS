#!/usr/bin/env python3
"""cybex report: native read-only diagnostics, archive privacy and redaction.

Every system tool the report runs is a stub in PATH whose output carries the
kinds of private values real journals and hardware listings contain. Nothing
here reads the host's journal, opens a browser, or uploads anything.
"""
import getpass
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import stat
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
import urllib.parse

from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'assets/scripts/cybexos-report'
loader = importlib.machinery.SourceFileLoader('cybexos_report', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
report = importlib.util.module_from_spec(spec)
loader.exec_module(report)

USER = getpass.getuser()
# Nix sandboxes use the deliberately public hostname "localhost". Exercise a
# private hostname deterministically while retaining the generic-hostname test.
HOST = 'fixture-private-host'

# Values that must never survive into a bundle or the issue URL.
SECRETS = {
    'ghp_0123456789abcdefghijABCDEFGHIJ0123456789', 'github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuv',
    'sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345', 'sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456',
    'AKIAIOSFODNN7EXAMPLE', 'AIzaSyA1234567890abcdefghijklmnopqrstuv', 'xoxb-1234567890-abcdefghij',
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
    'hunter2secret', 'S3cr3tSessionCookie', 'bearertokenvalue123', 'urlpassword', 'querytokenvalue',
    'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC',
    'jane.doe@example.com', 'a4:5e:60:c1:22:9f', 'A4-5E-60-C1-22-9F', '192.168.1.23', '84.22.101.7',
    '10.0.0.0/8', 'fe80::1c2d:3eff:fe4f:5a6b', '2001:db8:85a3::8a2e:370:7334',
    'PF3XK2LM', '7YK3CK3', 'SVT02B6Q99', '0123ABCD4567', 'c0ffee00-1234-5678-9abc-def012345678',
    '0f1e2d3c4b5a69788796a5b4c3d2e1f0', 'HomeNet-5G', 'CoffeeShop Guest',
    f'/home/{USER}', 'Johnathan Example', 'Neighbours WiFi', 'OtherNet',
}
# Values that carry no personal data and must stay readable.
KEPT = ('127.0.0.1', '::1', '7.3.0', '22:09:11', 'NixOS 26.05', '1.2.3.400',
        'Kernel driver in use: nvidia', 'NVIDIA Corporation AD102', 'user@1000.service',
        'max_tokens=4096', 'serial8250', '0000:01:00.0')

FIXTURE_LOG = textwrap.dedent(f'''\
    2026-10-13T22:09:11+0200 {HOST} quickshell[2211]: QML error at /home/{USER}/.config/cybexos/shell.json:12
    token=ghp_0123456789abcdefghijABCDEFGHIJ0123456789 and github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuv
    ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345 OPENAI sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456
    aws AKIAIOSFODNN7EXAMPLE google AIzaSyA1234567890abcdefghijklmnopqrstuv slack xoxb-1234567890-abcdefghij
    jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
    password=hunter2secret "session_id": "S3cr3tSessionCookie" Authorization: Bearer bearertokenvalue123
    fetch https://alice:urlpassword@git.example.org/repo.git?access_token=querytokenvalue&page=2
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC
    -----END PRIVATE KEY-----
    commit by Johnathan Example <jane.doe@example.com>
    wlp0s20f3: link a4:5e:60:c1:22:9f, bridge A4-5E-60-C1-22-9F
    DHCP 192.168.1.23 via 84.22.101.7 route 10.0.0.0/8 local 127.0.0.1 any 0.0.0.0
    inet6 fe80::1c2d:3eff:fe4f:5a6b%wlp0s20f3 global 2001:db8:85a3::8a2e:370:7334 lo ::1
    usb 1-2: SerialNumber: 0123ABCD4567 iSerial 3 SVT02B6Q99
    Monitor DP-1: serial: PF3XK2LM description: Dell Inc. DELL U2723QE 7YK3CK3
    filesystem UUID=c0ffee00-1234-5678-9abc-def012345678 machine 0f1e2d3c4b5a69788796a5b4c3d2e1f0
    NetworkManager: Config: added 'ssid' value 'HomeNet-5G'; roaming to CoffeeShop Guest
    wpa_supplicant: Trying to associate with SSID 'Neighbours WiFi' ssid="OtherNet"
    kernel 7.3.0 NixOS 26.05 libfoo 1.2.3.400 at 22:09:11
    Kernel driver in use: nvidia NVIDIA Corporation AD102 user@1000.service max_tokens=4096
    serial8250 0000:01:00.0 /var/home/{USER}/Downloads
''')

STUBS = {
    'cybex': f'''
        case $1 in
          update) printf '%s\\n' '{{"state":"awaiting-boot"}}' ;;
          version) echo '1.0.0-beta.1' ;;
          shell) printf '%s\\n' '{{"safe":false,"path":"/home/{USER}/.local/state/cybexos/shell.json"}}' ;;
          report) exec "$CYBEXOS_REPORT" "${{@:2}}" ;;
        esac
    ''',
    'journalctl': '''
        for unit in cybexos-update@0123456789abcdef0123456789abcdef.service cybexos-software@0123456789abcdef0123456789abcdef.service \\
                    cybexos-maintenance-policy@0123456789abcdef0123456789abcdef.service cybexos-maintenance@0123456789abcdef0123456789abcdef.service \\
                    cybexos-recover.service cybexos-region.service; do
          for pattern in "$@"; do
            if [[ $unit == $pattern ]]; then
              printf 'LIFECYCLE_UNIT:%s\\n' "$unit"
              break
            fi
          done
        done
        cat "$FIXTURE/log"
    ''',
    'systemctl': 'case " $* " in *" is-system-running "*) echo running;; *" is-active "*) echo active;; *) echo "bad-$USER.service loaded failed failed Something on $(cat "$FIXTURE/host")";; esac',
    'nix': 'echo "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-fixture"',
    'lspci': textwrap.dedent('''\
        printf '%s\\n' '00:02.0 VGA compatible controller [0300]: Intel Corporation Device [8086:7d55]' \\
          $'\\tKernel driver in use: xe' \\
          '01:00.0 3D controller [0302]: NVIDIA Corporation AD102 [10de:2684]' $'\\tKernel driver in use: nvidia' '''),
    'lsusb': 'cat "$FIXTURE/log"',
    'lsblk': 'echo "nvme0n1 1.8T disk"',
    'hyprctl': textwrap.dedent('''\
        if [[ $* == '-j configerrors' ]]; then
          echo '[]'
        elif [[ $* == 'monitors all -j' ]]; then
          echo '[{"name":"DP-1","serial":"7YK3CK3","description":"Dell Inc. DELL U2723QE 7YK3CK3"}]'
        else
          cat "$FIXTURE/log"
        fi'''),
    'bootctl': 'echo "Secure Boot: enabled"',
    'nmcli': textwrap.dedent('''\
        case "$*" in
          '-t -f NAME,TYPE connection show') printf '%s\\n' 'Wired connection 1:802-3-ethernet' \\
             'CoffeeShop Guest:802-11-wireless' 'Home\\:Net:802-11-wireless' ;;
          *'CoffeeShop Guest') echo 'CoffeeShop Guest' ;;
          *) echo 'HomeNet-5G' ;;
        esac'''),
    'qs': 'echo "quickshell 0.2.0"',
    'xdg-open': 'printf "%s\\n" "$1" >"$FIXTURE/opened"',
}


class RedactorFixtures(unittest.TestCase):
    def redactor(self):
        return report.Redactor(users={USER}, names={'Johnathan Example', 'Johnathan', 'Example'},
                               hosts={HOST, 'nixos'}, homes={f'/home/{USER}', f'/var/home/{USER}'},
                               ssids={'HomeNet-5G', 'CoffeeShop Guest'},
                               machine_ids={'0f1e2d3c4b5a69788796a5b4c3d2e1f0'}, serials={'7YK3CK3'})

    def test_every_private_kind_is_removed_and_counted(self):
        redact = self.redactor()
        text = redact(FIXTURE_LOG)
        for secret in SECRETS:
            self.assertNotIn(secret, text, secret)
        for value in KEPT:
            self.assertIn(value, text, value)
        self.assertIn('/home/[user]/.config/cybexos/shell.json', text)
        self.assertIn('/home/[user]/Downloads', text)
        for kind in ('token', 'key', 'email', 'mac', 'ipv4', 'ipv6', 'serial', 'ssid', 'home', 'host', 'user'):
            self.assertGreater(redact.counts.get(kind, 0), 0, kind)

    def test_placeholders_are_stable_when_a_username_is_a_common_word(self):
        redact = report.Redactor(users={'user'}, homes={'/home/user'})
        self.assertEqual(redact('/home/user/x user@1000.service the user said'),
                         '/home/[user]/x [user]@1000.service the [user] said')
        self.assertEqual(redact(redact('/home/user/x')), '/home/[user]/x')

    def test_generic_hostnames_and_short_values_are_not_treated_as_private(self):
        redact = report.Redactor(hosts={'nixos', 'localhost', 'ab'}, users={'jo'})
        self.assertEqual(redact('NixOS nixos localhost ab jo'), 'NixOS nixos localhost ab jo')

    def test_timestamps_versions_and_pci_addresses_are_not_addresses(self):
        redact = report.Redactor()
        for text in ('2026-10-13 22:09:11', '12:34:56.789', 'std::string::npos', 'qrc:/Foo.qml:12:5',
                     'version 1.2.3.4.5', 'nvidia 615.78.08', '0000:00:02.0', 'fe80 is a prefix'):
            self.assertEqual(redact(text), text)
        self.assertEqual(redact('gateway 192.168.0.1:53'), 'gateway [ipv4]:53')


FIXTURE_ENTRY = """
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader('fixture_report', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
report = importlib.util.module_from_spec(spec)
loader.exec_module(report)
report.socket.gethostname = lambda: 'fixture-private-host'
original_read = report.read
report.read = lambda path, limit=None: json.dumps({'schema': 1, 'units': ['NetworkManager.service'], 'userUnits': []}) if str(path) == '/etc/cybexos/health-services.json' else original_read(path, limit)
sys.exit(report.main(sys.argv[2:]))
"""


class Fixture:
    def __init__(self, directory):
        self.base = Path(directory)
        self.home = self.base / 'home'
        self.bin = self.base / 'bin'
        self.fixture = self.base / 'fixture'
        for path in (self.home / 'Downloads', self.bin, self.fixture):
            path.mkdir(parents=True)
        (self.fixture / 'log').write_text(FIXTURE_LOG)
        (self.fixture / 'host').write_text(HOST)
        for name, body in STUBS.items():
            script = self.bin / name
            script.write_text('#!' + shutil.which('bash') + '\n' + textwrap.dedent(body))
            script.chmod(0o755)

    def environment(self):
        return {'PATH': f"{self.bin}:{os.environ['PATH']}", 'HOME': str(self.home), 'USER': USER,
                'FIXTURE': str(self.fixture), 'CYBEXOS_REPORT': str(HELPER), 'PYTHONDONTWRITEBYTECODE': '1',
                'XDG_STATE_HOME': str(self.home / '.local/state')}

    def run(self, *argv, command=None):
        return subprocess.run(command or [sys.executable, '-c', FIXTURE_ENTRY, str(HELPER), *argv], env=self.environment(), text=True,
                              capture_output=True, timeout=120, stdin=subprocess.DEVNULL)


def members(path):
    with tarfile.open(path) as archive:
        return {member.name.split('/', 1)[1]: archive.extractfile(member).read().decode()
                for member in archive.getmembers() if member.isfile()}


class Bundle(unittest.TestCase):
    def test_json_bundle_is_complete_redacted_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            result = fixture.run('--json', '--output', str(fixture.base))
            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(result.stdout)
            path = Path(output['path'])
            self.assertRegex(path.name, r'^cybexos-report-\d{8}-\d{6}\.tar\.gz$')
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            content = members(path)
            self.assertEqual(set(content), {
                'README.txt', 'summary.json', 'health.json', 'versions.txt', 'hardware.txt', 'shell-health.json',
                'failed-units.txt', 'journal/hyprland.txt', 'journal/quickshell.txt', 'journal/sddm.txt',
                'journal/update-worker.txt', 'journal/hardware-setup.txt'})
            everything = '\n'.join(content.values()) + output['issueUrl'] + json.dumps(output['summary'])
            # The fixture's full name and machine id are not this machine's;
            # RedactorFixtures covers them with explicit identities.
            for secret in (SECRETS - {'Johnathan Example', '0f1e2d3c4b5a69788796a5b4c3d2e1f0'}) \
                    | {HOST, str(fixture.home)}:
                self.assertNotIn(secret, everything, secret)
                self.assertNotIn(urllib.parse.quote(secret), output['issueUrl'], secret)
            summary = json.loads(content['summary.json'])
            self.assertEqual(summary['health'], 'warning')
            self.assertEqual(summary['attention'], ['deployment'])
            self.assertEqual(summary['cybexos'], '1.0.0-beta.1')
            self.assertIn('NVIDIA Corporation AD102 [10de:2684] (nvidia)', summary['gpus'])
            self.assertGreater(summary['redactions']['token'], 0)
            json.loads(content['health.json'])
            self.assertIn('/home/[user]', content['shell-health.json'])
            for unit in ('cybexos-update@0123456789abcdef0123456789abcdef.service', 'cybexos-software@0123456789abcdef0123456789abcdef.service',
                         'cybexos-maintenance-policy@0123456789abcdef0123456789abcdef.service', 'cybexos-maintenance@0123456789abcdef0123456789abcdef.service',
                         'cybexos-recover.service', 'cybexos-region.service'):
                self.assertIn('LIFECYCLE_UNIT:' + unit, content['journal/update-worker.txt'])
            self.assertFalse((fixture.fixture / 'opened').exists(), '--json never opens a browser')

    def test_issue_url_prefills_the_bug_form_with_a_short_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            output = json.loads(fixture.run('--json', '--output', str(fixture.base)).stdout)
            url = urllib.parse.urlsplit(output['issueUrl'])
            self.assertEqual(f'{url.scheme}://{url.netloc}{url.path}',
                             'https://github.com/DigitalPals/CybexOS/issues/new')
            query = urllib.parse.parse_qs(url.query)
            self.assertEqual(query['template'], ['bug_report.yml'])
            environment = query['environment'][0]
            self.assertIn('- Cybex OS: 1.0.0-beta.1', environment)
            self.assertIn(Path(output['path']).name, environment)
            self.assertLess(len(output['issueUrl']), 2000, 'the body stays short; logs go in the archive')
            form = (ROOT / '.github/ISSUE_TEMPLATE/bug_report.yml').read_text()
            for field in query:
                if field not in ('template', 'labels'):
                    self.assertIn(f'id: {field}\n', form, f'{field} must be a field of the bug form')

    def test_no_browser_and_non_interactive_runs_never_open_the_browser(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            for arguments in (('--no-browser',), ()):
                result = fixture.run('--output', str(fixture.base), *arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('nothing has been uploaded', result.stdout)
                self.assertIn('Redacted:', result.stdout)
            self.assertFalse((fixture.fixture / 'opened').exists())

    def test_default_location_is_the_download_folder_and_zstd_is_optional(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            output = json.loads(fixture.run('--json').stdout)
            self.assertEqual(Path(output['path']).parent, fixture.home / 'Downloads')
            zst = fixture.base / 'bundle.tar.zst'
            result = fixture.run('--json', '--output', str(zst))
            if result.returncode == 0:
                listing = subprocess.run(['tar', '--zstd', '-tf', str(zst)], text=True, capture_output=True)
                if listing.returncode == 0:
                    self.assertIn('bundle/summary.json', listing.stdout)
            else:
                self.assertIn('zstd', result.stderr)
            bad = fixture.run('--json', '--output', str(fixture.base / 'bundle.txt'))
            self.assertNotEqual(bad.returncode, 0)



class NativeDiagnostics(unittest.TestCase):
    def probe(self, replies=None, declaration=None):
        self.calls = []
        default = {'schema': 1, 'units': ['NetworkManager.service'], 'userUnits': ['personal.service']}
        values = {
            ('systemctl', 'is-system-running'): (0, 'running'),
            ('systemctl', 'is-active', 'NetworkManager.service'): (0, 'active'),
            ('systemctl', '--user', 'is-active', 'personal.service'): (0, 'active'),
            ('cybex', 'update', 'status'): (0, '{"state":"done"}'),
            ('hyprctl', '-j', 'configerrors'): (0, '["", " "]'),
            ('cybex', 'shell', 'status'): (0, '{"safe":false}'),
            ('systemctl', '--user', 'is-active', 'quickshell.service'): (0, 'active'),
        }
        values.update(replies or {})
        def run(command):
            self.calls.append(tuple(command))
            return values[tuple(command)]
        with patch.object(report, 'tool', side_effect=lambda name: name), \
             patch.object(report, 'read', return_value=json.dumps(default if declaration is None else declaration)), \
             patch.object(report, 'run', side_effect=run):
            return report.diagnostics()

    def test_read_only_health_includes_declared_personal_services(self):
        result = self.probe()
        self.assertEqual(result['overall'], 'ok')
        self.assertIn(('systemctl', '--user', 'is-active', 'personal.service'), self.calls)
        self.assertNotIn('doctor', str(self.calls))
        self.assertFalse(any(action in {'start', 'stop', 'restart', 'confirm', 'apply'} for call in self.calls for action in call))

    def test_failed_service_pending_deployment_and_safe_shell_are_actionable(self):
        result = self.probe({
            ('systemctl', 'is-active', 'NetworkManager.service'): (3, 'failed'),
            ('cybex', 'update', 'status'): (0, '{"state":"awaiting-boot"}'),
            ('cybex', 'shell', 'status'): (0, '{"safe":true,"reason":"Repeated crashes"}'),
        })
        warnings = {check['name']: check['detail'] for check in result['checks'] if check['state'] == 'warning'}
        self.assertEqual(result['overall'], 'warning')
        self.assertEqual(set(warnings), {'NetworkManager.service', 'deployment', 'shell'})
        self.assertIn('awaiting-boot', warnings['deployment'])
        self.assertIn('Repeated crashes', warnings['shell'])

    def test_unavailable_and_malformed_responses_never_mean_healthy(self):
        for command in [('cybex', 'update', 'status'), ('hyprctl', '-j', 'configerrors'), ('cybex', 'shell', 'status'),
                        ('systemctl', '--user', 'is-active', 'quickshell.service')]:
            with self.subTest(command=command):
                self.assertEqual(self.probe({command: (127, 'not installed')})['overall'], 'warning')
                self.assertEqual(self.probe({command: (0, '{}')})['overall'], 'warning')

    def test_invalid_service_declarations_are_never_interpreted_as_options(self):
        for declaration in ({}, {'schema':1, 'units':[], 'userUnits':[]},
                            {'schema':1, 'units':['--all'], 'userUnits':[]}):
            with self.subTest(declaration=declaration):
                self.assertEqual(self.probe(declaration=declaration)['overall'], 'warning')
                self.assertFalse(any('--all' in command for command in self.calls))


if __name__ == '__main__':
    unittest.main()
