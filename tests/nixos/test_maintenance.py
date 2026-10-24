"""Retention, review freshness and restartable cleanup command-boundary tests."""
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import test_lifecycle as lifecycle
from nerdos.common import Failure, atomic, locked, read
from nerdos.maintenance import DEFAULT_POLICY, Maintenance, policy, prepare


class MaintenanceTests(unittest.TestCase):
    setUp = lifecycle.EngineTests.setUp

    def setup_retention(self):
        self.now = 2000000000
        self.profiles = self.base / 'profiles'; self.profiles.mkdir()
        self.cleanup_policy = self.base / 'maintenance.json'; atomic(self.cleanup_policy, DEFAULT_POLICY)
        self.records = []
        for i in range(1, 11):
            identifier = f'{i:032x}'
            record = {'id':identifier, 'system':f'/nix/store/{i:032d}-system',
                      'previousSystem':f'/nix/store/{i-1:032d}-system', 'createdAt':self.now - (100 - i) * 86400}
            tx = self.engine.tx(identifier); tx.mkdir()
            atomic(tx / 'deployment.json', record); atomic(tx / 'good.json', {'at': record['createdAt']})
            roots = tx / 'roots'; roots.mkdir()
            (roots / 'system').symlink_to(record['system']); (roots / 'previous-system').symlink_to(record['previousSystem'])
            (tx / 'personal-before-rollback').mkdir(); (tx / 'personal-before-rollback/edits.nix').write_text('personal edits')
            (self.profiles / f'system-{i}-link').symlink_to(record['system'])
            self.records.append(record)
        self.system.unlink(); self.system.symlink_to(self.records[-1]['system'])
        self.booted.unlink(); self.booted.symlink_to(self.records[-1]['system'])
        (self.profiles / 'system').symlink_to(self.profiles / 'system-10-link')
        original = self.runner
        def run(*args, **kwargs):
            args = tuple(map(str, args)); original.calls.append(args)
            if args[:3] == ('nix-store', '--gc', '--print-roots'):
                roots = [f'{p} -> {p.resolve()}' for p in self.profiles.glob('system-*-link') if p.is_symlink()]
                roots += [f'{p} -> {p.resolve()}' for p in (self.engine.state / 'transactions').glob('*/roots/*') if p.is_symlink()]
                return '\n'.join(roots)
            if args[:3] == ('nix-store', '--query', '--requisites'):
                return '\n'.join([*args[3:], '/nix/store/' + 'f'*32 + '-shared'])
            if args[:2] == ('nix', 'path-info'):
                return json.dumps({p:{'narSize':100} for p in args[3:]})
            if args[:3] == ('nix-store', '--gc', '--print-dead'): return ''
            if args[:3] == ('nix-env', '--profile', str(self.profiles / 'system')):
                (self.profiles / f'system-{args[-1]}-link').unlink()
            return ''
        run.log = None
        self.engine.run = run
        self.maintenance = Maintenance(self.engine, self.cleanup_policy, self.profiles, store=self.base, now=self.now)

    def test_retention_and_pins_protect_system_fallback_sources_and_personal_edits(self):
        self.setup_retention()
        self.maintenance.pin(self.records[0]['id'], True)
        plan = self.maintenance.preview()
        self.assertEqual(plan['candidates'], [r['id'] for r in self.records[1:5]])
        self.assertNotIn('5', plan['generations']) # predecessor of the oldest kept deployment
        self.maintenance.clean(plan['id'], plan['token'])
        self.assertEqual(read(self.engine.state / 'maintenance-status.json')['state'], 'done')
        for record in self.records:
            tx = self.engine.tx(record['id'])
            self.assertEqual((tx / 'personal-before-rollback/edits.nix').read_text(), 'personal edits')
            self.assertTrue((tx / 'deployment.json').exists())
            self.assertEqual((tx / 'retired.json').exists(), record['id'] in plan['candidates'])
        with self.assertRaisesRegex(Failure, 'retired'):
            self.engine.rollback(plan['candidates'][0])
        self.assertTrue((self.profiles / 'system-10-link').is_symlink())

    def test_preview_is_invalidated_by_pin_or_new_deployment(self):
        self.setup_retention()
        plan = self.maintenance.preview()
        self.maintenance.pin(self.records[0]['id'], True)
        with self.assertRaisesRegex(Failure, 'stale'): self.maintenance.clean(plan['id'], plan['token'])
        self.assertFalse(self.maintenance.pending.exists())

    def test_pending_updates_unknown_roots_and_unconfirmed_boot_fail_closed(self):
        self.setup_retention()
        atomic(self.engine.pending_path, {'phase':'boot'})
        with self.assertRaises(Failure): self.maintenance.preview()
        self.engine.pending_path.unlink()
        atomic(self.engine.status_path, {'state':'ready'})
        with self.assertRaises(Failure): self.maintenance.preview()
        atomic(self.engine.status_path, {'state':'done'})
        unexpected = self.engine.tx(self.records[0]['id']) / 'roots/unknown'
        unexpected.write_text('not a managed GC root')
        with self.assertRaisesRegex(Failure, 'unknown GC reference'): self.maintenance.preview()
        unexpected.unlink()
        self.booted.unlink(); self.booted.symlink_to('/nix/store/' + 'a'*32 + '-other')
        with self.assertRaisesRegex(Failure, 'confirmed system boot'): self.maintenance.preview()

    def test_interrupted_cleanup_resumes_before_gc_and_keeps_journal_until_success(self):
        self.setup_retention()
        plan = self.maintenance.preview()
        original = self.engine.run
        failed = False
        def run(*args, **kwargs):
            nonlocal failed
            if args[:2] == ('nix-store', '--gc') and len(args) == 2 and not failed:
                failed = True; raise Failure('injected GC interruption')
            return original(*args, **kwargs)
        run.log = None; self.engine.run = run
        with self.assertRaisesRegex(Failure, 'interruption'): self.maintenance.clean(plan['id'], plan['token'])
        self.assertEqual(read(self.maintenance.pending)['phase'], 'gc')
        with self.assertRaisesRegex(Failure, 'cleanup awaits recovery'): self.engine.stage('local')
        with locked(self.engine.state / 'operation.lock'): self.maintenance.resume()
        self.assertFalse(self.maintenance.pending.exists())
        calls = self.runner.calls
        boot = next(i for i,c in enumerate(calls) if c[0].endswith('/bin/switch-to-configuration'))
        gc = next(i for i,c in enumerate(calls) if c == ('nix-store', '--gc'))
        self.assertLess(boot, gc)

    def test_automatic_cleanup_obeys_opt_out_busy_lock_and_pending_recovery(self):
        self.setup_retention()
        atomic(self.cleanup_policy, DEFAULT_POLICY | {'automatic':False})
        self.maintenance.clean(automatic=True)
        self.assertFalse(any((self.engine.tx(r['id']) / 'retired.json').exists() for r in self.records))
        atomic(self.cleanup_policy, DEFAULT_POLICY)
        with locked(self.engine.state / 'operation.lock'): self.maintenance.clean(automatic=True)
        self.assertFalse(self.maintenance.pending.exists())
        atomic(self.engine.pending_path, {'phase':'recovery'})
        self.maintenance.clean(automatic=True)
        self.assertEqual(read(self.engine.state / 'maintenance-status.json')['state'], 'skipped')
        self.engine.pending_path.unlink()
        self.maintenance.clean(automatic=True)
        self.assertEqual(read(self.engine.state / 'maintenance-status.json')['state'], 'done')
        for record in self.records:
            self.assertEqual((self.engine.tx(record['id']) / 'retired.json').exists(),
                             record['id'] in {r['id'] for r in self.records[:5]})
        self.assertTrue((self.profiles / 'system-10-link').is_symlink())
        self.assertIn(('nix-store', '--gc'), self.runner.calls)

    def test_future_schemas_and_unsafe_retention_are_rejected_without_modifying_personal_data(self):
        for value in [DEFAULT_POLICY | {'keepConfirmed':4}, DEFAULT_POLICY | {'keepDays':1}, DEFAULT_POLICY | {'automatic':1}]:
            with self.assertRaises(Failure): policy(value)
        atomic(self.config / 'local/maintenance.json', {'schema':2, 'policy':DEFAULT_POLICY})
        with self.assertRaises(Failure): prepare(self.config, {'previous':DEFAULT_POLICY, 'policy':DEFAULT_POLICY})

    def test_gc_still_runs_when_all_recovery_points_are_protected(self):
        self.setup_retention()
        atomic(self.cleanup_policy, DEFAULT_POLICY | {'keepConfirmed':100})
        plan = self.maintenance.preview()
        self.assertEqual(plan['candidates'], [])
        self.maintenance.clean(plan['id'], plan['token'])
        self.assertIn(('nix-store', '--gc'), self.runner.calls)
        self.assertFalse(any(call[0].endswith('/bin/switch-to-configuration') for call in self.runner.calls))
        self.assertTrue(all((self.engine.tx(r['id']) / 'roots/system').is_symlink() for r in self.records))

    def test_unhealthy_system_blocks_manual_and_skips_automatic_cleanup(self):
        self.setup_retention()
        original = self.engine.run
        def run(*args, **kwargs):
            if args[0] == 'nerdos-health': raise Failure('A required hardware service failed')
            return original(*args, **kwargs)
        run.log = None; self.engine.run = run
        with self.assertRaisesRegex(Failure, 'hardware'): self.maintenance.preview()
        self.maintenance.clean(automatic=True)
        self.assertEqual(read(self.engine.state / 'maintenance-status.json')['state'], 'skipped')
        self.assertFalse(self.maintenance.pending.exists())

    def test_first_install_can_collect_garbage_without_retiring_any_recovery_references(self):
        self.setup_retention()
        for record in self.records: (self.engine.tx(record['id']) / 'good.json').unlink()
        plan = self.maintenance.preview()
        self.assertEqual(plan['candidates'], [])
        self.assertEqual(plan['generations'], {})
        self.maintenance.clean(plan['id'], plan['token'])
        self.assertIn(('nix-store', '--gc'), self.runner.calls)
        self.assertTrue(all((self.engine.tx(r['id']) / 'roots/system').is_symlink() for r in self.records))
        self.maintenance.clean(automatic=True)
        self.assertEqual(read(self.engine.state / 'maintenance-status.json')['state'], 'skipped')

    def test_failed_build_can_collect_garbage_and_retains_the_failed_transaction(self):
        self.setup_retention()
        failed = self.engine.tx('f'*32); failed.mkdir()
        (failed / 'roots').mkdir()
        (failed / 'roots/source').symlink_to(self.records[0]['system'])
        atomic(self.engine.status_path, {'state':'failed', 'transaction':failed.name})
        plan = self.maintenance.preview()
        entry = next(d for d in plan['deployments'] if d['id'] == failed.name)
        self.assertFalse(entry['eligible'])
        self.maintenance.clean(plan['id'], plan['token'])
        self.assertTrue((failed / 'roots/source').is_symlink())
        self.assertIn(('nix-store', '--gc'), self.runner.calls)

    def test_status_distinguishes_personal_preferences_from_effective_cleanup_policy(self):
        from nerdos.maintenance import public_status
        self.setup_retention()
        desired = DEFAULT_POLICY | {'keepDays':90}
        atomic(self.config / 'local/maintenance.json', {'schema':1, 'policy':desired})
        atomic(self.engine.state / 'maintenance-status.json', {'policy':DEFAULT_POLICY | {'keepDays':60}})
        result = public_status(self.engine.state, self.cleanup_policy, self.base, self.config)
        self.assertEqual(result['policy'], DEFAULT_POLICY)
        self.assertEqual(result['desiredPolicy'], desired)
        self.assertTrue(result['configurationChanged'])
        self.assertFalse(result['configurationError'])
        (self.config / 'local/maintenance.json').write_text('invalid JSON')
        result = public_status(self.engine.state, self.cleanup_policy, self.base, self.config)
        self.assertTrue(result['configurationError'])
        self.assertEqual(result['policy'], DEFAULT_POLICY)

    def test_stopped_workers_release_the_ui_and_expose_durable_cleanup_recovery(self):
        from nerdos.maintenance import public_status
        from subprocess import CompletedProcess
        self.setup_retention()
        atomic(self.config / 'local/maintenance.json', {'schema':1, 'policy':DEFAULT_POLICY})
        for identifier, recovery in (('a'*32, False), (None, False), (None, True)):
            with self.subTest(requestId=identifier, recovery=recovery):
                atomic(self.engine.state / 'maintenance-status.json',
                       {'state':'cleaning', 'requestId':identifier, 'reviewToken':'stale',
                        'workerUnit':'nerdos-recover.service' if recovery else None})
                atomic(self.maintenance.pending, {'phase':'gc'})
                with patch('nerdos.maintenance.subprocess.run', return_value=CompletedProcess([], 0, 'ActiveState=failed\n')) as worker:
                    result = public_status(self.engine.state, self.cleanup_policy, self.base, self.config)
                self.assertEqual(result['state'], 'failed')
                self.assertTrue(result['recoveryPending'])
                self.assertIsNone(result['reviewToken'])
                expected = ('nerdos-recover.service' if recovery else
                            f'nerdos-maintenance@{identifier}.service' if identifier else 'nerdos-maintenance-auto.service')
                self.assertIn(expected, worker.call_args.args[0])
                with patch('nerdos.maintenance.subprocess.run', return_value=CompletedProcess([], 0, 'ActiveState=activating\n')):
                    active = public_status(self.engine.state, self.cleanup_policy, self.base, self.config)
                self.assertEqual(active['state'], 'cleaning')
