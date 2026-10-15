"""Fixtures for the real VM gate; these deliberately do not claim VM execution."""
import importlib.machinery
import importlib.util
import io
import json
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

import installed_outcomes as outcomes
import parity_qualification as parity
import source_snapshot as source

loader = importlib.machinery.SourceFileLoader('checkout_qualification', str(Path(__file__).with_name('qualify-checkout')))
spec = importlib.util.spec_from_loader(loader.name, loader)
checkout_runner = importlib.util.module_from_spec(spec)
loader.exec_module(checkout_runner)


def fixture(installation='iso'):
    result = {key: {'fixture': True} for key in outcomes.CAPTURE_FIELDS}
    result.update(format=1, installation=installation, scenario='plain-us', profile='fresh',
                  source_revision='a' * 40, source_content_sha256='b' * 64, hardware={'product_name': 'QEMU'},
                  graphical_session=True, sole_managed_shell=True, installed_packages=['quickshell.x86_64=1'],
                  required_packages={'quickshell': ['quickshell.x86_64=1']}, flatpaks=[], selinux='Enforcing', boot_target='graphical.target')
    return result


class FlatpakColumns(unittest.TestCase):
    def test_capture_asks_only_for_columns_flatpak_118_accepts(self):
        """Fedora 44's flatpak 1.18 exits "Unknown column: commit"; the
        deployed commit is the `active` column (seen in a 2026-10-14 ISO run)."""
        accepted = {'name', 'description', 'application', 'version', 'branch', 'arch', 'runtime',
                    'origin', 'installation', 'ref', 'active', 'latest', 'size', 'options', 'all'}
        source = Path(outcomes.__file__).read_text()
        requested = re.findall(r"'--columns=([a-z,]+)'", source)
        self.assertTrue(requested)
        for columns in requested:
            self.assertLessEqual(set(columns.split(',')), accepted, columns)


