"""The installer screen's state service, driven over its real Unix socket.

A scripted stand-in for `cybexos-install --json-ui` records every request, so
these tests check what the daemon sends to the one disk-writing worker: the
reviewed plan, the token-bound install request, and nothing else.
"""
import asyncio
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lifecycle'))
loader = importlib.machinery.SourceFileLoader('cybexos_installerd', str(ROOT / 'installer/cybexos-installerd'))
spec = importlib.util.spec_from_loader(loader.name, loader)
daemon = importlib.util.module_from_spec(spec)
loader.exec_module(daemon)

PASSWORD = 'correct horse battery'

WORKER = r'''#!PYTHON
import json, os, sys
log = open(os.environ['FAKE_WORKER_LOG'], 'a')
def emit(**values):
    print(json.dumps(values), flush=True)
def ready():
    emit(event='ready', release='TEST', development=False, hardware={'nvidia': False},
         disks=[{'path': '/dev/vda', 'serial': 'QA-DISK', 'model': 'QA Disk', 'size': 80 * 1024**3,
                 'available': True, 'reason': '', 'filesystems': ['ext4']},
                {'path': '/dev/sda', 'serial': 'USB', 'model': 'Stick', 'size': 8 * 1024**3,
                 'available': False, 'reason': 'Too small', 'filesystems': []}])
emit(event='network', message='Internet connection ready.')
ready()
reviews = 0
token = ''
for line in sys.stdin:
    request = json.loads(line)
    log.write(json.dumps(request) + '\n'); log.flush()
    action = request.get('action')
    if action == 'review':
        reviews += 1
        token = 'token-%d' % reviews
        emit(event='review', plan=request['plan'], token=token)
    elif action == 'rescan':
        ready()
    elif action == 'install':
        if request.get('token') != token or request.get('confirmed') is not True:
            emit(event='error', message='unconfirmed'); break
        emit(event='started')
        emit(event='disk-writing')
        for stage in range(1, 7):
            emit(event='stage', stage=stage, total=6, message='Stage %d' % stage)
        emit(event='complete', username='ada', encrypted=True, hostname='ada-cybexos')
        break
    elif action == 'cancel':
        emit(event='cancelled'); break
'''


def zoneinfo(directory):
    root = Path(directory)
    (root / 'Europe').mkdir(parents=True)
    for name in ('Europe/Amsterdam', 'Europe/Kyiv', 'UTC'):
        (root / name).write_bytes(b'TZif')
    (root / 'iso3166.tab').write_text('# comment\nNL\tNetherlands\nUA\tUkraine\n')
    (root / 'zone.tab').write_text('# comment\nNL\t+5222+00454\tEurope/Amsterdam\nUA\t+5026+03031\tEurope/Kyiv\tmost of Ukraine\n'
                                   'XX\t+0000+00000\tAtlantis/Lost\n')
    (root / 'tzdata.zi').write_text('# version 2026c\nL Europe/Kyiv Europe/Kiev\nL Europe/Kyiv Etc/Ignored\n')
    return root


