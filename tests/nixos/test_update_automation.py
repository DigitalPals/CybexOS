"""Readable update summaries and background preparation/confirmation.

Real review, policy and request code with isolated files, a fake system
manager and fake discovery. Not installation qualification.
"""
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import test_lifecycle as lifecycle
from cybexos import automatic, cli, review
from cybexos.common import Failure, atomic, read
from cybexos.engine import config_digest


def change(name, kind, before, after, path='x'):
    store = '/nix/store/' + path * 32 + '-' + name
    return {'name': name, 'kind': kind, 'before': before, 'after': after,
            'oldPath': None if kind == 'added' else store, 'newPath': None if kind == 'removed' else store,
            'description': ''}


class Highlights(unittest.TestCase):
    def test_components_apps_tools_and_background_are_grouped_for_people(self):
        apps = {'firefox': {'title': 'Firefox', 'icon': 'firefox'}, 'obs-studio': {'title': 'OBS Studio', 'icon': 'com.obsproject.Studio'}}
        entry = lambda path: next((value for name, value in apps.items() if path.endswith('-' + name)), None)
        changes = [change('firefox', 'updated', '143.0.4', '144.0.1'), change('git', 'updated', '2.51.0', '2.52.0'),
                   change('obs-studio', 'added', None, '32.0'), change('hello', 'rebuilt', '1', '1')]
        diff = ('\x1b[1mfirefox\x1b[0m: 143.0.4 → 144.0.1, +2048.0 KiB\n'
                'git: 2.51.0 → 2.52.0, -1.0 MiB\nlinux: 6.12.55 → 6.12.58, +1.0 MiB\n'
                'openssl: 3.5.2 → 3.5.4\nglibc: +12.0 KiB\nobs-studio: ∅ → 32.0, +1.0 MiB\nnot a closure line\n')
        before = {'kernel': '6.12.55', 'nixos': '26.05.20261024.abcdef1', 'cybexos': '1.0.0-beta.9'}
        after = {'kernel': '6.12.58', 'nixos': '26.05.20261027.1234567', 'cybexos': '1.0.0-beta.9', 'nvidia': '580.95'}
        result = review.highlights(changes, before, after, diff, entry)
        self.assertEqual([row['id'] for row in result['components']], ['nixos', 'kernel', 'nvidia'])
        self.assertEqual(result['components'][1], {'id': 'kernel', 'before': '6.12.55', 'after': '6.12.58'})
        self.assertEqual(result['components'][2], {'id': 'nvidia', 'before': None, 'after': '580.95'})
        self.assertEqual([(app['title'], app['kind']) for app in result['apps']], [('Firefox', 'updated'), ('OBS Studio', 'added')])
        self.assertEqual(result['tools'], [{'name': 'git', 'kind': 'updated', 'before': '2.51.0', 'after': '2.52.0'}])
        # firefox, git, obs-studio and linux are shown; openssl and glibc are counted.
        self.assertEqual(result['background'], 2)
        self.assertEqual(result['sizeChange'], (2048 + 12) * 1024 + 1024 ** 2)
        self.assertNotIn('rebuilt', json.dumps(result))
        self.assertNotIn('/nix/store', json.dumps(result))

    def test_a_system_without_a_manifest_lists_no_components(self):
        result = review.highlights([], {}, {'kernel': '6.12.58'}, '', lambda path: None)
        self.assertEqual(result['components'], [])
        for body in ('', '[]', json.dumps({'schema': 2, 'components': {}}),
                     json.dumps({'schema': 1, 'components': {'kernel': 6, 'unknown': '1', 'nixos': ''}})):
            self.assertEqual(review.components(body), {})
        self.assertEqual(review.components(json.dumps({'schema': 1, 'components': {'kernel': '6.12.58'}})),
                         {'kernel': '6.12.58'})

    def test_desktop_entries_identify_visible_applications_only(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, body in (('app', '[Desktop Entry]\nType=Application\nName=Firefox\nName[nl]=Firefox NL\nIcon=firefox\n'
                                       '[Desktop Action new]\nName=New Window\n'),
                               ('hidden', '[Desktop Entry]\nType=Application\nName=Helper\nNoDisplay=true\n'),
                               ('link', '[Desktop Entry]\nType=Link\nName=Site\n')):
                directory = root / name / 'share/applications'
                directory.mkdir(parents=True)
                (directory / (name + '.desktop')).write_text(body)
            self.assertEqual(review.desktop_entry(root / 'app'), {'title': 'Firefox', 'icon': 'firefox'})
            self.assertIsNone(review.desktop_entry(root / 'hidden'))
            self.assertIsNone(review.desktop_entry(root / 'link'))
            self.assertIsNone(review.desktop_entry(root / 'missing'))

    def test_staged_review_publishes_highlights_and_binds_them_to_the_token(self):
        engine = lifecycle.EngineTests()
        engine.setUp()
        try:
            record = engine.engine.stage('upstream')
            status = read(engine.engine.status_path)
            self.assertEqual(status['highlights'], record['highlights'])
            self.assertEqual(status['highlights']['components'],
                             [{'id': 'kernel', 'before': '6.12.55', 'after': '6.12.58'}])
            self.assertEqual(status['highlights']['tools'][0]['name'], 'hello')
            import hashlib
            changes = 'hello: 1 → 2\n'
            expected = hashlib.sha256((record['configDigest'] + changes + review.identity(record['packageChanges'])
                                       + review.identity(record['highlights'])).encode()).hexdigest()
            self.assertEqual(record['reviewToken'], expected)
            # A new transaction must not inherit an earlier review summary.
            fresh = engine.engine.status(transaction='c' * 32, state='discovering')
            self.assertIsNone(fresh['highlights'])
        finally:
            engine.doCleanups()


class Automation(unittest.TestCase):
    setUp = lifecycle.EngineTests.setUp

    def discovery(self, upstream='available', cybexos='unpublished'):
        return {'upstream': {'state': upstream, 'available': '2' * 40},
                'cybexos': {'state': cybexos, 'available': '1.1.0'}}

    def enqueue(self, state, action, values):
        with patch('cybexos.cli.subprocess.run'):
            return cli.enqueue_update(state, action, values)

    def finish(self, accepted, state='done'):
        path = self.engine.state / 'request-status' / (accepted['requestId'] + '.json')
        atomic(path, read(path) | {'state': state}, 0o644)

    def status(self):
        return cli.update_status(self.engine.state, self.working)

    def prepare(self, discovery=None, metered=False, now=1000.0):
        return automatic.prepare(self.engine, self.enqueue, self.status, config_digest,
                                 discover=lambda: discovery or self.discovery(),
                                 is_metered=lambda: metered, now=lambda: now)

    def test_policy_defaults_on_and_an_unreadable_choice_disables(self):
        state = self.engine.state
        self.assertEqual(automatic.policy(state), {'prepare': True, 'confirm': True})
        self.assertEqual(self.status()['automatic'], {'prepare': True, 'confirm': True})
        self.assertEqual(automatic.choose(state, 'prepare', False), {'prepare': False, 'confirm': True})
        self.assertEqual((state / automatic.POLICY).stat().st_mode & 0o777, 0o644)
        with self.assertRaises(Failure):
            automatic.choose(state, 'apply', True)
        (state / automatic.POLICY).write_text('{"prepare": "yes"}')
        self.assertEqual(automatic.policy(state), {'prepare': False, 'confirm': False})
        (state / automatic.POLICY).write_text('not json')
        self.assertEqual(automatic.policy(state), {'prepare': False, 'confirm': False})

    def test_preparation_submits_one_ordinary_stage_per_target(self):
        accepted = self.prepare(self.discovery(cybexos='available'))
        self.assertEqual(accepted['scope'], 'both')
        request = read(self.engine.state / 'requests' / (accepted['requestId'] + '.json'))
        self.assertEqual(request, {'action': 'stage', 'arguments': ['both']})
        self.assertEqual(self.prepare(self.discovery(cybexos='available')), {'skipped': 'request'})
        self.finish(accepted)
        # The person discarded or installed nothing new: never prepare it twice.
        self.assertEqual(self.prepare(self.discovery(cybexos='available')), {'skipped': 'prepared'})
        upstream_only = self.prepare(self.discovery())
        self.assertEqual(upstream_only['scope'], 'upstream')

    def test_preparation_waits_for_people_power_and_networks(self):
        self.assertEqual(self.prepare(self.discovery('current')), {'skipped': 'current'})
        self.assertEqual(self.prepare(metered=True), {'skipped': 'metered'})
        for state in ('ready', 'stale', 'building', 'awaiting-boot', 'awaiting-login', 'rolled-back',
                      'recovery-failed', 'failed'):
            atomic(self.engine.status_path, {'state': state})
            self.assertEqual(self.prepare(), {'skipped': state})
        atomic(self.engine.status_path, {'state': 'idle'})
        automatic.choose(self.engine.state, 'prepare', False)
        self.assertEqual(self.prepare(), {'skipped': 'disabled'})
        self.assertFalse(list((self.engine.state / 'requests').glob('*.json')))

    def test_an_own_failure_is_retried_for_a_new_target_or_after_a_day(self):
        accepted = self.prepare()
        self.finish(accepted, 'failed')
        atomic(self.engine.status_path, {'state': 'failed', 'requestId': accepted['requestId']})
        self.assertEqual(self.prepare(now=2000.0), {'skipped': 'prepared'})
        retried = self.prepare(now=1000.0 + automatic.RETRY_SECONDS)
        self.assertEqual(retried['scope'], 'upstream')
        self.finish(retried, 'failed')
        atomic(self.engine.status_path, {'state': 'failed', 'requestId': retried['requestId']})
        newer = self.discovery()
        newer['upstream']['available'] = '3' * 40
        self.assertEqual(self.prepare(newer, now=1000.0 + automatic.RETRY_SECONDS + 1)['scope'], 'upstream')

    def test_a_configuration_change_is_a_new_target(self):
        self.finish(self.prepare())
        (self.config / 'local/personal.nix').write_text('{ }')
        self.assertEqual(self.prepare()['scope'], 'upstream')

    def test_confirmation_is_requested_only_for_a_trial_boot(self):
        confirm = lambda: automatic.confirm(self.engine, self.enqueue, self.status)
        atomic(self.engine.status_path, {'state': 'awaiting-boot'})
        self.assertEqual(confirm(), {'skipped': 'awaiting-boot'})
        atomic(self.engine.status_path, {'state': 'awaiting-login'})
        automatic.choose(self.engine.state, 'confirm', False)
        self.assertEqual(confirm(), {'skipped': 'disabled'})
        automatic.choose(self.engine.state, 'confirm', True)
        accepted = confirm()
        self.assertEqual(read(self.engine.state / 'requests' / (accepted['requestId'] + '.json')),
                         {'action': 'confirm', 'arguments': []})
        self.assertEqual(confirm(), {'skipped': 'request'})

    def test_metered_reads_network_manager(self):
        class Result:
            def __init__(self, stdout, returncode=0):
                self.stdout, self.returncode = stdout, returncode
        for stdout, expected in (('u 1\n', True), ('u 3\n', True), ('u 2\n', False), ('u 4\n', False), ('', False)):
            self.assertEqual(automatic.metered(lambda *args, **kwargs: Result(stdout)), expected)
        self.assertFalse(automatic.metered(lambda *args, **kwargs: Result('u 1', 1)))
        def missing(*args, **kwargs):
            raise OSError('no busctl')
        self.assertFalse(automatic.metered(missing))

    def test_finished_failures_can_be_dismissed_without_touching_files(self):
        for state in ('failed', 'interrupted', 'rolled-back'):
            identifier = state[0] * 32 if state[0] in 'abcdef' else 'a' * 32
            self.engine.tx(identifier).mkdir(exist_ok=True)
            atomic(self.engine.status_path, {'state': state, 'transaction': identifier, 'error': 'private cause'})
            self.engine.discard(identifier)
            result = read(self.engine.status_path)
            self.assertEqual((result['state'], result['error'], result['transaction']), ('idle', '', None))
            self.assertTrue(self.engine.tx(identifier).is_dir())
        atomic(self.engine.status_path, {'state': 'recovery-failed', 'transaction': 'a' * 32})
        with self.assertRaises(Failure):
            self.engine.discard('a' * 32)
        atomic(self.engine.status_path, {'state': 'awaiting-boot', 'transaction': 'a' * 32})
        with self.assertRaises(Failure):
            self.engine.discard('a' * 32)


if __name__ == '__main__':
    unittest.main()
