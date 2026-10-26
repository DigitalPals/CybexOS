"""Real request/state/review code with isolated files and a fake system manager."""
import hashlib
import json
from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import test_lifecycle as lifecycle
from cybexos import cli, review
from cybexos.common import Failure, atomic, read


class UpdateRequests(unittest.TestCase):
    setUp = lifecycle.EngineTests.setUp

    def enqueue(self, action, arguments):
        with patch('cybexos.cli.subprocess.run'):
            return cli.enqueue_update(self.engine.state, action, arguments)

    def status(self):
        return cli.update_status(self.engine.state, self.working)

    def test_private_exact_review_payload_and_public_acceptance(self):
        token = 'f' * 64
        accepted = self.enqueue('apply', ['a' * 32, token])
        identifier = accepted['requestId']
        payload = self.engine.state / 'requests' / (identifier + '.json')
        status = self.engine.state / 'request-status' / (identifier + '.json')
        self.assertEqual(read(payload), {'action': 'apply', 'arguments': ['a' * 32, token]})
        self.assertEqual(payload.stat().st_mode & 0o777, 0o600)
        self.assertEqual(status.stat().st_mode & 0o777, 0o644)
        self.assertNotIn(token, json.dumps(self.status()))
        self.assertEqual(accepted['unit'], f'cybexos-update@{identifier}.service')
        with self.assertRaisesRegex(Failure, 'already running'):
            self.enqueue('stage', ['both'])

    def test_submission_failure_is_durable_and_payload_is_removed(self):
        with patch('cybexos.cli.subprocess.run', side_effect=OSError('private detail')):
            with self.assertRaisesRegex(Failure, 'could not be started'):
                cli.enqueue_update(self.engine.state, 'stage', ['upstream'])
        result = self.status()['request']
        self.assertEqual(result['state'], 'failed')
        self.assertNotIn('private detail', result['error'])
        self.assertFalse((self.engine.state / 'requests' / (result['id'] + '.json')).exists())

    def test_discovery_identity_belongs_to_the_exact_lock_read(self):
        body = (self.working / 'flake.lock').read_bytes()
        validate = lifecycle.inputs.validate_machine
        def replace_lock(lock):
            validate(lock)
            updated = json.loads(body)
            updated['nodes']['nixpkgs']['locked']['rev'] = 'f' * 40
            atomic(self.working / 'flake.lock', updated)
        with patch('cybexos.engine.inputs.validate_machine', side_effect=replace_lock):
            result = self.engine.check()
        self.assertEqual(result['installedIdentity'], hashlib.sha256(body).hexdigest())
        self.assertNotEqual(result['installedIdentity'], self.status()['installedIdentity'])

    def test_preflight_rejection_survives_repeated_status_reads(self):
        self.engine.status(state='awaiting-boot', transaction='a' * 32, phase='Waiting for reboot')
        atomic(self.engine.pending_path, {'id': 'a' * 32})
        identifier = self.enqueue('stage', ['both'])['requestId']
        before = read(self.engine.status_path)
        with self.assertRaisesRegex(Failure, 'awaits recovery'):
            cli.run_update(self.engine, identifier)
        self.assertEqual(read(self.engine.status_path), before)
        for _ in range(3):
            result = self.status()
            self.assertEqual(result['request']['id'], identifier)
            self.assertEqual(result['request']['state'], 'failed')
            self.assertIn('awaits recovery', result['request']['error'])

    def test_stale_review_is_invalidated_and_does_not_apply_personal_edits(self):
        identifier = self.enqueue('stage', ['upstream'])['requestId']
        cli.run_update(self.engine, identifier)
        candidate = self.status()
        self.assertEqual(candidate['state'], 'ready')
        self.assertEqual(candidate['packageChanges'][0]['before'], '1')
        self.assertEqual(candidate['packageChanges'][0]['after'], '2')
        (self.config / 'local/personal.nix').write_text('# new personal changes\n{}')
        identifier = self.enqueue('apply', [candidate['transaction'], candidate['reviewToken']])['requestId']
        with self.assertRaisesRegex(Failure, 'configuration changed'):
            cli.run_update(self.engine, identifier)
        result = self.status()
        self.assertEqual(result['state'], 'stale')
        self.assertIsNone(result['reviewToken'])
        self.assertEqual(result['request']['state'], 'failed')
        self.assertFalse(self.engine.pending_path.exists())
        self.assertIn('new personal changes', (self.config / 'local/personal.nix').read_text())

    def test_abrupt_worker_death_reconciles_without_reboot_or_state_mutation(self):
        for phase in ('building', 'activating'):
            with self.subTest(phase=phase):
                identifier = 'e' * 32
                self.engine.status(state=phase, transaction='a' * 32, requestId=identifier)
                atomic(self.engine.state / 'request-status' / (identifier + '.json'), {
                    'createdAt': 0, 'state': 'running', 'unit': f'cybexos-update@{identifier}.service'})
                before = read(self.engine.status_path)
                stopped = SimpleNamespace(returncode=0, stdout='ActiveState=failed\nResult=signal\n')
                with patch('cybexos.cli.subprocess.run', return_value=stopped):
                    result = self.status()
                self.assertEqual(result['state'], 'interrupted' if phase == 'building' else 'recovery-failed')
                self.assertEqual(result['request']['state'], 'failed')
                self.assertEqual(read(self.engine.status_path), before)

    def test_unsafe_new_personal_link_invalidates_review_before_activation(self):
        record = self.engine.stage('upstream')
        (self.config / 'local/new-link').symlink_to('/etc/passwd')
        with self.assertRaisesRegex(Failure, 'configuration changed'):
            self.engine.apply(record['id'], record['reviewToken'])
        self.assertEqual(self.status()['state'], 'stale')
        self.assertIsNone(self.status()['reviewToken'])
        self.assertFalse(self.engine.pending_path.exists())

    def test_worker_liveness_timeout_remains_unknown_and_blocks_duplicate_request(self):
        identifier = self.enqueue('stage', ['upstream'])['requestId']
        path = self.engine.state / 'request-status' / (identifier + '.json')
        atomic(path, read(path) | {'createdAt': 0, 'state': 'running'})
        with patch('cybexos.cli.subprocess.run', side_effect=subprocess.TimeoutExpired('systemctl', 10)):
            self.assertEqual(cli.request_status(identifier, self.engine.state)['state'], 'unknown')
            with self.assertRaisesRegex(Failure, 'already running'):
                cli.enqueue_update(self.engine.state, 'stage', ['both'])

    def test_unexpected_worker_errors_never_publish_private_diagnostics(self):
        identifier = self.enqueue('stage', ['upstream'])['requestId']
        with patch.object(self.engine, 'stage', side_effect=RuntimeError('TOP SECRET')):
            with self.assertRaises(RuntimeError): cli.run_update(self.engine, identifier)
        self.assertNotIn('TOP SECRET', json.dumps(self.status()))
        self.assertIn('private system service log', self.status()['request']['error'])

    def test_new_transaction_clears_old_review_and_recovery_fields(self):
        self.engine.status(transaction='a' * 32, state='ready', notes='old notes', changes='old changes',
                           reviewToken='b' * 64, recovery='old recovery', restart='old restart')
        result = self.engine.status(transaction='c' * 32, state='discovering', phase='Checking sources')
        for key in ('notes', 'changes', 'recovery', 'restart'):
            self.assertEqual(result[key], '')
        self.assertIsNone(result['reviewToken'])
        self.assertEqual(result['packageChanges'], [])
        self.assertEqual(result['phase'], 'Checking sources')

    def test_discard_is_explicit_and_cannot_affect_a_pending_generation(self):
        candidate = self.engine.stage('upstream')
        with self.assertRaises(Failure): self.engine.discard('f' * 32)
        atomic(self.engine.pending_path, {'id': candidate['id']})
        with self.assertRaises(Failure): self.engine.discard(candidate['id'])
        self.engine.pending_path.unlink()
        self.engine.discard(candidate['id'])
        result = read(self.engine.status_path)
        self.assertEqual(result['state'], 'idle')
        self.assertIsNone(result['reviewToken'])
        self.assertIsNone(result['transaction'])
        self.assertTrue((self.engine.tx(candidate['id']) / 'deployment.json').exists())

    def test_bad_lock_reports_unknown_sources_without_network_or_mutation(self):
        atomic(self.config / 'flake.lock', {})
        before = (self.config / 'flake.lock').read_bytes()
        result = self.engine.check()
        self.assertEqual(result['upstream']['state'], 'unavailable')
        self.assertEqual(result['cybexos']['state'], 'unavailable')
        self.assertIn('configuration', result['error'])
        self.assertEqual(self.runner.calls, [])
        self.assertEqual((self.config / 'flake.lock').read_bytes(), before)

    def test_invalid_request_arguments_never_reach_systemd(self):
        for action, values in [('stage', ['latest']), ('apply', ['a' * 32, 'wrong']),
                               ('discard', ['../escape']), ('confirm', ['unexpected']),
                               ('rollback', ['a' * 32, 'b' * 32])]:
            with self.subTest(action=action), patch('cybexos.cli.subprocess.run') as run:
                with self.assertRaises(Failure): cli.enqueue_update(self.engine.state, action, values)
                run.assert_not_called()