class TimezoneTableTests(unittest.TestCase):
    def test_zone_tab_countries_aliases_and_canonical_names(self):
        with tempfile.TemporaryDirectory() as directory:
            table = daemon.timezone_table(zoneinfo(directory))
        self.assertEqual([zone[0] for zone in table['zones']], ['Europe/Amsterdam', 'Europe/Kyiv'],
                         'zones without TZif data are not offered')
        self.assertEqual(table['zones'][0][1:4], ['NL', 52.37, 4.9])
        self.assertEqual(table['countries']['NL'], 'Netherlands')
        self.assertEqual(table['aliases'], {'Europe/Kiev': 'Europe/Kyiv'})
        self.assertEqual(table['tzdata'], '2026c')
        self.assertEqual(daemon.canonical_zone('Europe/Kiev', table), 'Europe/Kyiv')
        self.assertEqual(daemon.canonical_zone('UTC', table), 'UTC')
        self.assertEqual(daemon.canonical_zone('Etc/GMT+5', table), 'Etc/GMT+5')
        self.assertIsNone(daemon.canonical_zone('Etc/GMT+15', table))
        self.assertIsNone(daemon.canonical_zone('Mars/Olympus', table))

    def test_names_mirror_the_worker(self):
        reserved = {'root', 'nixos', 'messagebus'}
        self.assertEqual(daemon.username_problem('ada', reserved), '')
        for name in ('Ada', '1ada', 'ada.l', '', 'a' * 32):
            self.assertIn('lowercase', daemon.username_problem(name, reserved))
        self.assertIn('reserved', daemon.username_problem('messagebus', reserved))
        self.assertEqual(daemon.hostname_for('ada'), 'ada-cybexos')
        self.assertEqual(daemon.hostname_for('a' * 31), 'a' * 23 + '-cybexos')
        self.assertEqual(daemon.full_name_problem('José García'), '')
        self.assertNotEqual(daemon.full_name_problem('a:b'), '')

    def test_network_summary_prefers_wired_and_deduplicates_networks(self):
        summary = daemon.summarize_network({'devices': [
            {'interface': 'wlp1', 'type': 'wifi', 'connected': True, 'ssid': 'Home', 'ipv4': '10.0.0.5', 'stateCode': 100},
            {'interface': 'enp2', 'type': 'ethernet', 'connected': True, 'connection': 'Cybex OS Wired', 'ipv4': '10.0.0.6', 'stateCode': 100}],
            'wifi': {'interface': 'wlp1', 'networks': [
                {'ssid': 'Home', 'signal': 40, 'security': 'WPA2', 'connected': True},
                {'ssid': 'Home', 'signal': 80, 'security': 'WPA2'},
                {'ssid': '', 'signal': 90}]}})
        self.assertEqual((summary['kind'], summary['interface'], summary['address']), ('ethernet', 'enp2', '10.0.0.6'))
        self.assertEqual([n['ssid'] for n in summary['wifi']['networks']], ['Home'])


class DaemonTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='nid-'))
        self.addCleanup(shutil.rmtree, self.root, True)
        etc, run, binary = self.root / 'etc', self.root / 'run', self.root / 'bin'
        for directory in (etc, run, binary):
            directory.mkdir()
        (etc / 'installer').write_text('fresh-install-only\n')
        (etc / 'installer-defaults.json').write_text(json.dumps({key: True for key, _, _ in daemon.APPLICATIONS}))
        (etc / 'installer-layout.json').write_text(json.dumps({'minimumDiskGiB': 64, 'espGiB': 16}))
        (etc / 'installer-reserved-names.json').write_text(json.dumps(['messagebus', 'nobody']))
        (etc / 'installer-region.json').write_text(json.dumps({'timezone': 'UTC', 'locale': 'en_US.UTF-8', 'desktopKeyboard': 'us'}))
        (etc / 'release.json').write_text(json.dumps({'version': '1.0.0-test'}))
        worker = binary / 'cybexos-install'
        worker.write_text(WORKER.replace('PYTHON', sys.executable))
        worker.chmod(0o755)
        self.log = self.root / 'worker.log'
        self.commands = []

        async def quiet(command):
            self.commands.append(command)

        fixtures = [
            patch.object(daemon, 'ETC', etc), patch.object(daemon, 'RUNTIME', run),
            patch.object(daemon, 'SOCKET', run / 'control.sock'), patch.object(daemon, 'KEYBOARD_ENV', run / 'keyboard.env'),
            patch.object(daemon, 'geoip_zone', return_value='Europe/Amsterdam'),
            patch.object(daemon, 'run_quiet', side_effect=quiet),
            patch.object(daemon, 'graphics_names', return_value=['QA GPU']),
            patch.dict(os.environ, {'PATH': f'{binary}{os.pathsep}{os.environ.get("PATH", "")}',
                                    'FAKE_WORKER_LOG': str(self.log), 'TZDIR': str(zoneinfo(self.root / 'zoneinfo')),
                                    'CYBEXOS_INSTALLER_GROUP': 'nonexistent-group'}),
        ]
        for fixture in fixtures:
            fixture.start()
            self.addCleanup(fixture.stop)
        self.service = daemon.Daemon([], network_helper='')
        self.stop = asyncio.Event()
        self.task = asyncio.create_task(self.service.serve())
        for _ in range(100):
            if (run / 'control.sock').exists():
                break
            await asyncio.sleep(0.02)
        self.reader, self.writer = await asyncio.open_unix_connection(str(run / 'control.sock'), limit=daemon.MAX_LINE)
        self.received = []

    async def asyncTearDown(self):
        self.writer.close()
        await self.service.shutdown(self.stop)
        self.task.cancel()
        try:
            await self.task
        except (asyncio.CancelledError, Exception):
            pass

    async def send(self, **request):
        self.writer.write((json.dumps(request) + '\n').encode())
        await self.writer.drain()

    async def until(self, predicate, timeout=10):
        async def wait():
            while True:
                line = await self.reader.readline()
                self.assertTrue(line, 'the daemon closed the connection')
                self.received.append(line.decode())
                message = json.loads(line)
                if predicate(message):
                    return message
        return await asyncio.wait_for(wait(), timeout)

    def requests(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    async def setup_phase(self):
        static = await self.until(lambda m: m['type'] == 'static')
        self.assertEqual(static['version'], '1.0.0-test')
        self.assertIn('messagebus', static['reserved'])
        return await self.until(lambda m: m['type'] == 'state' and m['phase'] == 'setup' and m['draft']['timezone'] == 'Europe/Amsterdam')

    async def test_wifi_connect_waits_for_background_poll_and_errors_survive_polling(self):
        await self.setup_phase()
        if self.service.network_task:
            await self.service.network_task
        entered, release = asyncio.Event(), asyncio.Event()
        commands = []

        async def network(command, request):
            commands.append((command, dict(request) if request else None))
            if len(commands) == 1:
                entered.set()
                await release.wait()

        with patch.object(self.service, 'run_network', side_effect=network):
            self.service.network('snapshot', None)
            await entered.wait()
            await self.send(action='network-connect', network={'ssid': 'Home', 'password': PASSWORD})
            await self.send(action='draft', values={'username': 'responsive'})
            await self.until(lambda m: m['type'] == 'state' and m['draft']['username'] == 'responsive')
            self.assertEqual(len(commands), 1)
            release.set()
            await self.service.network_task
        self.assertEqual([c[0] for c in commands], ['snapshot', 'wifi', 'snapshot'])
        self.assertEqual(commands[1][1], {'ssid': 'Home', 'password': PASSWORD})
        self.assertNotIn(PASSWORD, ''.join(self.received))

    async def test_snapshot_keeps_connection_error_and_explicit_refresh_requests_rescan(self):
        await self.setup_phase()
        if self.service.network_task:
            await self.service.network_task
        helper = self.root / 'network.py'
        helper.write_text('import json; print(json.dumps({"success": True, "devices": [], "wifi": {}}))')
        self.service.network_helper = str(helper)
        self.service.state['network']['error'] = 'Check the password'
        await self.service.run_network('snapshot', None)
        self.assertEqual(self.service.state['network']['error'], 'Check the password')
        with patch.object(self.service, 'network') as network:
            await self.service.handle_request(self.writer, {'action': 'network-refresh'})
        network.assert_called_once_with('scan', None)

    async def test_malformed_network_result_is_an_actionable_error(self):
        await self.setup_phase()
        helper = self.root / 'network.py'
        helper.write_text('print("[]")')
        self.service.network_helper = str(helper)
        await self.service.run_network('snapshot', None)
        self.assertIn('Connection failed', self.service.state['network']['error'])
        self.assertFalse(self.service.state['network']['busy'])

    async def test_network_cancellation_kills_and_reaps_helper(self):
        await self.setup_phase()
        if self.service.network_task:
            await self.service.network_task
        pidfile = self.root / 'network.pid'
        helper = self.root / 'network.py'
        helper.write_text(f'import os, pathlib, time\npathlib.Path({str(pidfile)!r}).write_text(str(os.getpid()))\ntime.sleep(60)\n')
        self.service.network_helper = str(helper)
        task = asyncio.create_task(self.service.run_network('snapshot', None))
        try:
            for _ in range(100):
                if pidfile.exists():
                    break
                await asyncio.sleep(.01)
            self.assertTrue(pidfile.exists())
        finally:
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pidfile.read_text()), 0)

    async def test_started_event_does_not_claim_erasure_before_disk_writing(self):
        await self.setup_phase()
        self.service.handle_event({'event': 'started'})
        self.assertFalse(self.service.state['diskTouched'])
        self.service.handle_event({'event': 'error', 'message': 'Network unavailable. No disk has been erased.'})
        self.assertFalse(self.service.state['diskTouched'])
        self.service.handle_event({'event': 'disk-writing'})
        self.assertTrue(self.service.state['diskTouched'])

    async def test_completion_preserves_the_actual_elapsed_installation_time(self):
        await self.setup_phase()
        self.service.started_at = 100.0
        with patch.object(daemon.time, 'monotonic', return_value=142.9):
            self.service.handle_event({'event': 'complete', 'username': 'ada', 'encrypted': True})
        with patch.object(daemon.time, 'monotonic', return_value=500.0):
            self.assertEqual(self.service.snapshot()['elapsed'], 42)

    async def test_slow_details_do_not_block_edits_and_refreshes_are_coalesced(self):
        await self.setup_phase()
        entered, release = asyncio.Event(), asyncio.Event()

        async def details():
            entered.set()
            await release.wait()
            return {'type': 'details', 'text': 'test details', 'error': ''}

        with patch.object(self.service, 'details', side_effect=details) as query:
            await self.send(action='details')
            await asyncio.wait_for(entered.wait(), 1)
            for _ in range(20):
                await self.send(action='details')
            await self.send(action='draft', values={'username': 'responsive', 'screen': 'account'})
            state = await self.until(lambda m: m['type'] == 'state' and m['draft']['username'] == 'responsive', timeout=1)
            self.assertEqual(state['draft']['screen'], 'account')
            self.assertEqual(query.call_count, 1)
            release.set()
            await self.until(lambda m: m['type'] == 'details')

    async def test_disconnect_cancels_inflight_diagnostics(self):
        await self.setup_phase()
        entered, cancelled = asyncio.Event(), asyncio.Event()

        async def details():
            entered.set()
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        with patch.object(self.service, 'details', side_effect=details):
            await self.send(action='details')
            await asyncio.wait_for(entered.wait(), 1)
            self.writer.close()
            await self.writer.wait_closed()
            await asyncio.wait_for(cancelled.wait(), 1)
            self.assertFalse(self.service.queries)

    async def test_review_rereview_and_token_bound_install(self):
        state = await self.setup_phase()
        self.assertEqual(state['draft']['disk'], '/dev/vda', 'the only available disk is preselected')
        self.assertEqual(state['draft']['tzSource'], 'detected')
        await self.send(action='draft', values={'username': 'ada', 'fullName': 'Ada Lovelace', 'screen': 'account', 'layout': 'gb'})
        await self.send(action='review', password=PASSWORD, confirm=PASSWORD)
        review = await self.until(lambda m: m['type'] == 'state' and m['phase'] == 'review')
        plan = self.requests()[-1]['plan']
        self.assertEqual(plan['username'], 'ada')
        self.assertEqual(plan['fullName'], 'Ada Lovelace')
        self.assertEqual(plan['hostname'], 'ada-cybexos')
        self.assertEqual((plan['keyboard'], plan['desktopKeyboard']), ('uk', 'gb'))
        self.assertEqual(plan['timezone'], 'Europe/Amsterdam')
        # Unlocking an encrypted disk signs the owner in.
        self.assertTrue(plan['autoLogin'])
        self.assertTrue(plan['encrypted'])
        self.assertEqual(set(plan['features']), {key for key, _, _ in daemon.APPLICATIONS})
        self.assertEqual(review['review']['serial'], 'QA-DISK')
        self.assertIs(review['review']['autoLogin'], True)

        # Customizing on the review page re-reviews with the held password.
        await self.send(action='draft', values={'timezone': 'Europe/Kiev'})
        await self.until(lambda m: m['type'] == 'state' and m['phase'] == 'review' and m['draft']['timezone'] == 'Europe/Kyiv' and not m['reviewPending'])
        reviews = [r for r in self.requests() if r['action'] == 'review']
        self.assertEqual(len(reviews), 2)
        self.assertEqual(reviews[-1]['plan']['timezone'], 'Europe/Kyiv')
        # A plain disk keeps password login; encrypting it again restores autologin.
        for encrypted in (False, True):
            await self.send(action='draft', values={'encrypted': encrypted})
            await self.until(lambda m: m['type'] == 'state' and m['phase'] == 'review'
                             and m['draft']['encrypted'] is encrypted and not m['reviewPending'])
            self.assertIs(self.requests()[-1]['plan']['autoLogin'], encrypted)

        await self.send(action='install')
        done = await self.until(lambda m: m['type'] == 'state' and m['phase'] == 'complete')
        self.assertEqual(done['result'], {'username': 'ada', 'hostname': 'ada-cybexos', 'encrypted': True})
        self.assertTrue(done['diskTouched'])
        install = self.requests()[-1]
        self.assertEqual(install, {'action': 'install', 'token': 'token-4', 'confirmed': True, 'secrets': {'password': PASSWORD}})
        # The password reaches only the worker: never a snapshot or the saved draft.
        self.assertFalse(any(PASSWORD in line for line in self.received))
        self.assertNotIn(PASSWORD, (self.root / 'run/draft.json').read_text())

    async def test_password_confirmation_and_reserved_names_stop_before_review(self):
        await self.setup_phase()
        await self.send(action='draft', values={'username': 'ada'})
        await self.send(action='review', password=PASSWORD, confirm=PASSWORD + '!')
        state = await self.until(lambda m: m['type'] == 'state' and 'do not match' in m['error'])
        self.assertEqual(state['phase'], 'setup')
        await self.send(action='review', password='short', confirm='short')
        await self.until(lambda m: m['type'] == 'state' and '8' in m['error'])
        await self.send(action='draft', values={'username': 'messagebus'})
        await self.send(action='review', password=PASSWORD, confirm=PASSWORD)
        await self.until(lambda m: m['type'] == 'state' and 'reserved' in m['error'])
        # Invalid draft values are ignored rather than stored.
        await self.send(action='draft', values={'username': 'Ada', 'timezone': 'Mars/Olympus', 'layout': 'xx'})
        await self.send(action='hello')
        state = await self.until(lambda m: m['type'] == 'state')
        self.assertEqual((state['draft']['username'], state['draft']['timezone'], state['draft']['layout']),
                         ('messagebus', 'Europe/Amsterdam', 'us'))
        self.assertFalse([r for r in self.requests() if r['action'] == 'review'])

    async def test_keyboard_change_restarts_the_screen_with_the_new_layout(self):
        await self.setup_phase()
        await self.send(action='keyboard', layout='de')
        await self.until(lambda m: m['type'] == 'restart')
        self.assertEqual((self.root / 'run/keyboard.env').read_text(), 'XKB_DEFAULT_LAYOUT=de\n')
        await asyncio.sleep(0.05)
        self.assertIn(['loadkeys', 'de-latin1'], self.commands)
        await self.send(action='keyboard', layout='not-a-layout')
        await self.send(action='hello')
        state = await self.until(lambda m: m['type'] == 'state')
        self.assertEqual(state['draft']['layout'], 'de')

    async def first_state(self):
        reader, writer = await asyncio.open_unix_connection(str(self.root / 'run/control.sock'), limit=daemon.MAX_LINE)
        try:
            while True:
                message = json.loads(await asyncio.wait_for(reader.readline(), 5))
                if message['type'] == 'state':
                    return message
        finally:
            writer.close()

    async def test_snapshots_report_the_attached_screen(self):
        await self.setup_phase()
        self.assertEqual((await self.first_state())['screens'], 0)
        await self.send(action='hello')
        await self.until(lambda m: m['type'] == 'state')
        self.assertEqual((await self.first_state())['screens'], 0, 'only the screen identifies itself as one')
        await self.send(action='hello', client='screen')
        await self.until(lambda m: m['type'] == 'state' and m['screens'] == 1)
        self.assertEqual((await self.first_state())['screens'], 1)
        # A disconnected screen is no longer reported, as after a daemon restart.
        self.writer.close()
        for _ in range(100):
            if (await self.first_state())['screens'] == 0:
                break
            await asyncio.sleep(0.02)
        else:
            self.fail('the disconnected screen is still reported')

    async def test_service_stops_promptly_with_a_connected_screen(self):
        await self.setup_phase()
        # SIGTERM's handler: the screen's open connection must not hold the exit.
        os.kill(os.getpid(), signal.SIGTERM)
        await asyncio.wait_for(self.task, 15)
        # Buffered snapshots may still arrive, then the connection ends.
        await asyncio.wait_for(self.reader.read(), 5)
        self.assertTrue(self.reader.at_eof())
        self.assertFalse((self.root / 'run/control.sock').exists())

    async def test_shutdown_cancels_an_idle_worker(self):
        await self.setup_phase()
        worker = self.service.worker
        await self.service.shutdown(self.stop)
        self.assertIsNotNone(worker.returncode)
        self.assertEqual(self.requests()[-1], {'action': 'cancel'})


if __name__ == '__main__':
    unittest.main()
