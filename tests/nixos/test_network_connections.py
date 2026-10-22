#!/usr/bin/env python3
"""VPN and hotspot contracts of network-tool.py and system_settings_network.

nmcli is a PATH stub that logs every call; the secret agent runs against a
fake NetworkManager on a private D-Bus daemon. Nothing touches the host's
NetworkManager, and no secret may appear in a helper's output or argv.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'desktop/quickshell/scripts'
HELPER = SCRIPTS / 'network-tool.py'
sys.path.insert(0, str(SCRIPTS))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool = load('network_tool_under_test', HELPER)
agent = load('network_vpn_agent_under_test', SCRIPTS / 'network_vpn_agent.py')

OFFICE = '11111111-2222-4333-8444-555555555555'
HOME_WG = '22222222-3333-4444-8555-666666666666'
WIFI = '33333333-4444-4555-8666-777777777777'
HOTSPOT = tool.HOTSPOT_UUID

# nmcli: answers from a JSON rule list, logs argv and (for passwd-file) stdin.
# An import also records whether its file argument was a symlink and where it
# pointed, so the WireGuard rename path can be checked without copying keys.
NMCLI = r'''#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
entry = {"argv": argv}
if "passwd-file" in argv:
    entry["stdin"] = sys.stdin.read()
if "import" in argv and "file" in argv:
    target = argv[argv.index("file") + 1]
    entry["symlink"] = os.path.islink(target)
    entry["points"] = os.readlink(target) if os.path.islink(target) else ""
    entry["name"] = os.path.basename(target)
with open(os.environ["STUB_LOG"], "a") as stream:
    stream.write(json.dumps(entry) + "\n")
with open(os.environ["STUB_RULES"]) as stream:
    rules = json.load(stream)
for rule in rules:
    if all(token in argv for token in rule.get("all", [])) and not any(
            token in argv for token in rule.get("none", [])):
        sys.stdout.write(rule.get("stdout", ""))
        sys.stderr.write(rule.get("stderr", ""))
        sys.exit(rule.get("code", 0))
sys.exit(0)
'''


def connection_list(*records):
    blocks = []
    for name, uuid, kind, device, state, stamp in records:
        blocks.append(f'NAME:{name}\nUUID:{uuid}\nTYPE:{kind}\nDEVICE:{device}\n'
                      f'STATE:{state}\nTIMESTAMP:{stamp}\n')
    return '\n'.join(blocks)


PROFILES = connection_list(
    ('Office', OFFICE, 'vpn', '--', '', '1700000000'),
    ('home', HOME_WG, 'wireguard', 'home', 'activated', '1800000000'),
    ('Home Wi-Fi', WIFI, '802-11-wireless', 'wlan0', 'activated', '1800000500'),
    ('tailscale0', '44444444-5555-4666-8777-888888888888', 'tun', 'tailscale0', 'activated', '0'),
)
LIST = {'all': ['connection', 'show', 'NAME,UUID,TYPE,DEVICE,STATE,TIMESTAMP'], 'stdout': PROFILES}
SERVICES = {'all': ['connection.uuid,vpn.service-type'],
            'stdout': f'connection.uuid:{OFFICE}\nvpn.service-type:org.freedesktop.NetworkManager.openvpn\n'}
DEVICES = {'all': ['device', 'status'],
           'stdout': 'wlan0:wifi:connected:Home Wi-Fi:' + WIFI + '\neth0:ethernet:connected:Wired:x\n'}
AP_YES = {'all': ['WIFI-PROPERTIES.AP'], 'stdout': 'WIFI-PROPERTIES.AP:yes\n'}


class Stubbed(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix='network-connections-'))
        self.bin = self.scratch / 'bin'
        self.bin.mkdir()
        (self.bin / 'nmcli').write_text(NMCLI.replace("#!/usr/bin/env python3", f"#!{sys.executable}"))
        (self.bin / 'nmcli').chmod(0o755)
        self.log = self.scratch / 'nmcli.log'
        self.rules_path = self.scratch / 'rules.json'
        self.rules([])
        # No test reaches the host's NetworkManager: the system bus is a
        # dead end unless a test brings its own.
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", STUB_LOG=str(self.log),
                        STUB_RULES=str(self.rules_path), PYTHONDONTWRITEBYTECODE='1',
                        TMPDIR=str(self.scratch), DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent')

    def tearDown(self):
        shutil.rmtree(self.scratch, ignore_errors=True)

    def rules(self, rules):
        self.rules_path.write_text(json.dumps(rules))

    def invoke(self, command, request):
        result = subprocess.run([sys.executable, str(HELPER), command], input=json.dumps(request) + '\n',
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.stderr, '')
        return result.returncode, json.loads(result.stdout), result.stdout

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def argvs(self, *tokens):
        return [call['argv'] for call in self.calls() if all(token in call['argv'] for token in tokens)]


class Parsing(unittest.TestCase):
    def test_vpn_profiles_come_from_the_terse_connection_list(self):
        vpns = tool.parse_vpn_profiles(PROFILES + '\nNAME:Bad\nUUID:not-a-uuid\nTYPE:vpn\nDEVICE:--\n')
        self.assertEqual([vpn['name'] for vpn in vpns], ['home', 'Office'])
        office = vpns[1]
        self.assertEqual((office['uuid'], office['type'], office['state'], office['active'], office['timestamp']),
                         (OFFICE, 'vpn', '', False, 1700000000))
        self.assertEqual((vpns[0]['label'], vpns[0]['kind'], vpns[0]['active'], vpns[0]['device']),
                         ('WireGuard', 'wireguard', True, 'home'))

    def test_escaped_names_and_missing_state_columns(self):
        output = (f'NAME:Corp\\: Paris\nUUID:{OFFICE}\nTYPE:vpn\nDEVICE:wlan0\n\n'
                  f'NAME:Lab\nUUID:{HOME_WG}\nTYPE:wireguard\nDEVICE:--\nSTATE:activating\nTIMESTAMP:junk\n')
        corp, lab = tool.parse_vpn_profiles(output)
        self.assertEqual(corp['name'], 'Corp: Paris')
        self.assertEqual(corp['state'], 'activated', 'a bound device without a STATE column is up')
        self.assertEqual((lab['state'], lab['active'], lab['timestamp']), ('activating', False, 0))

    def test_snapshot_lists_vpns_from_the_profile_query(self):
        self.assertIn('STATE', tool.CONNECTION_FIELDS)
        self.assertIn('TIMESTAMP', tool.CONNECTION_FIELDS)
        self.assertEqual(tool.connection_list_command()[-3:], [tool.CONNECTION_FIELDS, 'connection', 'show'])

    def test_wifi_devices_and_hotspot_device_choice(self):
        devices = tool.parse_wifi_devices('wlan0:wifi:connected:Home\\: 5G:' + WIFI + '\n'
                                          'wlan1:wifi:disconnected:--:--\neth0:ethernet:connected:W:x\n')
        self.assertEqual([device['interface'] for device in devices], ['wlan0', 'wlan1'])
        self.assertEqual(devices[0]['connection'], 'Home: 5G')
        self.assertEqual(devices[1]['uuid'], '')
        devices[0]['ap'], devices[1]['ap'] = True, True
        self.assertEqual(tool.choose_hotspot_device(devices)['interface'], 'wlan1',
                         'an idle second adapter hosts without dropping Wi-Fi')
        self.assertEqual(tool.choose_hotspot_device(devices, 'wlan0')['interface'], 'wlan0')
        devices[1]['ap'] = False
        self.assertEqual(tool.choose_hotspot_device(devices)['interface'], 'wlan0')
        devices[0]['ap'] = False
        self.assertIsNone(tool.choose_hotspot_device(devices))

    def test_generated_password_is_strong_and_typeable(self):
        passwords = {tool.generate_password() for _ in range(64)}
        self.assertEqual(len(passwords), 64)
        for password in passwords:
            self.assertRegex(password, r'^[a-hjkmnp-z2-9]{4}(-[a-hjkmnp-z2-9]{4}){3}$')
            self.assertTrue(8 <= len(password) <= 63, 'WPA2 passphrase length')

    def test_config_kind_sniffs_without_trusting_the_suffix_for_conf(self):
        self.assertEqual(tool.config_kind('.ovpn', ''), 'openvpn')
        self.assertEqual(tool.config_kind('.conf', '[Interface]\nPrivateKey = abc=\n[Peer]\n'), 'wireguard')
        self.assertEqual(tool.config_kind('.conf', '# provider\nclient\nremote vpn.example 1194\n'), 'openvpn')
        with self.assertRaises(tool.ToolError) as caught:
            tool.config_kind('.conf', '[Unit]\nDescription=not a vpn\n')
        self.assertEqual(caught.exception.code, 'unsupported_file')

    def test_wireguard_interface_names_and_display_names(self):
        self.assertEqual(tool.wireguard_interface('My Office VPN (2)'), 'MyOfficeVPN2')
        self.assertEqual(tool.wireguard_interface('a' * 40), 'a' * 15)
        self.assertEqual(tool.wireguard_interface('ÄÖÜ'), 'wg0')
        self.assertEqual(tool.display_name('  Paris\x07 office '), 'Paris office')

    def test_dns_presets_leave_shared_profiles_alone(self):
        wired = {'connectionType': '802-3-ethernet', 'standalone': True, 'ipv4Method': 'auto'}
        hotspot = {'connectionType': '802-11-wireless', 'standalone': True, 'ipv4Method': 'shared'}
        self.assertTrue(tool.target_profile(wired))
        self.assertFalse(tool.target_profile(hotspot))

    def test_error_mapping_never_echoes_diagnostics(self):
        leak = 'line 7: <key>MIIEvQIBADANsecret</key>'
        for stderr, code in [('Error: failed to load VPN plugin: missing', 'vpn_plugin_missing'),
                             ('Error: not authorized to add connection', 'not_authorized'),
                             ('Error: failed to read: Permission denied', 'unreadable_file'),
                             (leak, 'import_failed')]:
            found, message = tool.import_failure(stderr, 'openvpn')
            self.assertEqual(found, code, stderr)
            self.assertNotIn('MIIE', message)
        for stderr, code in [('Error: Connection activation failed: No suitable device found', 'hotspot_unavailable'),
                             ('Error: Timeout expired (25 seconds)', 'hotspot_timeout'),
                             ('Error: Insufficient privileges', 'not_authorized'),
                             ('Error: Secrets were required, but not provided', 'hotspot_secrets'),
                             ('Error: something else', 'hotspot_failed')]:
            self.assertEqual(tool.hotspot_failure(stderr)[0], code, stderr)


class VpnActions(Stubbed):
    def test_list_names_each_plugin_with_one_extra_read(self):
        self.rules([SERVICES, LIST])
        status, response, _ = self.invoke('vpn', {'action': 'list'})
        self.assertEqual(status, 0)
        labels = {vpn['name']: (vpn['kind'], vpn['label']) for vpn in response['vpns']}
        self.assertEqual(labels, {'Office': ('openvpn', 'OpenVPN'), 'home': ('wireguard', 'WireGuard')})
        lookups = self.argvs('connection.uuid,vpn.service-type')
        self.assertEqual(len(lookups), 1)
        self.assertEqual(lookups[0][-2:], ['uuid', OFFICE], 'only VPN-plugin profiles are looked up')

    def test_snapshot_carries_the_vpn_list(self):
        self.rules([LIST, {'all': ['device', 'show'], 'stdout': ''}])
        (self.bin / 'ip').write_text(f'#!{shutil.which("sh")}\necho "[]"\n')
        (self.bin / 'ip').chmod(0o755)
        result = subprocess.run([sys.executable, str(HELPER), 'snapshot'], env=self.env, text=True,
                                capture_output=True, timeout=30)
        snapshot = json.loads(result.stdout)
        self.assertTrue(snapshot['success'], result.stdout)
        self.assertEqual([vpn['uuid'] for vpn in snapshot['vpns']], [HOME_WG, OFFICE])
        self.assertNotIn('vpns', snapshot['profiles'][0])

    def test_disconnect_and_already_connected_requests(self):
        self.rules([LIST])
        status, response, _ = self.invoke('vpn', {'action': 'disconnect', 'uuid': HOME_WG})
        self.assertEqual(status, 0, response)
        self.assertEqual(self.argvs('down'), [['--wait', '15', 'connection', 'down', 'uuid', HOME_WG]])
        status, response, _ = self.invoke('vpn', {'action': 'connect', 'uuid': HOME_WG})
        self.assertEqual((status, response['success']), (0, True), 'an active VPN needs no agent')

    def test_actions_refuse_profiles_that_are_not_vpns(self):
        self.rules([LIST])
        for action in ('connect', 'disconnect', 'remove'):
            status, response, _ = self.invoke('vpn', {'action': action, 'uuid': WIFI, 'confirmed': True})
            self.assertEqual((status, response['code']), (1, 'vpn_missing'), action)
        status, response, _ = self.invoke('vpn', {'action': 'remove', 'uuid': 'x; rm -rf /'})
        self.assertEqual(response['code'], 'invalid_request')
        self.assertEqual(self.argvs('delete') + self.argvs('down'), [])

    def test_removal_requires_the_confirming_second_press(self):
        self.rules([LIST])
        status, response, _ = self.invoke('vpn', {'action': 'remove', 'uuid': OFFICE})
        self.assertEqual((status, response['code']), (1, 'confirmation_required'))
        self.assertEqual(self.argvs('delete'), [])
        status, response, _ = self.invoke('vpn', {'action': 'remove', 'uuid': OFFICE, 'confirmed': True})
        self.assertEqual(status, 0, response)
        self.assertEqual(self.argvs('delete'), [['connection', 'delete', 'uuid', OFFICE]])
        self.assertEqual(response['message'], 'Removed Office')

    def test_openvpn_import_uses_the_file_and_never_echoes_it(self):
        secret = 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASC-private'
        source = self.scratch / 'Paris office.ovpn'
        source.write_text(f'client\nremote vpn.example 1194\n<key>\n{secret}\n</key>\n')
        added = f"Connection 'Paris office' ({OFFICE}) successfully added.\n"
        self.rules([{'all': ['import'], 'stdout': added},
                    {'all': ['connection', 'show'], 'stdout': connection_list(
                        ('Paris office', OFFICE, 'vpn', '--', '', '0'))}])
        status, response, stdout = self.invoke('vpn', {'action': 'import', 'path': str(source)})
        self.assertEqual(status, 0, response)
        self.assertEqual((response['uuid'], response['name'], response['kind']), (OFFICE, 'Paris office', 'openvpn'))
        imports = self.argvs('import')
        self.assertEqual(imports, [['connection', 'import', 'type', 'openvpn', 'file', str(source)]])
        self.assertIn(['connection', 'modify', 'uuid', OFFICE, 'connection.autoconnect', 'no'], self.argvs('modify'))
        self.assertEqual(self.argvs('down'), [], 'an OpenVPN import never connects by itself')
        self.assertNotIn(secret, stdout + self.log.read_text().replace(str(source), ''))

    def test_wireguard_import_symlinks_an_interface_name_and_keeps_the_title(self):
        key = 'cGVyc29uYWwta2V5LXRoYXQtbXVzdC1uZXZlci1sZWFr='
        source = self.scratch / 'My Office VPN.conf'
        source.write_text(f'[Interface]\nPrivateKey = {key}\nAddress = 10.0.0.2/32\n[Peer]\n')
        self.rules([{'all': ['import'], 'stdout': f"Connection 'MyOfficeVPN' ({HOME_WG}) successfully added.\n"}])
        status, response, stdout = self.invoke('vpn', {'action': 'import', 'path': str(source)})
        self.assertEqual(status, 0, response)
        call = next(call for call in self.calls() if 'import' in call['argv'])
        self.assertEqual(call['argv'][:4], ['connection', 'import', 'type', 'wireguard'])
        self.assertTrue(call['symlink'], 'the key is never copied into a temporary file')
        self.assertEqual((call['name'], call['points']), ('MyOfficeVPN.conf', str(source)))
        self.assertIn(['connection', 'modify', 'uuid', HOME_WG, 'connection.autoconnect', 'no',
                       'connection.id', 'My Office VPN'], self.argvs('modify'))
        self.assertEqual(self.argvs('down'), [['connection', 'down', 'uuid', HOME_WG]],
                         'NetworkManager starts an imported WireGuard profile; the import stops it')
        self.assertEqual(response['name'], 'My Office VPN')
        self.assertEqual(list(self.scratch.glob('cybexos-vpn-import-*')), [], 'the symlink directory is removed')
        self.assertNotIn(key, stdout + self.log.read_text())

    def test_import_validates_the_file_before_nmcli_sees_it(self):
        plain = self.scratch / 'notes.conf'
        plain.write_text('[Unit]\nDescription=no vpn\n')
        large = self.scratch / 'huge.ovpn'
        large.write_bytes(b'#' * (tool.MAX_IMPORT_BYTES + 1))
        fifo = self.scratch / 'pipe.ovpn'
        os.mkfifo(fifo)
        cases = [('relative.ovpn', 'invalid_file'), (str(self.scratch / 'key.pem'), 'invalid_file'),
                 (str(plain), 'unsupported_file'), (str(large), 'invalid_file'), (str(fifo), 'invalid_file'),
                 (str(self.scratch / 'missing.ovpn'), 'unreadable_file'), ('', 'invalid_file')]
        for path, code in cases:
            status, response, _ = self.invoke('vpn', {'action': 'import', 'path': path})
            self.assertEqual((status, response['code']), (1, code), path)
        self.assertEqual(self.argvs('import'), [])

    def test_import_failures_are_classified_not_quoted(self):
        source = self.scratch / 'Office.ovpn'
        source.write_text('client\n')
        self.rules([{'all': ['import'], 'code': 1,
                     'stderr': "Error: failed to import 'Office.ovpn': line 3: <key>leaked-bytes</key>\n"}])
        status, response, stdout = self.invoke('vpn', {'action': 'import', 'path': str(source)})
        self.assertEqual((status, response['code']), (1, 'import_failed'))
        self.assertNotIn('leaked', stdout)
        self.rules([{'all': ['import'], 'code': 1, 'stderr': 'Error: failed to load VPN plugin: no\n'}])
        status, response, _ = self.invoke('vpn', {'action': 'import', 'path': str(source)})
        self.assertEqual(response['code'], 'vpn_plugin_missing')
        self.assertEqual(response['error'], 'The OpenVPN support for NetworkManager is not installed')


def hotspot_rules(*, profile=None, ap='yes', state='connected', up=None):
    records = [('Home Wi-Fi', WIFI, '802-11-wireless', 'wlan0', 'activated', '1')]
    if profile:
        records.append(profile)
    rules = [{'all': ['device', 'status'],
              'stdout': f'wlan0:wifi:{state}:' + ('Home Wi-Fi:' + WIFI if state == 'connected' else '--:--') + '\n'},
             {'all': ['WIFI-PROPERTIES.AP'], 'stdout': f'WIFI-PROPERTIES.AP:{ap}\n'},
             {'all': ['802-11-wireless.ssid,connection.interface-name'],
              'stdout': '802-11-wireless.ssid:Studio\\: guests\nconnection.interface-name:wlan0\n'},
             {'all': ['connection', 'add'], 'stdout': f"Connection 'CybexOS hotspot' ({HOTSPOT}) successfully added.\n"},
             {'all': ['connection', 'up'], **(up or {})},
             {'all': ['connection', 'show'], 'none': ['uuid'], 'stdout': connection_list(*records)}]
    return rules


class Hotspot(Stubbed):
    def test_status_reports_adapter_profile_and_the_dropped_wifi(self):
        self.rules(hotspot_rules(profile=('CybexOS hotspot', HOTSPOT, '802-11-wireless', '--', '', '0')))
        status, response, _ = self.invoke('hotspot', {'action': 'status'})
        self.assertEqual(status, 0, response)
        self.assertEqual({key: response[key] for key in ('available', 'supported', 'interface', 'configured',
                                                          'uuid', 'ssid', 'state', 'active', 'dropsWifi',
                                                          'wifiConnection', 'radioOff')},
                         {'available': True, 'supported': True, 'interface': 'wlan0', 'configured': True,
                          'uuid': HOTSPOT, 'ssid': 'Studio: guests', 'state': '', 'active': False,
                          'dropsWifi': True, 'wifiConnection': 'Home Wi-Fi', 'radioOff': False})

    def test_start_creates_the_shared_profile_without_a_secret_in_argv(self):
        self.rules(hotspot_rules())
        status, response, stdout = self.invoke('hotspot', {'action': 'start', 'ssid': 'Studio guests'})
        self.assertEqual(status, 0, response)
        add = self.argvs('connection', 'add')[0]
        settings = dict(zip(add[add.index('ssid') + 2::2], add[add.index('ssid') + 3::2]))
        self.assertEqual(add[:10], ['connection', 'add', 'type', 'wifi', 'ifname', 'wlan0',
                                    'con-name', 'CybexOS hotspot', 'ssid', 'Studio guests'])
        for key, value in {'connection.uuid': HOTSPOT, 'connection.autoconnect': 'no',
                           'connection.zone': 'nm-shared', '802-11-wireless.mode': 'ap',
                           'ipv4.method': 'shared', '802-11-wireless-security.key-mgmt': 'wpa-psk'}.items():
            self.assertEqual(settings.get(key), value, key)
        self.assertFalse(any('psk' == key.rsplit('.', 1)[-1] for key in settings), 'no PSK on argv')
        up = next(call for call in self.calls() if 'up' in call['argv'])
        self.assertEqual(up['argv'], ['--wait', '25', 'connection', 'up', 'uuid', HOTSPOT,
                                      'ifname', 'wlan0', 'passwd-file', '/dev/stdin'])
        match = re.fullmatch(r'802-11-wireless-security\.psk:([a-z2-9-]{19})\n', up['stdin'])
        self.assertTrue(match, up['stdin'])
        self.assertNotIn(match.group(1), stdout)
        self.assertEqual(response['message'], 'Hotspot Studio guests is on')

    def test_start_reuses_and_renames_an_existing_profile(self):
        self.rules(hotspot_rules(profile=('CybexOS hotspot', HOTSPOT, '802-11-wireless', '--', '', '0')))
        status, response, _ = self.invoke('hotspot', {'action': 'start', 'ssid': 'New name'})
        self.assertEqual(status, 0, response)
        self.assertEqual(self.argvs('connection', 'add'), [])
        self.assertEqual(self.argvs('modify'), [['connection', 'modify', 'uuid', HOTSPOT,
                                                 '802-11-wireless.ssid', 'New name']])
        self.assertEqual(len(self.argvs('connection', 'up')), 1)

    def test_rename_while_off_never_starts_it(self):
        self.rules(hotspot_rules(profile=('CybexOS hotspot', HOTSPOT, '802-11-wireless', '--', '', '0')))
        status, response, _ = self.invoke('hotspot', {'action': 'rename', 'ssid': 'Quiet room'})
        self.assertEqual(status, 0, response)
        self.assertEqual(len(self.argvs('modify')), 1)
        self.assertEqual(self.argvs('connection', 'up'), [])

    def test_stop_takes_the_profile_down(self):
        self.rules(hotspot_rules(profile=('CybexOS hotspot', HOTSPOT, '802-11-wireless', 'wlan0', 'activated', '0'),
                                 state='connected'))
        status, response, _ = self.invoke('hotspot', {'action': 'stop'})
        self.assertEqual(status, 0, response)
        self.assertEqual(self.argvs('down'), [['--wait', '15', 'connection', 'down', 'uuid', HOTSPOT]])

    def test_refusals_and_activation_failures_are_mapped(self):
        self.rules(hotspot_rules(ap='no'))
        status, response, _ = self.invoke('hotspot', {'action': 'start'})
        self.assertEqual((status, response['code']), (1, 'hotspot_unsupported'))
        self.rules(hotspot_rules(state='unavailable'))
        status, response, _ = self.invoke('hotspot', {'action': 'start'})
        self.assertEqual(response['code'], 'wifi_off')
        self.rules(hotspot_rules(up={'code': 4, 'stderr': 'Error: Connection activation failed: '
                                                          'No suitable device found for this connection.\n'}))
        status, response, _ = self.invoke('hotspot', {'action': 'start'})
        self.assertEqual((status, response['code']), (1, 'hotspot_unavailable'))
        self.log.unlink()
        self.rules(hotspot_rules())
        status, response, _ = self.invoke('hotspot', {'action': 'start', 'ssid': 'x' * 33})
        self.assertEqual(response['code'], 'invalid_request')
        self.assertEqual(self.argvs('connection', 'add'), [])
        self.rules([{'all': ['device', 'status'], 'stdout': 'eth0:ethernet:connected:Wired:x\n'}])
        status, response, _ = self.invoke('hotspot', {'action': 'start'})
        self.assertEqual(response['code'], 'no_wifi')

    def test_join_card_reveals_the_password_only_when_asked(self):
        (self.bin / 'qrencode').write_text(f'#!{shutil.which("sh")}\ncat >/dev/null\nprintf "101\\n010\\n101\\n"\n')
        (self.bin / 'qrencode').chmod(0o755)
        request = {'ssid': 'Studio', 'security': 'WPA2', 'password': 'abcd-efgh-jkmn-pqrs'}
        _, plain, stdout = self.invoke('qr', request)
        self.assertNotIn('abcd-efgh', stdout)
        _, revealed, _ = self.invoke('qr', dict(request, reveal=True))
        self.assertEqual(revealed['password'], 'abcd-efgh-jkmn-pqrs')
        self.assertEqual(plain['matrix'], revealed['matrix'])


class SettingsService(Stubbed):
    def setUp(self):
        super().setUp()
        self.network = load('system_settings_network_under_test', SCRIPTS / 'system_settings_network.py')
        # The service runs network-tool in this process, so its nmcli calls
        # take this process's environment.
        self.saved = dict(os.environ)
        os.environ.update(self.env)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        super().tearDown()

    def service(self):
        return object.__new__(self.network.NetworkSettings)

    def test_vpn_and_hotspot_requests_reach_network_tool(self):
        self.rules([LIST])
        result = self.service().dispatch(dict(action='vpn', op='remove', uuid=OFFICE, confirmed=True))
        self.assertEqual(result['message'], 'Removed Office')
        self.assertNotIn('success', result, 'system-settings.py adds the success flag itself')
        with self.assertRaisesRegex(ValueError, 'Confirm removing'):
            self.service().dispatch(dict(action='vpn', op='remove', uuid=OFFICE))
        with self.assertRaisesRegex(ValueError, 'Unknown hotspot action'):
            self.service().dispatch(dict(action='hotspot', op='explode'))

    def test_extras_never_break_the_profile_snapshot(self):
        self.rules([LIST, SERVICES, DEVICES, AP_YES])
        extras = self.network.connection_extras()
        self.assertEqual([vpn['label'] for vpn in extras['vpns']], ['WireGuard', 'OpenVPN'])
        self.assertTrue(extras['hotspot']['available'])
        self.rules([{'all': ['connection', 'show'], 'code': 8, 'stderr': 'NetworkManager is not running\n'}])
        self.assertEqual(self.network.connection_extras(),
                         {'vpns': [], 'hotspot': {'available': False}, 'extrasError': True})

    def test_request_boundary_returns_bounded_errors(self):
        self.rules([LIST])
        result = subprocess.run([sys.executable, str(SCRIPTS / 'system-settings.py'), 'network'],
                                input=json.dumps(dict(action='vpn', op='remove', uuid=OFFICE)) + '\n',
                                env=self.env, text=True, capture_output=True, timeout=20)
        response = json.loads(result.stdout)
        # Without libnm the service cannot start at all; with it, the request
        # is refused for its missing confirmation. Neither deletes anything.
        self.assertFalse(response['success'])
        self.assertEqual(self.argvs('delete'), [])


class AgentProtocol(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix='network-agent-'))

    def tearDown(self):
        shutil.rmtree(self.scratch, ignore_errors=True)

    def plugin(self, name='openvpn', dialog=True, hints='true'):
        directory = self.scratch / 'plugins'
        directory.mkdir(exist_ok=True)
        path = self.scratch / f'{name}-auth-dialog'
        if dialog:
            path.write_text(f'#!{shutil.which("sh")}\nexit 0\n')
            path.chmod(0o755)
        (directory / f'nm-{name}-service.name').write_text(
            f'[VPN Connection]\nname={name}\nservice=org.freedesktop.NetworkManager.{name}\n\n'
            f'[GNOME]\nauth-dialog={path}\nsupports-hints={hints}\n')
        return directory, path

    def test_plugin_files_name_their_sign_in_dialog(self):
        directory, path = self.plugin()
        info = agent.plugin_info('org.freedesktop.NetworkManager.openvpn', [directory])
        self.assertEqual(info, {'dialog': str(path), 'hints': True})
        self.assertEqual(agent.plugin_info('openvpn', [directory]), info, 'a short service name')
        self.assertIsNone(agent.plugin_info('', [directory]))
        self.assertIsNone(agent.plugin_info('org.freedesktop.NetworkManager.vpnc', [directory]))
        missing, _ = self.plugin('ssh', dialog=False)
        self.assertIsNone(agent.plugin_info('org.freedesktop.NetworkManager.ssh', [missing]),
                          'a dialog that is not executable is no dialog')

    def test_dialog_arguments_and_protocol(self):
        info = {'dialog': '/usr/libexec/nm-openvpn-auth-dialog', 'hints': True}
        self.assertEqual(agent.dialog_argv(info, 'Office', OFFICE, 'org.x.openvpn', 0x1 | 0x2, ['password']),
                         ['/usr/libexec/nm-openvpn-auth-dialog', '-u', OFFICE, '-n', 'Office', '-s',
                          'org.x.openvpn', '-i', '-r', '-t', 'password'])
        self.assertNotIn('-t', agent.dialog_argv(dict(info, hints=False), 'O', OFFICE, 's', 0, ['password']))
        self.assertEqual(agent.dialog_input({'remote': 'vpn.example', 'bad': 'a\nb'}, {'password': 'x'}),
                         b'DATA_KEY=remote\nDATA_VAL=vpn.example\n\nSECRET_KEY=password\nSECRET_VAL=x\n\nDONE\n\n')
        self.assertEqual(agent.dialog_secrets(['password', 'pw', 'certpass', 'cp', 'dangling']),
                         {'password': 'pw', 'certpass': 'cp'})

    def test_failure_reasons(self):
        self.assertEqual(agent.failure_for_reason(9, canceled=True)[0], 'vpn_canceled')
        self.assertEqual(agent.failure_for_reason(9, plugin_missing=True)[0], 'vpn_plugin_missing')
        self.assertEqual(agent.failure_for_reason(10)[1], 'The VPN server rejected the sign-in')
        self.assertEqual(agent.failure_for_reason(99)[0], 'vpn_failed')
        self.assertEqual(agent.failure_for_dbus_error('org.freedesktop.NetworkManager.PermissionDenied')[0],
                         'not_authorized')
        self.assertEqual(agent.failure_for_dbus_error(
            'org.freedesktop.NetworkManager.Manager.ConnectionNotActive')[0], 'vpn_no_network')


# A NetworkManager stand-in on a private bus: settings lookup, agent
# registration, activation, and one GetSecrets round trip per activation (a
# request for another profile first, which the agent must decline).
FAKE_NM = r'''
import json, sys
from gi.repository import Gio, GLib
address, uuid, log_path = sys.argv[1:4]
NM = "org.freedesktop.NetworkManager"
PATH = "/org/freedesktop/NetworkManager"
CONNECTION = PATH + "/Settings/7"
ACTIVE = "/org/freedesktop/NetworkManager/ActiveConnection/1"
XML = """<node>
<interface name="org.freedesktop.NetworkManager"><method name="ActivateConnection">
<arg type="o" direction="in"/><arg type="o" direction="in"/><arg type="o" direction="in"/>
<arg type="o" direction="out"/></method></interface>
<interface name="org.freedesktop.NetworkManager.Settings"><method name="GetConnectionByUuid">
<arg type="s" direction="in"/><arg type="o" direction="out"/></method></interface>
<interface name="org.freedesktop.NetworkManager.AgentManager">
<method name="RegisterWithCapabilities"><arg type="s" direction="in"/><arg type="u" direction="in"/></method>
<method name="Unregister"/></interface>
<interface name="org.freedesktop.NetworkManager.Connection.Active">
<property name="State" type="u" access="read"/><signal name="StateChanged">
<arg type="u"/><arg type="u"/></signal></interface>
</node>"""
node = Gio.DBusNodeInfo.new_for_xml(XML)
bus = Gio.DBusConnection.new_for_address_sync(address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT
    | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
state = {"value": 1, "agent": ""}
def record(**entry):
    with open(log_path, "a") as stream:
        stream.write(json.dumps(entry) + "\n")
def emit(value, reason):
    state["value"] = value
    bus.emit_signal(None, ACTIVE, NM + ".Connection.Active", "StateChanged", GLib.Variant("(uu)", (value, reason)))
def secrets_for(path, then):
    settings = {"connection": {"id": GLib.Variant("s", "Office"), "uuid": GLib.Variant("s", uuid)},
                "vpn": {"service-type": GLib.Variant("s", NM + ".openvpn"),
                        "data": GLib.Variant("a{ss}", {"remote": "vpn.example"}),
                        "secrets": GLib.Variant("a{ss}", {})}}
    bus.call(state["agent"], PATH + "/SecretAgent", NM + ".SecretAgent", "GetSecrets",
             GLib.Variant("(a{sa{sv}}osasu)", (settings, path, "vpn", ["password"], 5)),
             GLib.VariantType.new("(a{sa{sv}})"), Gio.DBusCallFlags.NONE, 30000, None, then, None)
def answered(connection, result, _):
    try:
        secrets = connection.call_finish(result).unpack()[0]
    except GLib.Error as error:
        record(answer=Gio.DBusError.get_remote_error(error))
        GLib.timeout_add(50, lambda: emit(4, 9) and False)
        return
    record(secrets=secrets)
    ok = secrets.get("vpn", {}).get("secrets", {}).get("password") == "correct horse"
    GLib.timeout_add(50, lambda: emit(2 if ok else 4, 1 if ok else 10) and False)
def declined(connection, result, _):
    try:
        connection.call_finish(result)
        record(other="answered")
    except GLib.Error as error:
        record(other=Gio.DBusError.get_remote_error(error))
    secrets_for(CONNECTION, answered)
def method(connection, sender, path, interface, name, parameters, invocation):
    if name == "GetConnectionByUuid":
        if parameters.unpack()[0] != uuid:
            invocation.return_dbus_error(NM + ".Settings.InvalidConnection", "no")
        else:
            invocation.return_value(GLib.Variant("(o)", (CONNECTION,)))
    elif name == "RegisterWithCapabilities":
        state["agent"] = sender
        record(registered=parameters.unpack()[0], capabilities=parameters.unpack()[1])
        invocation.return_value(None)
    elif name == "Unregister":
        record(unregistered=True)
        invocation.return_value(None)
    elif name == "ActivateConnection":
        record(activate=list(parameters.unpack()), sender_is_agent=sender == state["agent"])
        invocation.return_value(GLib.Variant("(o)", (ACTIVE,)))
        GLib.timeout_add(50, lambda: secrets_for(PATH + "/Settings/99", declined) and False)
def prop(connection, sender, path, interface, name):
    return GLib.Variant("u", state["value"])
for path, index in ((PATH, 0), (PATH + "/Settings", 1), (PATH + "/AgentManager", 2), (ACTIVE, 3)):
    bus.register_object(path, node.interfaces[index], method, prop, None)
def owned(*_):
    print("ready", flush=True)
Gio.bus_own_name_on_connection(bus, NM, Gio.BusNameOwnerFlags.NONE, owned, None)
GLib.MainLoop().run()
'''

# The plugin's sign-in dialog: reads the profile data, prints the password
# (or exits 1 when "canceled"), and waits to be told to quit.
DIALOG = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["DIALOG_LOG"], "a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
data = []
for line in sys.stdin:
    if line.strip() == "DONE":
        break
    data.append(line.strip())
if os.environ.get("DIALOG_CANCEL"):
    sys.exit(1)
sys.stdout.write("password\ncorrect horse\n\n\n")
sys.stdout.flush()
for line in sys.stdin:
    if line.strip() == "QUIT":
        break
sys.exit(0)
'''


@unittest.skipUnless(shutil.which('dbus-daemon'), 'dbus-daemon is not installed')
class AgentOnPrivateBus(Stubbed):
    def setUp(self):
        super().setUp()
        if importlib.util.find_spec('gi') is None:
            self.skipTest('PyGObject is not installed')
        config = self.scratch / 'session.conf'
        config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
                          '<auth>EXTERNAL</auth><policy context="default">'
                          '<allow send_destination="*"/><allow receive_sender="*"/>'
                          '<allow own="*"/></policy></busconfig>')
        self.daemon = subprocess.Popen(['dbus-daemon', '--nofork', '--print-address=1',
                                        '--config-file=' + str(config)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_process, self.daemon)
        self.address = self.daemon.stdout.readline().strip()
        self.assertTrue(self.address.startswith('unix:'), 'Private D-Bus did not publish an address')
        self.nm_log = self.scratch / 'nm.log'
        self.nm = subprocess.Popen([sys.executable, '-c', FAKE_NM, self.address, OFFICE, str(self.nm_log)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_process, self.nm)
        ready = self.nm.stdout.readline().strip()
        if ready != 'ready':
            self.nm.wait(timeout=5)
            self.fail('Private NetworkManager fixture did not start: ' + self.nm.stderr.read())
        directory = self.scratch / 'plugins'
        directory.mkdir()
        dialog = self.scratch / 'nm-openvpn-auth-dialog'
        dialog.write_text(DIALOG.replace("#!/usr/bin/env python3", f"#!{sys.executable}"))
        dialog.chmod(0o755)
        (directory / 'nm-openvpn-service.name').write_text(
            '[VPN Connection]\nname=openvpn\nservice=org.freedesktop.NetworkManager.openvpn\n\n'
            f'[GNOME]\nauth-dialog={dialog}\nsupports-hints=true\n')
        self.dialog_log = self.scratch / 'dialog.log'
        self.env.update(DBUS_SYSTEM_BUS_ADDRESS=self.address, NETWORK_VPN_PLUGIN_DIRS=str(directory),
                        NETWORK_TOOL_VPN_TIMEOUT='15', DIALOG_LOG=str(self.dialog_log))
        self.rules([LIST])

    @staticmethod
    def stop_process(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(5)
        for stream in (process.stdout, process.stderr):
            if stream and not stream.closed:
                stream.close()

    def events(self):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            entries = [json.loads(line) for line in self.nm_log.read_text().splitlines()] \
                if self.nm_log.exists() else []
            if any('unregistered' in entry for entry in entries):
                return entries
            time.sleep(0.05)
        return entries

    def test_sign_in_dialog_answers_networkmanager_and_nothing_else(self):
        status, response, stdout = self.invoke('vpn', {'action': 'connect', 'uuid': OFFICE})
        self.assertEqual((status, response.get('success')), (0, True), response)
        self.assertEqual(response['message'], 'Connected to Office')
        events = self.events()
        merged = {key: value for entry in events for key, value in entry.items()}
        self.assertRegex(merged['registered'], r'^org\.cybexos\.network\.vpn-\d+$')
        self.assertEqual(merged['capabilities'], 1)
        self.assertEqual(merged['activate'], ['/org/freedesktop/NetworkManager/Settings/7', '/', '/'])
        self.assertTrue(merged['sender_is_agent'], 'the agent and the activation share one process')
        self.assertEqual(merged['other'], 'org.freedesktop.NetworkManager.SecretAgent.NoSecrets')
        self.assertEqual(merged['secrets'], {'vpn': {'secrets': {'password': 'correct horse'}}})
        self.assertTrue(merged['unregistered'])
        argv = json.loads(self.dialog_log.read_text().splitlines()[0])
        self.assertEqual(argv, ['-u', OFFICE, '-n', 'Office', '-s', 'org.freedesktop.NetworkManager.openvpn',
                                '-i', '-t', 'password'])
        self.assertNotIn('correct horse', stdout)

    def test_a_canceled_sign_in_reports_cancellation(self):
        self.env['DIALOG_CANCEL'] = '1'
        status, response, stdout = self.invoke('vpn', {'action': 'connect', 'uuid': OFFICE})
        self.assertEqual((status, response['code']), (1, 'vpn_canceled'), response)
        merged = {key: value for entry in self.events() for key, value in entry.items()}
        self.assertEqual(merged['answer'], 'org.freedesktop.NetworkManager.SecretAgent.UserCanceled')
        self.assertTrue(merged['unregistered'])

    def test_a_missing_plugin_dialog_is_named(self):
        self.env['NETWORK_VPN_PLUGIN_DIRS'] = str(self.scratch / 'none')
        status, response, _ = self.invoke('vpn', {'action': 'connect', 'uuid': OFFICE})
        self.assertEqual((status, response['code']), (1, 'vpn_plugin_missing'), response)


if __name__ == '__main__':
    unittest.main()
