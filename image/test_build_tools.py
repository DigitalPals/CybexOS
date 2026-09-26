"""Source-only fixtures: no ISO filesystem, QEMU process or PXE server is used."""
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import tarfile
from types import SimpleNamespace
import unittest
import urllib.error
from unittest.mock import patch

from build_support import (builder_cloud_config, checksum_entries, deliver_artifacts,
                           select_firmware, wait_for_builder_initialization)
from download_cache import import_cache, merge_cache, verified_entries
from pxe_publish import DEFAULT_CONTRACT, IVentoy, publish, staging_parent, validate_status


class SourceArchiveTests(unittest.TestCase):
    def test_disposable_builder_receives_skill_license_and_provisioning_helper(self):
        loader = importlib.machinery.SourceFileLoader('archive_build', str(Path(__file__).with_name('build')))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        builder = importlib.util.module_from_spec(spec)
        loader.exec_module(builder)
        from desktop_payload import prepare_session
        from provision_payload import prepare_provision
        import yaml
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'source.tar.gz'
            builder.source_archive(archive)
            extracted = root / 'source'
            with tarfile.open(archive) as stream:
                stream.extractall(extracted, filter='data')
            payload = root / 'payload'
            inventory = yaml.safe_load((extracted / 'inventory/group_vars/all.yml').read_text())
            # Exercise the actual packager against only what crosses the VM
            # boundary; testing against the full checkout hid missing inputs.
            prepare_session(extracted, payload, inventory)
            prepare_provision(extracted, payload)
            self.assertTrue((extracted / 'LICENSE').is_file())
            self.assertTrue((payload / 'usr/share/cybexos/agent-skills/cybexos/SKILL.md').is_file())
            helper = payload / 'usr/share/cybexos/provision/scripts/manage-agent-skills'
            self.assertTrue(helper.is_file())
            self.assertTrue(helper.stat().st_mode & 0o111)


class BuilderInitializationTests(unittest.TestCase):
    def test_hostname_is_set_only_during_final_stage(self):
        config = builder_cloud_config('ssh-ed25519 synthetic-public-fixture')
        self.assertTrue(config['preserve_hostname'])
        self.assertEqual(config['runcmd'], [['hostnamectl', 'set-hostname', 'image-builder']])
        self.assertFalse(config['ssh_pwauth'])
        self.assertTrue(config['disable_root'])
        self.assertEqual(config['users'][0]['ssh_authorized_keys'], ['ssh-ed25519 synthetic-public-fixture'])

    def test_success_verifies_hostname_and_sudo_before_source_transfer(self):
        result = SimpleNamespace(returncode=0, stdout='{"status":"done"}\n', stderr='')
        with tempfile.TemporaryDirectory() as directory, patch('build_support.subprocess.run', return_value=result) as run:
            wait_for_builder_initialization(['ssh', 'builder-fixture'], directory)
            self.assertEqual(run.call_args_list[0].args[0][-1], 'cloud-init status --wait --format=json')
            command = run.call_args_list[1].args[0][-1]
            self.assertIn('test "$(hostname)" = image-builder', command)
            self.assertIn('sudo -n true', command)
            self.assertTrue(run.call_args_list[1].kwargs['check'])
            self.assertEqual((Path(directory) / 'builder-cloud-init-status.log').read_text(), result.stdout)

    def test_degraded_or_failed_cloud_init_never_proceeds_and_keeps_evidence(self):
        for code in (1, 2, 255):
            result = SimpleNamespace(returncode=code, stdout='{"status":"done","recoverable_errors":["fixture"]}\n', stderr='fixture diagnostic\n')
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory, \
                    patch('build_support.subprocess.run', return_value=result) as run:
                with self.assertRaisesRegex(RuntimeError, f'cloud-init exited {code}'):
                    wait_for_builder_initialization(['ssh', 'builder-fixture'], directory)
                self.assertEqual(run.call_count, 2)
                self.assertIn('tail -n 400 /var/log/cloud-init.log', run.call_args.args[0][-1])
                self.assertNotIn('mkdir', run.call_args.args[0][-1])
                self.assertTrue((Path(directory) / 'builder-cloud-init.log').exists())
                self.assertIn('fixture diagnostic', (Path(directory) / 'builder-cloud-init-status.log').read_text())