class OutcomeComparison(unittest.TestCase):
    def test_session_target_links_and_user_enablement_have_equivalent_activation(self):
        dependencies = {'quickshell.service', 'hypridle.service'}
        self.assertEqual(outcomes.effective_unit_state('quickshell.service', 'disabled', 'active', dependencies),
                         outcomes.effective_unit_state('quickshell.service', 'enabled', 'active', dependencies))
        active = outcomes.effective_unit_state('quickshell.service', 'enabled', 'active', dependencies)
        self.assertNotEqual(active, outcomes.effective_unit_state('quickshell.service', 'enabled', 'inactive', dependencies))
        self.assertNotEqual(active, outcomes.effective_unit_state('quickshell.service', 'disabled', 'active', set()))
        for invalid in ('masked', 'masked-runtime', 'not-found', 'bad'):
            self.assertNotEqual(active, outcomes.effective_unit_state('quickshell.service', invalid, 'active', dependencies))
        self.assertNotEqual(outcomes.effective_unit_state('voxtype.service', 'enabled', 'active', dependencies),
                            outcomes.effective_unit_state('voxtype.service', 'disabled', 'active', dependencies))

    def test_only_utc_alias_is_normalized_and_saved_choices_are_not_modified(self):
        selected = {'machine_timezone': 'UTC', 'passwordless_wheel': False, 'features': {'steam': False}}
        original = dict(selected)
        self.assertEqual(outcomes.policy_choices(selected), outcomes.policy_choices({**selected, 'machine_timezone': 'Etc/UTC'}))
        self.assertNotEqual(outcomes.policy_choices(selected), outcomes.policy_choices({**selected, 'machine_timezone': 'Europe/Amsterdam'}))
        self.assertEqual(selected, original)
        self.assertIs(outcomes.policy_choices(selected)['passwordless_wheel'], False)
        self.assertEqual(outcomes.policy_choices(selected)['features'], {'steam': False})

    def test_equal_real_capture_shapes_pass_without_implicit_exclusions(self):
        result = outcomes.compare(fixture(), fixture('checkout'), {})
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['differences'], {})

    def test_policy_or_effective_behavior_difference_blocks_release(self):
        for key in ('settings', 'input', 'choices', 'authentication', 'firewall', 'system_units',
                    'user_units', 'recovery', 'default_apps', 'required_packages', 'boot_target'):
            changed = fixture('checkout')
            if isinstance(changed[key], dict):
                changed[key]['difference'] = False
            else:
                changed[key] = 'rescue.target'
            with self.subTest(key=key):
                result = outcomes.compare(fixture(), changed, {})
                self.assertEqual(result['status'], 'failed')
                self.assertIn(key, result['differences'])

    def test_different_source_hardware_or_profile_cannot_be_compared(self):
        for key, value in (('source_content_sha256', 'c' * 64), ('source_revision', 'd' * 40),
                           ('hardware', {'product_name': 'different'}), ('profile', 'saved'), ('scenario', 'plain-nl')):
            changed = fixture('checkout')
            changed[key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'mismatched ' + key):
                outcomes.compare(fixture(), changed, {})

    def test_sparse_fixture_or_no_live_session_is_not_installed_evidence(self):
        for key in outcomes.CAPTURE_FIELDS:
            changed = fixture('checkout')
            del changed[key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                outcomes.compare(fixture(), changed, {})
        changed = fixture('checkout')
        changed['graphical_session'] = False
        with self.assertRaisesRegex(ValueError, 'graphical session'):
            outcomes.compare(fixture(), changed, {})

    def test_extra_packages_require_explicit_reason_without_masking_required_versions(self):
        changed = fixture('checkout')
        changed['installed_packages'].append('cloud-init.noarch=1')
        result = outcomes.compare(fixture(), changed, {})
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['package_delta']['checkout']['unreviewed'], ['cloud-init.noarch=1'])
        self.assertNotIn('package-delta-reviewed', result['checks'])
        exceptions = {'checkout': {'cloud-init.noarch': 'Pinned cloud test bootstrap dependency'}}
        self.assertEqual(outcomes.compare(fixture(), changed, exceptions)['status'], 'passed')
        changed['required_packages']['cloud-init'] = ['cloud-init.noarch=1']
        self.assertEqual(outcomes.compare(fixture(), changed, exceptions)['status'], 'failed')
        with self.assertRaisesRegex(ValueError, 'review reason'):
            outcomes.compare(fixture(), changed, {'checkout': {'cloud-init.noarch': ''}})

    def test_normalization_only_unifies_ownership_paths(self):
        value = {'wallDir': '/home/qualification/Pictures/Wallpapers', 'runtime': '/usr/share/cybexos/runtime/quickshell',
                 'choices': {'passwordless': False}, 'layout': ['nl', 'us']}
        normalized = outcomes.normalize(value, '/home/qualification')
        self.assertEqual(normalized['wallDir'], '$HOME/Pictures/Wallpapers')
        self.assertEqual(normalized['runtime'], '$RUNTIME/quickshell')
        self.assertEqual(normalized['choices'], {'passwordless': False})
        self.assertEqual(normalized['layout'], ['nl', 'us'])

    def test_signing_key_exception_is_exact_and_never_masks_required_versions(self):
        identity = 'gpg-pubkey.(none)=' + 'a' * 40 + '-12345678'
        changed = fixture('checkout')
        changed['installed_packages'].append(identity)
        exceptions = {'checkout': {identity: 'Exact reviewed vendor key imported by its signed package scriptlet'}}
        self.assertEqual(outcomes.compare(fixture(), changed, exceptions)['status'], 'passed')
        for unknown in (identity.replace('a' * 40, 'b' * 40), identity.replace('12345678', '87654321')):
            with self.subTest(identity=unknown):
                changed['installed_packages'][-1] = unknown
                result = outcomes.compare(fixture(), changed, exceptions)
                self.assertEqual(result['status'], 'failed')
                self.assertEqual(result['package_delta']['checkout']['unreviewed'], [unknown])
        changed['installed_packages'][-1] = identity
        changed['required_packages']['signing-key'] = [identity]
        self.assertEqual(outcomes.compare(fixture(), changed, exceptions)['status'], 'failed')

    def test_signing_key_family_exception_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'exact fingerprint and RPM release'):
            outcomes.compare(fixture(), fixture('checkout'), {
                'checkout': {'gpg-pubkey.(none)': 'A family-wide exception would hide unreviewed signing keys'}})

    def test_reviewed_brave_scriptlet_keys_are_fingerprint_scoped(self):
        policy = json.loads(Path(outcomes.__file__).with_name('parity-exceptions.json').read_text())
        keys = {name: reason for name, reason in policy['checkout'].items() if name.startswith('gpg-pubkey.')}
        self.assertEqual(len(keys), 3)
        for identity, reason in keys.items():
            self.assertRegex(identity, r'^gpg-pubkey\.\(none\)=[0-9a-f]{40}-[0-9a-f]{8}$')
            self.assertIn('brave-keyring 1.19-1', reason)
            self.assertIn('pinned stable repository', reason)


