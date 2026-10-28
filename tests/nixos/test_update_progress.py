"""Nix protocol, process-stream isolation and staged updater observations."""
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lifecycle'))
from cybexos.common import CommandFailure, Runner, read
from cybexos.progress import NixProgress, log_line
import test_lifecycle as lifecycle


def event(action, identifier=1, **values):
    return b'@nix ' + json.dumps(dict(action=action, id=identifier, **values)).encode() + b'\n'


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.records = []
        self.now = 0
        self.monitor = NixProgress(self.records.append, clock=lambda: self.now)

    def feed(self, action, identifier=1, **values):
        self.monitor.feed(event(action, identifier, **values))

    def test_concurrent_transfers_and_builds_use_bytes_and_aggregate_counters(self):
        self.feed('start', 1, type=102)
        self.feed('result', 1, type=106, fields=[101, 1000])
        self.feed('start', 2, type=104)
        self.feed('result', 2, type=105, fields=[3, 8, 2, 0])
        for identifier in (3, 4):
            self.feed('start', identifier, type=101, text='https://private-cache/?token=SECRET')
            self.feed('result', identifier, type=105, fields=[100, 200, 0, 0])
        self.feed('start', 5, type=105, fields=['/nix/store/' + 'a' * 32 + '-hyprland-0.56.2.drv'])
        self.feed('start', 6, type=100)  # Unpacked bytes must not count twice.
        self.feed('result', 6, type=105, fields=[5000, 8000, 0, 0])
        value = self.monitor.snapshot()
        self.assertEqual(value['downloads'], {'doneBytes': 200, 'expectedBytes': 1000, 'active': 2, 'totalKnown': True})
        self.assertEqual(value['builds'], {'done': 3, 'expected': 8, 'active': 2, 'failed': 0})
        self.assertEqual(value['step'], 'building')
        self.assertEqual(value['components'], ['window-manager'])
        self.assertNotIn('SECRET', json.dumps(value))
        self.feed('stop', 3)
        self.assertEqual(self.monitor.snapshot()['downloads']['doneBytes'], 200)
        self.feed('result', 2, type=105, fields=[4, 9, 0, 1])
        self.feed('stop', 5)
        self.monitor.close()
        final = self.records[-1]
        self.assertFalse(final['active'])
        self.assertEqual(final['builds'], {'done': 4, 'expected': 9, 'active': 0, 'failed': 1})
        self.assertEqual(final['downloads']['doneBytes'], 200)

    def test_stopped_builds_do_not_fabricate_success_or_leak_names(self):
        self.feed('start', type=105, fields=['/nix/store/' + 'a' * 32 + '-personal-secret.drv'])
        self.feed('result', type=104, fields=['private compiler phase'])
        self.assertEqual(self.monitor.snapshot()['components'], ['system-component'])
        self.feed('stop')
        self.assertEqual(self.monitor.snapshot()['builds']['done'], 0)
        self.assertNotIn('secret', json.dumps(self.monitor.snapshot()))

    def test_fragmented_lines_invalid_events_and_missing_final_newline(self):
        data = event('start', type=101) + event('result', type=105, fields=[30, 90, 0, 0]).rstrip(b'\n')
        for byte in data:
            self.monitor.feed(bytes([byte]))
        self.monitor.close()
        self.assertEqual(self.records[-1]['downloads']['doneBytes'], 30)
        for data in (b'@nix [1]\n', b'@nix {\n', b'@nix {"id":true,"action":"start","type":101}\n',
                     event('start', type=101, fields={}), event('result', type=105, fields=[True, -1, 0, 0]),
                     event('start', identifier=2**65, type=101)):
            self.monitor.feed(data)
        self.assertEqual(self.monitor.snapshot()['downloads']['doneBytes'], 30)

    def test_unknown_totals_remain_unknown_and_buffers_are_bounded(self):
        self.monitor.feed(b'x' * (self.monitor.MAX_LINE * 2))
        self.assertLessEqual(len(self.monitor.buffer), self.monitor.MAX_LINE)
        self.monitor.feed(b'\n' + event('start', type=101))
        self.assertFalse(self.monitor.snapshot()['downloads']['totalKnown'])
        for identifier in range(2, self.monitor.MAX_ACTIVITIES + 10):
            self.feed('start', identifier, type=101)
        self.assertEqual(len(self.monitor.activities), self.monitor.MAX_ACTIVITIES)

    def test_publications_are_throttled_but_finish_flushes(self):
        for i in range(10):
            self.feed('start', i, type=101)
        self.assertEqual(len(self.records), 1)
        self.now = 1
        self.feed('result', 1, type=105, fields=[20, 100, 0, 0])
        self.assertEqual(len(self.records), 2)
        self.monitor.close()
        self.assertEqual(len(self.records), 3)

    def test_real_runner_flushes_activity_during_a_silent_command(self):
        runner = Runner()
        runner.observer = self.monitor.feed
        self.monitor.clock = time.monotonic
        self.monitor.last_publish = self.monitor.clock()
        data = repr(event('start', type=105, fields=['private.drv']))
        runner(sys.executable, '-c', 'import os,time; os.write(2,' + data + '); time.sleep(1.3)')
        self.assertTrue(any(value['builds']['active'] == 1 for value in self.records))

    def test_private_log_reader_keeps_diagnostics_human_readable(self):
        self.assertEqual(log_line(event('result', type=101, fields=['compiler output']).decode()), 'compiler output\n')
        self.assertEqual(log_line(event('result', type=105, fields=[1, 2, 0, 0]).decode()), '')
        self.assertEqual(log_line('plain diagnostics\n'), 'plain diagnostics\n')

    def test_real_runner_observes_only_non_sensitive_stderr_and_preserves_json_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = Runner(Path(directory) / 'private.log')
            chunks = []
            runner.observer = chunks.append
            script = 'import os; os.write(1,b\'{"outputs":[]}\'); os.write(2,b"private stderr\\n")'
            self.assertEqual(runner(sys.executable, '-c', script), '{"outputs":[]}')
            self.assertEqual(b''.join(chunks), b'private stderr\n')
            self.assertIn('private stderr', runner.log.read_text())
            chunks.clear()
            before = runner.log.read_bytes()
            runner(sys.executable, '-c', script, sensitive=True)
            self.assertEqual(chunks, [])
            self.assertEqual(runner.log.read_bytes(), before)
            def broken(data):
                raise ValueError('unsupported observer')
            runner.observer = broken
            self.assertEqual(runner(sys.executable, '-c', script), '{"outputs":[]}')
            with self.assertRaises(CommandFailure):
                runner(sys.executable, '-c', 'raise SystemExit(7)')