class DeliveryTests(unittest.TestCase):
    def test_verified_directory_is_published_atomically(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / 'stage'
            stage.mkdir()
            (stage / 'payload.bin').write_bytes(b'synthetic fixture, not an image')
            checksum = hashlib.sha256((stage / 'payload.bin').read_bytes()).hexdigest()
            (stage / 'SHA256SUMS').write_text(f'{checksum}  payload.bin\n')
            self.assertEqual(deliver_artifacts(stage, root / 'complete'), {'payload.bin': checksum})
            self.assertFalse(stage.exists())
            self.assertEqual((root / 'complete/payload.bin').stat().st_mode & 0o777, 0o644)

    def test_bad_checksum_and_traversal_never_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'payload.bin').write_bytes(b'fixture')
            for entry in ('0' * 64 + '  payload.bin\n', '0' * 64 + '  ../payload.bin\n'):
                (root / 'SHA256SUMS').write_text(entry)
                with self.assertRaises(ValueError):
                    checksum_entries(root)

    def test_unchecked_artifacts_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'payload.bin').write_bytes(b'fixture')
            digest = hashlib.sha256(b'fixture').hexdigest()
            (root / 'SHA256SUMS').write_text(f'{digest}  payload.bin\n')
            (root / 'unexpected').touch()
            with self.assertRaises(ValueError):
                checksum_entries(root)


