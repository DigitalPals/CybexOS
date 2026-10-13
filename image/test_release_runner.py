"""No runner registration or listening occurs in these source fixtures."""
import hashlib
import io
import os
from pathlib import Path
import signal
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import release_runner as runner

HEAD = 'a' * 40
RUN_ID = 1234
LABEL = f'cybexos-iso-{RUN_ID}'
RUN = {'id': RUN_ID, 'repository': {'full_name': runner.REPOSITORY},
       'head_repository': {'full_name': runner.REPOSITORY},
       'event': 'push', 'path': '.github/workflows/release.yml',
       'head_sha': HEAD, 'head_branch': 'v1.2.3', 'pull_requests': [], 'status': 'in_progress'}
JOB = {'id': 5678, 'run_id': RUN_ID, 'head_sha': HEAD, 'labels': [LABEL], 'status': 'queued'}
DOWNLOAD = {'os': 'linux', 'architecture': 'x64', 'sha256_checksum': 'b' * 64,
            'download_url': 'https://github.com/actions/runner/releases/download/v2.333.0/actions-runner-linux-x64-2.333.0.tar.gz'}


class ReviewedIdentity(unittest.TestCase):
    def test_exact_reviewed_main_and_version_tag_are_allowed(self):
        for branch in ('main', 'v1.2.3', 'v1.2.3-rc.1'):
            self.assertEqual(runner.validate_run({**RUN, 'head_branch': branch}, HEAD)['head_sha'], HEAD)
        self.assertEqual(runner.validate_job([JOB], RUN_ID, HEAD)['id'], JOB['id'])

    def test_wrong_source_workflow_pr_and_finished_runs_are_rejected(self):
        cases = ({'head_sha': 'c' * 40}, {'event': 'pull_request'},
                 {'head_repository': {'full_name': 'attacker/CybexOS'}},
                 {'repository': {'full_name': 'attacker/CybexOS'}},
                 {'path': '.github/workflows/tests.yml'}, {'head_branch': 'unreviewed'},
                 {'pull_requests': [{'number': 12}]}, {'status': 'completed'})
        for values in cases:
            with self.subTest(values=values), self.assertRaises(ValueError):
                runner.validate_run({**RUN, **values}, HEAD)

    def test_unique_label_only_and_exact_queued_job_are_required(self):
        for jobs in ([], [JOB, JOB], [{**JOB, 'labels': ['self-hosted', LABEL]}],
                     [{**JOB, 'run_id': 99}], [{**JOB, 'head_sha': 'c' * 40}],
                     [{**JOB, 'status': 'in_progress'}]):
            with self.subTest(jobs=jobs), self.assertRaises(ValueError):
                runner.validate_job(jobs, RUN_ID, HEAD)

    def test_an_existing_runner_or_other_workflow_claim_blocks_enrollment(self):
        def pages(endpoint, field):
            if field == 'jobs':
                return [JOB]
            if field == 'runners':
                return [{'id': 77, 'labels': [{'name': LABEL}]}]
            return []
        with patch.object(runner, 'api', return_value=RUN), patch.object(runner, 'pages', side_effect=pages):
            with self.assertRaisesRegex(ValueError, 'already exists'):
                runner.reviewed_job(RUN_ID, HEAD)
            runner.reviewed_job(RUN_ID, HEAD, own_runner=77)
        def conflicting(endpoint, field):
            if field == 'jobs':
                return [JOB] if f'/runs/{RUN_ID}/' in endpoint else [{**JOB, 'run_id': 99}]
            return [{'id': 99}] if field == 'workflow_runs' else []
        with patch.object(runner, 'api', return_value=RUN), patch.object(runner, 'pages', side_effect=conflicting):
            with self.assertRaisesRegex(ValueError, 'Another unfinished'):
                runner.reviewed_job(RUN_ID, HEAD)

    def test_official_download_requires_api_checksum(self):
        self.assertEqual(runner.runner_package([DOWNLOAD]), (DOWNLOAD['download_url'], 'b' * 64))
        for values in ({'sha256_checksum': ''}, {'download_url': 'https://attacker.example/runner.tar.gz'},
                       {'download_url': DOWNLOAD['download_url'] + '?token=secret'}, {'architecture': 'arm64'}):
            with self.assertRaises(ValueError):
                runner.runner_package([{**DOWNLOAD, **values}])