class StagedProgressTests(unittest.TestCase):
    setUp = lifecycle.EngineTests.setUp

    def test_actual_engine_stage_publishes_events_and_clears_finished_activity(self):
        original = self.engine.run
        snapshots = []
        def run(*args, **kwargs):
            if args[:2] == ('nix', 'build'):
                self.assertIn('internal-json', args)
                run.observer.__self__.last_publish = float('-inf')
                run.observer(event('start', type=105, fields=['private.drv']))
                snapshots.append(read(self.engine.status_path))
            return original(*args, **kwargs)
        self.engine.run = run
        self.engine.stage('upstream')
        self.assertEqual(snapshots[0]['state'], 'building')
        self.assertEqual(snapshots[0]['progress']['schema'], 1)
        self.assertEqual(snapshots[0]['progress']['builds']['active'], 1)
        self.assertIsNone(run.observer)
        ready = read(self.engine.status_path)
        self.assertEqual(ready['state'], 'ready')
        self.assertIsNone(ready['progress'])
        self.assertGreaterEqual(ready['finishedAt'], ready['operationStartedAt'])

    def test_nix_observer_restored_even_on_command_and_close_failure(self):
        original = self.engine.run
        old_observer = lambda data: None
        original.observer = old_observer
        original.fail = lambda args: args[:2] == ('nix', 'build')
        with patch('cybexos.progress.NixProgress.close', side_effect=RuntimeError('telemetry')):
            with self.assertRaisesRegex(Exception, 'injected command failure'):
                self.engine.stage('upstream')
        self.assertIs(original.observer, old_observer)
        self.assertIsNone(read(self.engine.status_path)['progress'])


if __name__ == '__main__':
    unittest.main()