class CacheTests(unittest.TestCase):
    def test_verified_cache_reuses_bytes_and_rejects_stale_destinations(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exported, cached, guest = [root / name for name in ('exported', 'cached', 'guest')]
            exported.mkdir()
            checksum = hashlib.sha256(b'verified').hexdigest()
            (exported / checksum).write_bytes(b'verified')
            entry = {'path': '/var/cache/tool/asset', 'sha256': checksum}
            (exported / 'manifest.json').write_text(json.dumps({'entries': [entry]}))
            contract = [(checksum, '/var/cache/tool/asset', None)]
            merge_cache(exported, cached, contract)
            import_cache(cached, contract, guest)
            self.assertEqual((guest / 'var/cache/tool/asset').read_bytes(), b'verified')
            self.assertEqual(verified_entries(cached, []), [])
            (cached / checksum).write_bytes(b'corrupt')
            self.assertEqual(verified_entries(cached, contract), [])

    def test_cache_never_follows_destination_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache, guest, external = [root / name for name in ('cache', 'guest', 'external')]
            for path in (cache, guest, external):
                path.mkdir()
            checksum = hashlib.sha256(b'verified').hexdigest()
            (cache / checksum).write_bytes(b'verified')
            (cache / 'manifest.json').write_text(json.dumps({'entries': [{'path': '/var/asset', 'sha256': checksum}]}))
            (guest / 'var').symlink_to(external, target_is_directory=True)
            with self.assertRaises(ValueError):
                import_cache(cache, [(checksum, '/var/asset', None)], guest)
            self.assertEqual(list(external.iterdir()), [])


class FirmwareTests(unittest.TestCase):
    def test_qemu_descriptor_handles_fedora_qcow2_and_ignores_secure_boot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            code, variables = root / 'code.qcow2', root / 'vars.qcow2'
            code.touch()
            variables.touch()
            descriptor = {'interface-types': ['uefi'], 'features': [], 'targets': [{'architecture': 'x86_64', 'machines': ['pc-q35-*']}],
                          'mapping': {'device': 'flash', 'executable': {'filename': str(code), 'format': 'qcow2'},
                                      'nvram-template': {'filename': str(variables), 'format': 'qcow2'}}}
            (root / 'plain.json').write_text(json.dumps(descriptor))
            descriptor['features'] = ['secure-boot']
            (root / 'first.json').write_text(json.dumps(descriptor))
            selected = select_firmware(root, root / 'missing')
            self.assertEqual(selected['code']['format'], 'qcow2')
            self.assertTrue(selected['descriptor'].endswith('plain.json'))

    def test_missing_firmware_fails_with_package_guidance(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(RuntimeError, 'edk2-ovmf'):
                select_firmware(Path(temporary), Path(temporary))


class PublisherTests(unittest.TestCase):
    def fixture_client(self, responses, timeout=180):
        clock = [0]
        methods = []
        responses = iter(responses)
        def request(method):
            methods.append(method)
            clock[0] += 1
            response = next(responses)
            if isinstance(response, Exception):
                raise response
            return response
        def sleep(seconds):
            clock[0] += seconds
        client = IVentoy('http://127.0.0.1:26000/iventoy/json', DEFAULT_CONTRACT,
                         request=request, timeout=timeout, sleep=sleep, clock=lambda: clock[0])
        return client, methods, clock

    def test_accepted_refresh_retries_only_status_timeouts(self):
        client, methods, _ = self.fixture_client([
            {'status': 'running'}, {'result': 'success'}, TimeoutError('timed out'),
            urllib.error.URLError(TimeoutError('timed out')), {'status': 'refreshing'},
            {'status': 'running'}, [{'name': 'fixture.iso'}],
        ])
        client.refresh('fixture.iso')
        self.assertEqual(methods.count('refresh_img_list'), 1)
        self.assertEqual(methods.count('query_status'), 5)
        self.assertEqual(methods[-1], 'get_img_tree')

    def test_polling_uses_one_deadline_for_the_whole_refresh(self):
        client, methods, clock = self.fixture_client([
            {'status': 'refreshing'}, {'status': 'running'}, {'result': 'success'},
            TimeoutError('timed out')], timeout=8)
        with self.assertRaisesRegex(RuntimeError, 'deadline'):
            client.refresh('fixture.iso')
        self.assertEqual(clock[0], 8)
        self.assertEqual(methods, ['query_status', 'query_status', 'refresh_img_list', 'query_status'])

    def test_ambiguous_refresh_timeout_is_never_repeated(self):
        client, methods, _ = self.fixture_client([{'status': 'running'}, TimeoutError('timed out')])
        with self.assertRaises(TimeoutError):
            client.refresh('fixture.iso')
        self.assertEqual(methods, ['query_status', 'refresh_img_list'])

    def test_status_json_and_other_transport_errors_are_not_retried(self):
        for error in (json.JSONDecodeError('bad JSON', '!', 0),
                      urllib.error.URLError(ConnectionRefusedError('refused'))):
            with self.subTest(error=type(error).__name__):
                client, methods, _ = self.fixture_client([
                    {'status': 'running'}, {'result': 'success'}, error])
                with self.assertRaises(type(error)):
                    client.refresh('fixture.iso')
                self.assertEqual(methods, ['query_status', 'refresh_img_list', 'query_status'])

    def test_timeout_recovery_still_requires_running_pxe_and_expected_filename(self):
        for remaining, message in (([{'status': 'stopped'}], 'not running'),
                                   ([{'status': 'running'}, [{'name': 'other.iso'}]], 'published filename')):
            client, _, _ = self.fixture_client([
                {'status': 'running'}, {'result': 'success'}, TimeoutError('timed out'), *remaining])
            with self.assertRaisesRegex(RuntimeError, message):
                client.refresh('fixture.iso')

    def test_http_request_timeout_cannot_exceed_remaining_deadline(self):
        client = IVentoy('http://127.0.0.1:26000/iventoy/json', DEFAULT_CONTRACT, clock=lambda: 5)
        with patch('pxe_publish.urllib.request.urlopen', side_effect=TimeoutError) as request:
            with self.assertRaises(TimeoutError):
                client._query('query_status', 8)
        self.assertEqual(request.call_args.kwargs['timeout'], 3)

    def test_refresh_polls_known_iventoy_contract_and_verifies_tree(self):
        responses = iter([{'status': 'running'}, {'result': 'success'}, {'status': 'refreshing'}, {'status': 'running'}, [{'name': 'fixture.iso'}]])
        methods = []
        def request(method):
            methods.append(method)
            return next(responses)
        client = IVentoy('http://127.0.0.1:26000/iventoy/json', DEFAULT_CONTRACT, request=request, sleep=lambda _: None)
        client.refresh('fixture.iso')
        self.assertEqual(methods, ['query_status', 'refresh_img_list', 'query_status', 'query_status', 'get_img_tree'])

    def test_http_success_is_not_refresh_success(self):
        responses = iter([{'status': 'running'}, {'result': 'failure'}])
        client = IVentoy('http://127.0.0.1:26000/iventoy/json', DEFAULT_CONTRACT, request=lambda _: next(responses))
        with self.assertRaisesRegex(RuntimeError, 'rejected refresh'):
            client.refresh('fixture.iso')

    def test_stopped_pxe_and_unknown_schema_fail(self):
        for value in ({'status': 'ready'}, {'result': 'success'}, {'status': 'surprise'}):
            with self.assertRaises(RuntimeError):
                validate_status(value, DEFAULT_CONTRACT)

    def test_verified_publication_is_idempotent_and_preserves_other_files(self):
        # These tiny text fixtures are not ISO filesystems or boot tests.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            served = root / 'served'
            served.mkdir()
            source = root / 'payload.bin'
            source.write_bytes(b'synthetic publication bytes')
            previous = served / 'existing.bin'
            previous.write_bytes(b'preserve')
            first = publish(source, served, 'fixture.iso')
            second = publish(source, served, 'fixture.iso')
            self.assertEqual(first, second)
            self.assertEqual(previous.read_bytes(), b'preserve')
            source.write_bytes(b'different')
            with self.assertRaises(FileExistsError):
                publish(source, served, 'fixture.iso')
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['payload.bin', 'served'])

    @unittest.skipIf(os.geteuid() == 0, 'root bypasses directory permissions')
    def test_publication_stages_in_nearest_writable_ancestor(self):
        # Mirrors a PXE host: root-owned /data/pxe, user-writable /data and /data/pxe/iso.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            parent = root / 'pxe'
            served = parent / 'iso'
            served.mkdir(parents=True)
            source = root / 'payload.bin'
            source.write_bytes(b'synthetic publication bytes')
            parent.chmod(0o555)
            try:
                self.assertEqual(staging_parent(served), root.resolve())
                destination, _ = publish(source, served, 'fixture.iso')
                self.assertEqual(destination.read_bytes(), b'synthetic publication bytes')
                self.assertEqual(sorted(p.name for p in root.iterdir()), ['payload.bin', 'pxe'])
            finally:
                parent.chmod(0o755)

    def test_staging_inside_served_tree_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            served = Path(temporary) / 'served'
            (served / 'incoming').mkdir(parents=True)
            for requested in (served, served / 'incoming'):
                with self.assertRaises(ValueError):
                    staging_parent(served, requested)
            self.assertEqual(staging_parent(served, Path(temporary)), Path(temporary).resolve())


class QualificationSourceTests(unittest.TestCase):
    def test_installation_requires_both_explicit_execution_flags(self):
        import qualification
        for flags in ([], ['--execute-vm'], ['--erase-disposable-disk']):
            with patch('sys.argv', ['qualify', '/does-not-exist', '--output', '/does-not-exist', *flags]), patch('sys.stderr'), patch.object(qualification.signal, 'signal'), patch.object(qualification, 'TestVM') as vm:
                with self.assertRaises(SystemExit):
                    qualification.main()
                vm.assert_not_called()

    def test_cleanup_never_touches_an_unowned_directory(self):
        from vm_testing import TestVM
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'installed.qcow2').write_bytes(b'some other task')
            vm = TestVM(root)
            vm.cleanup()
            self.assertEqual((root / 'installed.qcow2').read_bytes(), b'some other task')

    def test_qemu_filename_options_cannot_be_injected(self):
        from build_support import validate_qemu_path
        for path in ('/tmp/example,media=disk', '/tmp/new\nline'):
            with self.assertRaises(ValueError):
                validate_qemu_path(path)

    def test_backend_protocol_extracts_result_and_never_passes_secrets_in_argv(self):
        import qualification
        from types import SimpleNamespace
        vm = SimpleNamespace(ssh=['ssh', 'fixture'])
        response = SimpleNamespace(stdout='{"event":"result","ok":true,"data":{"disk":{"name":"vda"},"token":"fixture-token"}}\n')
        with patch.object(qualification, 'run', return_value=response) as run:
            plan = qualification.backend(vm, 'plan', {'password': 'private-test-value'})
        self.assertEqual(plan['disk']['name'], 'vda')
        self.assertNotIn('private-test-value', ' '.join(run.call_args.args[0]))
        self.assertIn('private-test-value', run.call_args.kwargs['input'])


