"""Supervised updater firmware review/progress with fake hardware boundaries."""
import copy
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import test_lifecycle as lifecycle
from cybexos import automatic, cli, firmware
from cybexos.common import CommandFailure, Failure, atomic, read

DISCOVER = firmware.discover
DEVICE = {'id': 'bios', 'name': 'System Firmware', 'vendor': 'Example',
          'from': '1', 'to': '2', 'needsReboot': True, 'affectsFde': True}
PLAN = {'state': 'available', 'devices': [DEVICE]}


class Discovery(unittest.TestCase):
    def test_refresh_is_read_only_and_unavailability_is_not_current(self):
        calls = []
        def run(*args, **kwargs):
            calls.append((args, kwargs))
            return json.dumps({'devices': [DEVICE]})
        self.assertEqual(DISCOVER(run, refresh=True), PLAN)
        self.assertEqual(calls[0][0], ('cybexos-firmware-update', 'plan', '--refresh'))
        for output in ('', '[]', '{"devices":null}', '{"devices":[{}]}'):
            with self.subTest(output=output):
                self.assertEqual(DISCOVER(lambda *a, **kw: output)['state'], 'unavailable')
        def failed(*args, **kwargs):
            raise CommandFailure('firmware', 2, 'private diagnostic')
        result = DISCOVER(failed)
        self.assertEqual(result['state'], 'unavailable')
        self.assertNotIn('private diagnostic', str(result))