class PackageVerification(unittest.TestCase):
    def test_checksum_mismatch_never_reaches_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            response = io.BytesIO(b'fixture archive bytes')
            response.url = DOWNLOAD['download_url']
            with patch.object(runner, 'urlopen', return_value=response):
                with self.assertRaisesRegex(ValueError, 'SHA-256'):
                    runner.download(response.url, 'b' * 64, Path(temporary) / 'runner.tar.gz')

    def test_verified_download_and_archive_path_filter(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'runner.tar.gz'
            with tarfile.open(archive, 'w:gz') as bundle:
                for name in ('config.sh', 'run.sh'):
                    member = tarfile.TarInfo(name)
                    content = b'#!/bin/sh\nexit 0\n'
                    member.mode, member.size = 0o755, len(content)
                    bundle.addfile(member, io.BytesIO(content))
            output = root / 'unpacked'
            output.mkdir()
            runner.extract(archive, output)
            self.assertTrue(os.access(output / 'run.sh', os.X_OK))
            with tarfile.open(archive, 'w:gz') as bundle:
                member = tarfile.TarInfo('../escape')
                member.size = 1
                bundle.addfile(member, io.BytesIO(b'x'))
            with self.assertRaises(tarfile.FilterError):
                runner.extract(archive, output)
            self.assertFalse((root / 'escape').exists())
            data = b'official pinned bytes'
            response = io.BytesIO(data)
            response.url = DOWNLOAD['download_url']
            with patch.object(runner, 'urlopen', return_value=response):
                runner.download(response.url, hashlib.sha256(data).hexdigest(), root / 'download')
            self.assertEqual((root / 'download').read_bytes(), data)


class EphemeralLifecycle(unittest.TestCase):
    def execute_fixture(self, root, failure=None, completed=None):
        commands = []
        def api(endpoint, **_kwargs):
            if endpoint.endswith('/downloads'):
                return [DOWNLOAD]
            if endpoint.endswith('/registration-token'):
                return {'token': 'private-registration-token'}
            if '/actions/jobs/' in endpoint:
                return completed or {**JOB, 'status': 'completed', 'runner_id': 77, 'conclusion': 'success'}
            raise AssertionError(endpoint)
        def invoke(command, work, environment, timeout, **kwargs):
            commands.append((command, dict(environment), timeout, kwargs))
            (work / '.credentials').write_text('ephemeral credentials')
            if failure and (failure == 'registration' or command[0].endswith('/run.sh')):
                raise KeyboardInterrupt
        with patch.object(runner, 'check_user_manager'), \
             patch.object(runner, 'reviewed_job', return_value=(RUN, JOB)), \
             patch.object(runner, 'api', side_effect=api), \
             patch.object(runner, 'download', side_effect=lambda _url, _sha, path: path.touch()), \
             patch.object(runner, 'extract'), patch.object(runner, 'owned_runner', return_value=77), \
             patch.object(runner, 'run_child', side_effect=invoke), \
             patch.object(runner, 'run_scoped_runner', side_effect=lambda work, env, timeout, _name: invoke([str(work / 'run.sh')], work, env, timeout)), \
             patch.object(runner, 'cleanup_registration') as cleanup, \
             patch.dict(os.environ, {'GH_TOKEN': 'operator-admin-token', 'GITHUB_TOKEN': 'other-token'}):
            try:
                runner.execute(RUN_ID, HEAD, root, 60)
            finally:
                cleanup.assert_called_once()
                self.assertEqual(list(root.iterdir()), [], 'Task directory and credentials must be removed')
        return commands

    def test_success_registers_unique_only_label_and_strips_operator_tokens(self):
        with tempfile.TemporaryDirectory() as temporary:
            commands = self.execute_fixture(Path(temporary))
        config, run = commands
        self.assertIn('--ephemeral', config[0])
        self.assertIn('--no-default-labels', config[0])
        self.assertEqual(config[0][config[0].index('--labels') + 1], LABEL)
        self.assertNotIn('private-registration-token', ' '.join(config[0]))
        self.assertEqual(config[1]['ACTIONS_RUNNER_INPUT_TOKEN'], 'private-registration-token')
        for command in commands:
            self.assertNotIn('GH_TOKEN', command[1])
            self.assertNotIn('GITHUB_TOKEN', command[1])
        self.assertNotIn('ACTIONS_RUNNER_INPUT_TOKEN', run[1])
        self.assertEqual(run[2], 60)

    def test_interruption_cleans_partial_registration_and_active_runner(self):
        for failure in ('registration', 'running'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                with self.assertRaises(KeyboardInterrupt):
                    self.execute_fixture(Path(temporary), failure=failure)

    def test_unexpected_job_assignment_fails_after_stopping_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(RuntimeError, 'reviewed job'):
                self.execute_fixture(Path(temporary), completed={**JOB, 'status': 'completed',
                                      'runner_id': 88, 'conclusion': 'success'})

    def test_cleanup_deletes_only_exact_owned_runner(self):
        names = [{'name': 'other-runner', 'id': 1}, {'name': 'owned-unique', 'id': 2}]
        with patch.object(runner, 'pages', return_value=names), patch.object(runner, 'api') as api:
            runner.cleanup_registration('owned-unique')
            api.assert_called_once_with(f'repos/{runner.REPOSITORY}/actions/runners/2', method='DELETE')
        with patch.object(runner, 'pages', return_value=[]), patch.object(runner, 'api') as api:
            runner.cleanup_registration('already-removed')
            api.assert_not_called()

    def test_runtime_uses_a_bounded_cgroup_and_stops_it_on_interruption(self):
        result = subprocess.CompletedProcess([], 0, stdout='inactive\n')
        with patch.object(runner, 'run_child', side_effect=KeyboardInterrupt) as invoke, \
             patch.object(runner.subprocess, 'run', return_value=result) as systemctl:
            with self.assertRaises(KeyboardInterrupt):
                runner.run_scoped_runner(Path('/fixture'), {'HOME': '/fixture/home'}, 60, 'owned-unit')
        command = invoke.call_args.args[0]
        self.assertIn('--property=RuntimeMaxSec=60s', command)
        self.assertIn('--property=TimeoutStopSec=120s', command)
        self.assertIn('--property=KillMode=mixed', command)
        self.assertIn('/usr/bin/env', command)
        self.assertIn('-i', command)
        self.assertEqual(systemctl.call_args_list[0].args[0], ['systemctl', '--user', 'stop', 'owned-unit.service'])
        self.assertEqual(systemctl.call_args_list[-1].args[0][-2:], ['--property=ActiveState', '--value'])

    def test_running_cgroup_is_not_mistaken_for_safe_cleanup(self):
        result = subprocess.CompletedProcess([], 0, stdout='deactivating\n')
        with patch.object(runner, 'run_child'), patch.object(runner.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(runner.ActiveRunnerError, 'Could not confirm'):
                runner.run_scoped_runner(Path('/fixture'), {}, 60, 'owned-unit')

    def test_unconfirmed_stop_retains_private_staging_instead_of_deleting_live_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def api(endpoint, **_kwargs):
                return [DOWNLOAD] if endpoint.endswith('/downloads') else {'token': 'fixture-token'}
            with patch.object(runner, 'check_user_manager'), \
                 patch.object(runner, 'reviewed_job', return_value=(RUN, JOB)), \
                 patch.object(runner, 'api', side_effect=api), \
                 patch.object(runner, 'download', side_effect=lambda _url, _sha, path: path.touch()), \
                 patch.object(runner, 'extract'), patch.object(runner, 'run_child'), \
                 patch.object(runner, 'owned_runner', return_value=77), \
                 patch.object(runner, 'cleanup_registration') as cleanup, \
                 patch.object(runner, 'run_scoped_runner', side_effect=runner.ActiveRunnerError('still stopping')):
                with self.assertRaises(runner.ActiveRunnerError):
                    runner.execute(RUN_ID, HEAD, root, 60)
                cleanup.assert_called_once()
            directories = list(root.iterdir())
            self.assertEqual(len(directories), 1)
            self.assertEqual(directories[0].stat().st_mode & 0o777, 0o700)
            self.assertTrue((directories[0] / 'home').is_dir())
            # The outer fixture owns and removes this simulated retained tree.

    def test_validation_only_does_not_register_a_runner(self):
        with patch.object(runner, 'checkout_head', return_value=HEAD), \
             patch.object(runner, 'reviewed_job', return_value=(RUN, JOB)), \
             patch.object(runner, 'execute') as execute, \
             patch('sys.argv', ['release-runner', '--run-id', str(RUN_ID)]):
            self.assertEqual(runner.main(), 0)
            execute.assert_not_called()

    def test_timeout_stops_and_reaps_task_owned_process_group(self):
        process = MagicMock()
        process.__enter__.return_value = process
        process.communicate.side_effect = subprocess.TimeoutExpired('fixture', 60)
        with patch.object(runner.subprocess, 'Popen', return_value=process), patch.object(runner, 'stop') as stop:
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run_child(['fixture'], Path('/fixture'), {}, 60)
            stop.assert_called_once_with(process)
        process = MagicMock(pid=9876)
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired('fixture', 30), 0]
        with patch.object(runner.os, 'killpg') as kill:
            runner.stop(process)
        self.assertEqual([call.args for call in kill.call_args_list], [(9876, signal.SIGINT), (9876, signal.SIGTERM)])


if __name__ == '__main__':
    unittest.main()
