"""Software request tests through the actual staged engine, with command fixtures."""
import json
from pathlib import Path
import shutil
import unittest

import test_lifecycle as lifecycle
from cybexos.common import Failure, atomic, read
from cybexos.engine import config_digest, copy_config
from cybexos import software


class SoftwareTests(unittest.TestCase):
    setUp = lifecycle.EngineTests.setUp

    def prepare_machine(self):
        atomic(self.config / 'local/software.json', {'schema':1, 'packages':[]})
        shutil.rmtree(self.base / 'deployed')
        copy_config(self.config, self.base / 'deployed')

    def test_staged_install_apply_and_rollback_preserve_personal_configuration_and_locks(self):
        self.prepare_machine()
        baseline = config_digest(self.working)
        locked = (self.config / 'flake.lock').read_bytes()
        record = self.engine.stage('local', software={'packages':['hello'], 'previous':[]}, request_id='c' * 32)
        self.assertEqual(config_digest(self.working), baseline)
        self.assertEqual(read(self.engine.tx(record['id']) / 'config/local/software.json')['packages'], ['hello'])
        self.assertEqual((self.engine.tx(record['id']) / 'config/flake.lock').read_bytes(), locked)
        self.assertFalse(any(call[:3] == ('nix', 'flake', 'update') for call in self.runner.calls))
        self.assertEqual(record['requestId'], 'c' * 32)
        self.engine.apply(record['id'], record['reviewToken'])
        self.assertEqual(read(self.working / 'local/software.json')['packages'], ['hello'])
        self.assertEqual((self.working / 'local/personal.nix').read_text(), '# packages, VPN, services sentinel\n{}')
        self.engine.rollback(record['id'])
        self.assertEqual(read(self.working / 'local/software.json')['packages'], [])
        self.assertEqual((self.working / 'flake.lock').read_bytes(), locked)

    def test_stale_choices_unknown_schemas_and_expression_injection_are_rejected(self):
        self.prepare_machine()
        baseline = config_digest(self.working)
        for value in ['hello; import /tmp/evil', 'a..b', '../hello', '"hello"', 'a/${builtins.abort "oops"}']:
            with self.subTest(value=value), self.assertRaises(Failure):
                self.engine.stage('local', software={'packages':[value], 'previous':[]})
        with self.assertRaises(Failure):
            self.engine.stage('local', software={'packages':['hello'], 'previous':['git']})
        self.assertEqual(config_digest(self.working), baseline)
        atomic(self.config / 'local/software.json', {'schema':2, 'packages':[]})
        with self.assertRaises(Failure): software.prepare(self.config, {'packages':[], 'previous':[]})

    def test_catalogue_uses_effective_machine_packages_offline_and_invalidates_on_personal_edits(self):
        self.prepare_machine()
        installed = self.base / 'inventory.json'
        atomic(installed, {'schema':1, 'selected':[], 'packages':[]})
        calls = []
        def run(*args, **kwargs):
            calls.append(args)
            return json.dumps([{'attribute':'hello', 'name':'hello', 'version':'1', 'description':'A friendly application'},
                               {'attribute':'python3Packages.foo', 'name':'foo', 'version':'2', 'description':'Python tool'}])
        args = dict(config=self.working, installed=installed, cache=self.base / 'cache', run=run)
        found = software.search('friendly', **args)
        self.assertEqual([p['attribute'] for p in found['results']], ['hello'])
        software.search('python', **args)
        self.assertEqual(len(calls), 1)
        self.assertIn('--offline', calls[0]); self.assertIn('--no-update-lock-file', calls[0])
        self.assertIn('software-catalogue.nix', calls[0][-1])
        (self.config / 'local/personal.nix').write_text('# personal overlay changed\n{}')
        software.search('hello', **args)
        self.assertEqual(len(calls), 2)

    def test_catalogue_refuses_a_configuration_changed_during_indexing(self):
        self.prepare_machine()
        def run(*args, **kwargs):
            (self.config / 'local/personal.nix').write_text('changed')
            return '[]'
        with self.assertRaisesRegex(Failure, 'changed while indexing'):
            software.search(config=self.config, cache=self.base / 'cache', run=run)

    def test_supervised_requests_keep_distinct_payloads_and_report_worker_crashes(self):
        from unittest.mock import patch
        from types import SimpleNamespace
        from cybexos.cli import enqueue, request_status
        state = self.base / 'requests-state'
        with patch('cybexos.cli.subprocess.run'):
            one = enqueue(state, 'software', {'packages':['hello'], 'previous':[]})
            two = enqueue(state, 'software', {'packages':['git'], 'previous':[]})
        self.assertNotEqual(one['requestId'], two['requestId'])
        self.assertEqual(read(state / 'requests' / (one['requestId'] + '.json'))['packages'], ['hello'])
        path = state / 'request-status' / (one['requestId'] + '.json')
        atomic(path, read(path) | {'createdAt':0, 'state':'running'})
        result = SimpleNamespace(returncode=0, stdout='ActiveState=failed\nResult=signal\n')
        with patch('cybexos.cli.subprocess.run', return_value=result):
            self.assertEqual(request_status(one['requestId'], state)['state'], 'failed')
        with self.assertRaises(Failure): request_status('../secret', state)