class PackageReview(unittest.TestCase):
    def package(self, name, version, key):
        return {'name': name, 'version': version, 'path': '/nix/store/' + key * 32 + '-' + name}

    def compare(self, before, after):
        return review.compare(json.dumps({'schema': 1, 'packages': before}),
                              json.dumps({'schema': 1, 'packages': after}))

    def test_add_remove_update_rebuild_and_unchanged_packages(self):
        before = [self.package('app', '1', 'a'), self.package('library', '1', 'b'),
                  self.package('removed', '2', 'c'), self.package('unchanged', '1', 'd')]
        after = [self.package('app', '2', 'e'), self.package('library', '1', 'f'),
                 self.package('added', '3', 'g'), self.package('unchanged', '1', 'd')]
        result = self.compare(before, after)
        self.assertEqual({row['name']: row['kind'] for row in result},
                         {'app': 'updated', 'library': 'rebuilt', 'removed': 'removed', 'added': 'added'})
        self.assertNotEqual(review.identity(result), review.identity(result[:-1]))

    def test_multiple_versions_do_not_hide_a_changed_output(self):
        old = [self.package('python', '3.12', 'a'), self.package('python', '3.13', 'b')]
        new = [self.package('python', '3.12', 'a'), self.package('python', '3.14', 'c')]
        result = self.compare(old, new)
        self.assertEqual(len(result), 1)
        self.assertEqual((result[0]['before'], result[0]['after']), ('3.13', '3.14'))

    def test_missing_malformed_inventory_cannot_claim_an_empty_plan(self):
        for value in ('{}', '{"schema":2,"packages":[]}', '{"schema":1,"packages":[{"name":"x"}]}'):
            with self.subTest(value=value), self.assertRaises(Failure):
                review.compare(value, '{"schema":1,"packages":[]}')
