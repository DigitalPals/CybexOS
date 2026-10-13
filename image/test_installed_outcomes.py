"""Fixtures for the real VM gate; these deliberately do not claim VM execution."""
import importlib.machinery
import importlib.util
import io
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
                  required_packages={'quickshell': ['quickshell.x86_64=1']}, flatpaks=[], selinux='Enforcing')
    return result


class OutcomeComparison(unittest.TestCase):
    def test_equal_real_capture_shapes_pass_without_implicit_exclusions(self):
        result = outcomes.compare(fixture(), fixture('checkout'), {})
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['differences'], {})

    def test_policy_or_effective_behavior_difference_blocks_release(self):
        for key in ('settings', 'input', 'choices', 'authentication', 'firewall', 'system_units',
                    'user_units', 'recovery', 'default_apps', 'required_packages'):
            changed = fixture('checkout')
            changed[key]['difference'] = False
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
    def test_public_installer_uses_all_defaults_and_no_fixture_feature_optouts(self):
        script = checkout_runner.install_script('plain-nl')
        self.assertIn('./install --non-interactive', script)
        self.assertNotIn('convergence-vars', script)
        self.assertNotIn('--tags', script)
        self.assertIn('LANG=nl_NL.UTF-8', script)
        self.assertIn('rm -f /etc/sudoers.d/90-cloud-init-users', script)
        self.assertIn('export SUDO_USER=qualification', script)
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
