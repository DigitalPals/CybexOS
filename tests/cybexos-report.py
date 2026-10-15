#!/usr/bin/env python3
"""cybex report: redaction fixtures, the archive, and dispatcher parity.

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
import shlex
import socket
import stat
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
import urllib.parse

import jinja2

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'assets/scripts/cybexos-report'
loader = importlib.machinery.SourceFileLoader('cybexos_report', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
report = importlib.util.module_from_spec(spec)
loader.exec_module(report)

USER = getpass.getuser()
HOST = socket.gethostname()

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
KEPT = ('127.0.0.1', '::1', '6.17.4-300.fc44.x86_64', '22:09:11', 'Fedora Linux 44', '1.2.3.400',
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
    kernel 6.17.4-300.fc44.x86_64 Fedora Linux 44 libfoo 1.2.3.400 at 22:09:11
    Kernel driver in use: nvidia NVIDIA Corporation AD102 user@1000.service max_tokens=4096
    serial8250 0000:01:00.0 /var/home/{USER}/Downloads
''')

STUBS = {
    'cybex': f'''
        case $1 in
          doctor) printf '%s\\n' '{{"version":1,"overall":"warning","checks":[{{"name":"hardware","state":"pending",
"detail":"Hardware setup on {HOST}","action":"Restart"}},{{"name":"quickshell","state":"ok","detail":"ok","action":""}}]}}' ;;
          version) echo 'cybexos-desktop-0.4.0-1.fc44.noarch' ;;
          shell) printf '%s\\n' '{{"safe":false,"path":"/home/{USER}/.local/state/cybexos/shell.json"}}' ;;
          report) exec "$CYBEXOS_REPORT" "${{@:2}}" ;;
        esac
    ''',
    'journalctl': 'cat "$FIXTURE/log"',
    'systemctl': 'echo "bad-$USER.service loaded failed failed Something on $(cat "$FIXTURE/host")"',
    'rpm': 'echo "kernel-6.17.4-300.fc44.x86_64"; echo "hyprland-0.52.0-1.fc44.x86_64"',
    'lspci': textwrap.dedent('''\
        printf '%s\\n' '00:02.0 VGA compatible controller [0300]: Intel Corporation Device [8086:7d55]' \\
          $'\\tKernel driver in use: xe' \\
          '01:00.0 3D controller [0302]: NVIDIA Corporation AD102 [10de:2684]' $'\\tKernel driver in use: nvidia' '''),
    'lsusb': 'cat "$FIXTURE/log"',
    'lsblk': 'echo "nvme0n1 1.8T disk"',
    'hyprctl': textwrap.dedent('''\
        if [[ $* == 'monitors all -j' ]]; then
          echo '[{"name":"DP-1","serial":"7YK3CK3","description":"Dell Inc. DELL U2723QE 7YK3CK3"}]'
        else
          cat "$FIXTURE/log"
        fi'''),
    'mokutil': 'echo "SecureBoot enabled"',
    'nmcli': textwrap.dedent('''\
        case "$*" in
          '-t -f NAME,TYPE connection show') printf '%s\\n' 'Wired connection 1:802-3-ethernet' \\
             'CoffeeShop Guest:802-11-wireless' 'Home\\:Net:802-11-wireless' ;;
          *'CoffeeShop Guest') echo 'CoffeeShop Guest' ;;
          *) echo 'HomeNet-5G' ;;
        esac'''),
    'qs': 'echo "quickshell 0.2.0"',
    'cybexos-update-run': 'echo "{\\"state\\":\\"idle\\",\\"log\\":\\"$HOME/.local/state/cybexos/update/logs\\"}"',
    'xdg-open': 'printf "%s\\n" "$1" >"$FIXTURE/opened"',
}


class RedactorFixtures(unittest.TestCase):
    def redactor(self):
        return report.Redactor(users={USER}, names={'Johnathan Example', 'Johnathan', 'Example'},
                               hosts={HOST, 'fedora'}, homes={f'/home/{USER}', f'/var/home/{USER}'},
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
        redact = report.Redactor(hosts={'fedora', 'localhost', 'ab'}, users={'jo'})
        self.assertEqual(redact('Fedora fedora localhost ab jo'), 'Fedora fedora localhost ab jo')

    def test_timestamps_versions_and_pci_addresses_are_not_addresses(self):
        redact = report.Redactor()
        for text in ('2026-10-13 22:09:11', '12:34:56.789', 'std::string::npos', 'qrc:/Foo.qml:12:5',
                     'version 1.2.3.4.5', 'nvidia 615.78.08', '0000:00:02.0', 'fe80 is a prefix'):
            self.assertEqual(redact(text), text)
        self.assertEqual(redact('gateway 192.168.0.1:53'), 'gateway [ipv4]:53')


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
            script.write_text('#!/bin/bash\n' + textwrap.dedent(body))
            script.chmod(0o755)

    def environment(self):
        return {'PATH': f'{self.bin}:/usr/bin:/bin', 'HOME': str(self.home), 'USER': USER,
                'FIXTURE': str(self.fixture), 'CYBEXOS_REPORT': str(HELPER), 'PYTHONDONTWRITEBYTECODE': '1',
                'XDG_STATE_HOME': str(self.home / '.local/state')}

    def run(self, *argv, command=None):
        return subprocess.run(command or ['python3', str(HELPER), *argv], env=self.environment(), text=True,
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
                'README.txt', 'summary.json', 'doctor.json', 'versions.txt', 'hardware.txt', 'shell-health.json',
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
            self.assertEqual(summary['doctor'], 'warning')
            self.assertEqual(summary['attention'], ['hardware'])
            self.assertEqual(summary['cybexos'], 'cybexos-desktop-0.4.0-1.fc44.noarch')
            self.assertIn('NVIDIA Corporation AD102 [10de:2684] (nvidia)', summary['gpus'])
            self.assertGreater(summary['redactions']['token'], 0)
            json.loads(content['doctor.json'])
            self.assertIn('/home/[user]', content['shell-health.json'])
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
            self.assertIn('- CybexOS: cybexos-desktop-0.4.0-1.fc44.noarch', environment)
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


class DispatcherParity(unittest.TestCase):
    def dispatchers(self, fixture):
        checkout = jinja2.Environment(undefined=jinja2.StrictUndefined)
        checkout.filters['quote'] = shlex.quote
        home = fixture.home
        (home / '.local/bin').mkdir(parents=True, exist_ok=True)
        (home / '.local/bin/cybexos-report').symlink_to(HELPER)
        rendered = checkout.from_string((ROOT / 'roles/dotfiles/templates/cybex.j2').read_text()).render(
            primary_home=str(home))
        image = (ROOT / 'image/rootfs/usr/bin/cybex').read_text().replace(
            '/usr/share/cybexos/bin/cybexos-report', shlex.quote(str(HELPER)))
        paths = []
        for name, source in (('checkout', rendered), ('iso', image)):
            path = fixture.base / f'cybex-{name}'
            path.write_text(source)
            path.chmod(0o755)
            paths.append(path)
        return paths

    def test_both_dispatchers_run_the_same_report(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            results = []
            for dispatcher in self.dispatchers(fixture):
                result = fixture.run(command=[str(dispatcher), 'report', '--json', '--output', str(fixture.base)])
                self.assertEqual(result.returncode, 0, result.stderr)
                output = json.loads(result.stdout)
                results.append((sorted(output), sorted(output['summary']), output['summary']['members']))
                help_text = fixture.run(command=[str(dispatcher), 'help']).stdout
                self.assertRegex(help_text, r'\n  report +Collect a redacted diagnostic bundle for a bug report\n')
            self.assertEqual(results[0], results[1])

    def test_both_installation_paths_ship_the_helper(self):
        contract = json.loads((ROOT / 'assets/desktop-contract.json').read_text())
        self.assertIn('cybexos-report', contract['userHelpers'])
        self.assertIn('exec /usr/share/cybexos/bin/cybexos-report "$@"', (ROOT / 'image/rootfs/usr/bin/cybex').read_text())
        self.assertIn("'/.local/bin/cybexos-report'", (ROOT / 'roles/dotfiles/templates/cybex.j2').read_text())
        self.assertIn('/.local/bin/cybexos-report"', (ROOT / 'roles/uninstall/tasks/main.yml').read_text())
        self.assertTrue(os.access(HELPER, os.X_OK))


if __name__ == '__main__':
    unittest.main()