class SourceIdentity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cybexos-source-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.root.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        for name in ('install', 'site.yml', 'inventory/group_vars/all.yml'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture source\n')
        self.provenance = Path(self.temp.name) / 'build.json'
        self.provenance.write_text('{}')
        self.archive = Path(self.temp.name) / 'source.tar.gz'

    def test_archive_has_identical_content_identity_and_changes_are_detected(self):
        initial = source.tree_identity(self.root)
        source.write_archive(self.root, self.archive, {'image/build-provenance.json': self.provenance})
        self.assertEqual(source.archive_identity(self.archive), initial)
        (self.root / 'install').write_text('changed\n')
        self.assertNotEqual(source.tree_identity(self.root), initial)
        (self.root / 'install').write_text('fixture source\n')
        (self.root / 'install').chmod(0o755)
        self.assertNotEqual(source.tree_identity(self.root), initial)

    def test_ignored_files_and_generated_provenance_do_not_shape_content_identity(self):
        (self.root / '.gitignore').write_text('local-secret\n')
        first = source.tree_identity(self.root)
        (self.root / 'local-secret').write_text('never archive')
        (self.root / 'image').mkdir()
        (self.root / 'image/build-provenance.json').write_text('generated')
        self.assertEqual(source.tree_identity(self.root), first)

    def test_archive_rejects_traversal_links_duplicate_and_missing_installer(self):
        for names in (['../escape'], ['/absolute'], ['same', 'same'], ['ordinary']):
            with self.subTest(names=names):
                with tarfile.open(self.archive, 'w:gz') as archive:
                    for name in names:
                        member = tarfile.TarInfo(name)
                        member.size = 1
                        archive.addfile(member, io.BytesIO(b'x'))
                with self.assertRaises(ValueError):
                    source.archive_identity(self.archive)
        with tarfile.open(self.archive, 'w:gz') as archive:
            link = tarfile.TarInfo('link')
            link.type, link.linkname = tarfile.SYMTYPE, '/outside'
            archive.addfile(link)
        with self.assertRaises(ValueError):
            source.archive_identity(self.archive)


class GuestWorkflow(unittest.TestCase):
    def test_cloud_os_preparation_reboots_before_pruning_and_is_outside_public_installer(self):
        vm = Mock(owned=True, network_restricted=False)
        steps = []
        def execute(_vm, script, _password, **_kwargs):
            steps.append(script)
            return Mock(stdout='DNF output\n{"running_kernel":"current"}\n')
        with patch.object(checkout_runner, 'root_script', side_effect=execute), \
                patch.object(checkout_runner, 'poweroff_installed', side_effect=lambda *_: steps.append('poweroff')):
            result = checkout_runner.prepare_cloud_baseline(vm, 'fixture')
        self.assertEqual(result['running_kernel'], 'current')
        self.assertEqual(steps, [checkout_runner.PREPARE_CLOUD_BASELINE, 'poweroff', checkout_runner.FINALIZE_CLOUD_BASELINE])
        vm.start.assert_called_once_with(user='qualification')
        vm.wait_ssh.assert_called_once()
        self.assertIsNone(vm.seed)
        self.assertIs(vm.expect_shell, False)
        self.assertIn('--oldinstallonly --limit=1', checkout_runner.FINALIZE_CLOUD_BASELINE)
        self.assertIn('fedora-release-cloud fedora-release', checkout_runner.PREPARE_CLOUD_BASELINE)
        self.assertLess(checkout_runner.PREPARE_CLOUD_BASELINE.index('fedora-release-identity-cloud fedora-release-identity-basic'),
                        checkout_runner.PREPARE_CLOUD_BASELINE.index('fedora-release-cloud fedora-release'))
        self.assertLess(checkout_runner.PREPARE_CLOUD_BASELINE.index('fedora-release-cloud fedora-release'),
                        checkout_runner.PREPARE_CLOUD_BASELINE.index('dnf upgrade -y --refresh --best'))
        # Prepare only preexisting Cloud packages; never hide dependencies
        # introduced by the public installer's intermediate codec choices.
        for name in ('fdk-aac-free', 'libavc1394', 'libklvanc', 'librabbitmq', 'xevd-libs'):
            self.assertNotIn(name, checkout_runner.PREPARE_CLOUD_BASELINE)
        self.assertNotIn('dnf upgrade', checkout_runner.install_script('plain-us'))
        self.assertNotIn('oldinstallonly', checkout_runner.install_script('plain-us'))
        for script in (checkout_runner.PREPARE_CLOUD_BASELINE, checkout_runner.FINALIZE_CLOUD_BASELINE):
            subprocess.run(['bash', '-n'], input=script, text=True, check=True)
        for owned, restricted in ((False, False), (True, True)):
            with self.assertRaises(ValueError):
                checkout_runner.prepare_cloud_baseline(Mock(owned=owned, network_restricted=restricted), 'fixture')

    def test_public_installer_uses_all_defaults_and_no_fixture_feature_optouts(self):
        script = checkout_runner.install_script('plain-nl')
        self.assertIn('./install --non-interactive', script)
        self.assertNotIn('convergence-vars', script)
        self.assertNotIn('--tags', script)
        self.assertIn('LANG=nl_NL.UTF-8', script)
        self.assertIn('rm -f /etc/sudoers.d/90-cloud-init-users', script)
        self.assertIn('export SUDO_USER=qualification', script)
        self.assertIn('systemctl get-default', script)
        self.assertNotIn('systemctl set-default', script)
        self.assertNotIn('systemctl enable sddm', script)
        self.assertNotIn('set-x11-keymap', checkout_runner.install_script('plain-nl', repeat=True))
        with self.assertRaises(ValueError):
            checkout_runner.install_script('encrypted-us')

    def test_desktop_lifecycle_streams_the_real_managed_service_test(self):
        with patch.object(parity.subprocess, 'run') as run:
            parity.desktop_lifecycle(Mock(ssh=['ssh', 'fixture']))
        script = run.call_args.kwargs['input']
        self.assertIn('qs_live_begin', script)
        self.assertIn('qs_live_end', script)
        self.assertIn('sound network accounts keyboard touchpad region', script)
        self.assertIn("trap cleanup EXIT", script)
        subprocess.run(['bash', '-n'], input=script, text=True, check=True)

    def test_capture_source_is_valid_python_and_requires_explicit_cli(self):
        source_text = Path(outcomes.__file__).read_text()
        compile(source_text, '<guest-capture>', 'exec')
        with patch.object(outcomes.os, 'geteuid', return_value=1000), self.assertRaisesRegex(RuntimeError, 'disposable qualification'):
            outcomes.capture('qualification', 'iso', 'plain-us', 'fresh', '/never', '/never')
        compile(parity.SAVED_CHOICES, '<saved-choice-fixture>', 'exec')


if __name__ == '__main__':
    unittest.main()