class DeliveryRegressionTests(unittest.TestCase):
    def fixture(self, root, name='cybexos-desktop-0.0.0~dev^fixture.x86_64.rpm'):
        root.mkdir()
        (root / name).write_bytes(b'synthetic bytes, not an RPM')
        checksum = hashlib.sha256((root / name).read_bytes()).hexdigest()
        (root / 'SHA256SUMS').write_text(f'{checksum}  {name}\n')
        return name, checksum

    def test_prerelease_rpm_names_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory) / 'stage'
            name, checksum = self.fixture(stage)
            self.assertEqual(checksum_entries(stage), {name: checksum})

    def test_symlinked_checksum_manifest_is_rejected_without_chmod(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / 'stage'
            self.fixture(stage)
            external = root / 'external'
            (stage / 'SHA256SUMS').rename(external)
            external.chmod(0o600)
            (stage / 'SHA256SUMS').symlink_to(external)
            with self.assertRaisesRegex(ValueError, 'never a symlink'):
                deliver_artifacts(stage, root / 'delivered')
            self.assertEqual(external.stat().st_mode & 0o777, 0o600)
            self.assertFalse((root / 'delivered').exists())

    def test_concurrent_empty_directory_is_preserved(self):
        import build_support
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage, destination = root / 'stage', root / 'complete'
            self.fixture(stage)
            original = build_support.rename_new_directory
            def concurrent_creation(source, target):
                target.mkdir()
                return original(source, target)
            with patch.object(build_support, 'rename_new_directory', side_effect=concurrent_creation):
                with self.assertRaises(FileExistsError):
                    deliver_artifacts(stage, destination)
            self.assertTrue(stage.is_dir())
            self.assertEqual(list(destination.iterdir()), [])

    def test_adjacent_checksum_requires_correct_bytes_and_filename(self):
        from build_support import verify_sidecar
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'payload.bin'
            path.write_bytes(b'fixture')
            checksum = hashlib.sha256(b'fixture').hexdigest()
            sidecar = path.with_name(path.name + '.sha256')
            for entry in (f'{checksum}  different.bin\n', '0' * 64 + '  payload.bin\n'):
                sidecar.write_text(entry)
                with self.assertRaises(ValueError):
                    verify_sidecar(path)
            sidecar.write_text(f'{checksum}  payload.bin\n')
            self.assertEqual(verify_sidecar(path), checksum)

    def test_guest_audit_streams_the_actual_shared_helper(self):
        from vm_testing import audit_script
        helper = (Path(__file__).resolve().parents[1] / 'tests/lib/quickshell-live').read_text()
        script = audit_script()
        self.assertIn(helper, script)
        self.assertTrue(script.endswith('qs_live_begin\nqs_live_end\n'))

    def test_imported_qualification_entry_registers_cleanup_signals(self):
        import qualification
        import signal
        with patch('sys.argv', ['qualify', 'fixture', '--output', 'fixture']), patch('sys.stderr'), patch.object(qualification.signal, 'signal') as register:
            with self.assertRaises(SystemExit):
                qualification.main()
        register.assert_any_call(signal.SIGTERM, qualification.interrupt)
        register.assert_any_call(signal.SIGHUP, qualification.interrupt)


if __name__ == '__main__':
    unittest.main()