class FirmwareUpdates(unittest.TestCase):
    setUp = lifecycle.EngineTests.setUp

    def stage(self, scope='firmware'):
        with patch('cybexos.engine.firmware.discover', return_value=copy.deepcopy(PLAN)):
            return self.engine.stage(scope)

    def install_runner(self, fail=False):
        original = self.engine.run
        snapshots = []
        def run(*args, **kwargs):
            if args[:2] != ('cybexos-firmware-update', 'install'):
                return original(*args, **kwargs)
            self.assertEqual(read(args[args.index('--plan') + 1]), {'devices': [DEVICE]})
            self.assertEqual(kwargs['timeout'], float('inf'))
            events = [
                {'event': 'device', 'id': 'bios'},
                {'event': 'progress', 'id': 'bios', 'percent': 42, 'status': 'device-write'},
                {'event': 'request', 'id': 'bios', 'kind': 'immediate', 'message': 'Keep the device plugged in.'},
                {'event': 'installed', 'id': 'bios', 'needsReboot': True},
            ]
            if fail:
                events.append({'event': 'failed', 'id': 'dock', 'message': 'Connect external power.'})
            events.append({'event': 'summary', 'installed': 1, 'failed': int(fail), 'needsReboot': True})
            for event in events:
                data = (json.dumps(event) + '\n').encode()
                # Exercise chunk boundaries from the real Runner observer.
                run.observer(data[:7])
                run.observer(data[7:])
                snapshots.append(read(self.engine.status_path))
            if fail:
                raise CommandFailure('firmware', 1)
            return ''
        run.observer = None
        run.log = None
        self.engine.run = run
        return snapshots

    def test_device_only_uses_the_real_stage_apply_request_flow(self):
        with patch('cybexos.cli.subprocess.run'), patch('cybexos.engine.firmware.discover', return_value=PLAN):
            queued = cli.enqueue_update(self.engine.state, 'stage', ['firmware'])
            cli.run_update(self.engine, queued['requestId'])
        ready = cli.update_status(self.engine.state, self.working)
        self.assertEqual(ready['firmware'], PLAN)
        self.assertEqual(ready['state'], 'ready')
        self.assertFalse(any(call[0] == 'nix' for call in self.runner.calls))
        snapshots = self.install_runner()
        with patch('cybexos.cli.subprocess.run'):
            queued = cli.enqueue_update(self.engine.state, 'apply', [ready['transaction'], ready['reviewToken']])
            cli.run_update(self.engine, queued['requestId'])
        result = cli.update_status(self.engine.state, self.working)
        self.assertEqual(result['state'], 'done')
        self.assertTrue(result['firmware']['needsReboot'])
        self.assertTrue(any(snapshot['firmware'].get('percent') == 42 for snapshot in snapshots))
        self.assertTrue(any(snapshot['firmware']['requests'] for snapshot in snapshots))
        self.assertEqual(lifecycle.config_digest(self.config), self.sentinel)
        self.assertFalse(self.engine.pending_path.exists())
        self.assertFalse(any('switch-to-configuration' in str(call) or 'reboot' in call for call in self.runner.calls))

    def test_combined_device_failure_keeps_the_successful_os_activation(self):
        record = self.stage('upstream')
        self.install_runner(fail=True)
        self.engine.apply(record['id'], record['reviewToken'])
        result = read(self.engine.status_path)
        self.assertEqual(result['state'], 'awaiting-boot')
        self.assertEqual(result['firmware']['state'], 'failed')
        self.assertEqual(result['firmware']['error'], 'Connect external power.')
        self.assertEqual(read(self.engine.pending_path)['phase'], 'boot')
        self.assertFalse((self.engine.tx(record['id']) / 'failed.json').exists())

    def test_rejected_os_activation_never_starts_firmware(self):
        record = self.stage('upstream')
        self.runner.fail = lambda args: args[0].endswith('/switch-to-configuration') and args[-1] == 'test'
        with self.assertRaises(Failure):
            self.engine.apply(record['id'], record['reviewToken'])
        self.assertFalse(any(call[:2] == ('cybexos-firmware-update', 'install') for call in self.runner.calls))

    def test_firmware_review_cannot_be_rolled_back_as_an_os_generation(self):
        record = self.stage()
        with self.assertRaisesRegex(Failure, 'firmware cannot be reverted'):
            self.engine.rollback(record['id'])

    def test_firmware_only_targets_are_prepared_and_restart_blocks_background_preparation(self):
        scope, identity = automatic.target('config', {'upstream': {'state': 'current'},
            'cybexos': {'state': 'current'}, 'firmware': PLAN})
        self.assertEqual(scope, 'firmware')
        changed = copy.deepcopy(PLAN)
        changed['devices'][0]['to'] = '3'
        self.assertNotEqual(identity, automatic.target('config', {'upstream': {'state': 'current'},
            'cybexos': {'state': 'current'}, 'firmware': changed})[1])
        result = automatic.prepare(self.engine, lambda *a: self.fail('No request before restart'),
            lambda: {'state': 'done', 'firmware': {'needsReboot': True}}, lifecycle.config_digest)
        self.assertEqual(result, {'skipped': 'restart'})

    def test_restart_requirement_clears_only_after_boot_identity_changes(self):
        self.engine.status(state='done', firmware={'needsReboot': True, 'bootId': self.engine.boot_id()})
        self.assertTrue(cli.update_status(self.engine.state, self.working)['firmware']['needsReboot'])
        self.engine.status(firmware={'needsReboot': True, 'bootId': 'previous-boot'})
        self.assertFalse(cli.update_status(self.engine.state, self.working)['firmware']['needsReboot'])
        self.assertTrue(read(self.engine.status_path)['firmware']['needsReboot'])

    def test_interrupted_firmware_keeps_a_successfully_activated_os_pending(self):
        identifier = 'e' * 32
        self.engine.status(state='firmware', transaction='a' * 32, requestId=identifier,
                           firmware={'state': 'installing', 'needsReboot': False})
        atomic(self.engine.pending_path, {'phase': 'boot'})
        atomic(self.engine.state / 'request-status' / (identifier + '.json'), {
            'createdAt': 0, 'state': 'running', 'unit': f'cybexos-update@{identifier}.service'})
        stopped = SimpleNamespace(returncode=0, stdout='ActiveState=failed\nResult=signal\n')
        with patch('cybexos.cli.subprocess.run', return_value=stopped):
            result = cli.update_status(self.engine.state, self.working)
        self.assertEqual(result['state'], 'awaiting-boot')
        self.assertEqual(result['firmware']['state'], 'failed')
        self.assertIn('cannot be rolled back', result['firmware']['error'])
        self.assertTrue(self.engine.pending_path.exists())
