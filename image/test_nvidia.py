"""NVIDIA parity: the checkout role and the ISO hardware setup are one contract.

Both paths run roles/nvidia (site.yml directly; the ISO through the boot-time
cybexos-hardware-setup service and image/provision.yml). These checks keep
the payload, the playbook wiring, the session environment, and the status
surfaces (welcome window, doctor) in step. The helper's own behavior is
covered with stubbed tools in tests/nvidia-hardware.py.
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

import yaml

from provision_payload import prepare_provision

ROOT = Path(__file__).resolve().parents[1]


def load(name, relative):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / relative))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


configure = load('configure_installed_nvidia', 'image/rootfs/usr/libexec/cybexos-configure-installed')
doctor = load('cybexos_doctor_nvidia', 'image/rootfs/usr/libexec/cybexos-doctor')


def tasks(relative):
    return yaml.safe_load((ROOT / relative).read_text())


def find(entries, name):
    for entry in entries:
        if entry.get('name') == name:
            return entry
        for key in ('block', 'rescue', 'always'):
            found = find(entry.get(key) or [], name)
            if found:
                return found
    return None


def named(entries, name):
    found = find(entries, name)
    if found is None:
        raise AssertionError(f'missing task: {name}')
    return found


def provision_tasks():
    return yaml.safe_load((ROOT / 'image/provision.yml').read_text())[0]['tasks']


SNIPPET = re.compile(r'# NVIDIA session variables.*?\nfi\n', re.S)


class BothPathsRunTheRole(unittest.TestCase):
    def test_checkout_runs_the_role_after_the_applications_role(self):
        play = yaml.safe_load((ROOT / 'site.yml').read_text())[0]
        roles = [entry['role'] for entry in play['roles']]
        self.assertLess(roles.index('apps'), roles.index('nvidia'), 'RPM Fusion keys come from apps')
        nvidia = play['roles'][roles.index('nvidia')]
        self.assertEqual(nvidia['tags'], ['nvidia', 'hardware'])

    def test_iso_hardware_setup_runs_the_same_role_with_its_retry_command(self):
        entry = named(provision_tasks(), 'Apply the NVIDIA driver role on detected NVIDIA hardware')
        self.assertEqual(entry['ansible.builtin.include_role'], {'name': 'nvidia'})
        self.assertEqual(entry['when'], 'cybexos_hardware_only | bool')
        self.assertEqual(entry['vars']['nvidia_retry_command'], 'cybex repair --hardware')
        self.assertIn('cybexos_hardware_automatic', entry['vars']['nvidia_setup_automatic'])
        # The wrapper passes --automatic through for boot-time runs only.
        source = (ROOT / 'image/rootfs/usr/libexec/cybexos-configure-installed').read_text()
        self.assertIn("'cybexos_hardware_automatic': automatic", source)
        self.assertIn('configure(account, args.offline, args.hardware, args.reconcile, args.automatic)', source)

    def test_offline_installation_records_the_nvidia_gate_like_the_xps_gate(self):
        entries = provision_tasks()
        detect = named(entries, 'Detect an NVIDIA GPU during offline installation as well as repair')
        xps = named(entries, 'Detect hardware during offline installation as well as repair')
        self.assertEqual(detect['ansible.builtin.include_role'], {'name': 'nvidia', 'tasks_from': 'detect'})
        self.assertEqual(detect['when'], xps['when'])
        record = named(entries, 'Record the detected desktop hardware policy')['ansible.builtin.copy']['content']
        self.assertIn("'nvidia': nvidia_is_present | bool", record)
        result = named(entries, 'Record the hardware role outcome for the boot-aware setup wrapper')
        self.assertIn("'nvidia':", result['ansible.builtin.copy']['content'])

    def test_payload_carries_the_role_and_rpm_fusion_trust_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            prepare_provision(ROOT, payload)
            provision = payload / 'usr/share/cybexos/provision'
            for relative in [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'roles/nvidia').rglob('*'))
                             if path.is_file()] + ['roles/apps/tasks/rpmfusion.yml',
                                                   'roles/apps/files/rpmfusion-free-fedora-2020.asc',
                                                   'roles/apps/files/rpmfusion-nonfree-fedora-2020.asc']:
                self.assertEqual((provision / relative).read_bytes(), (ROOT / relative).read_bytes(), relative)
            self.assertTrue(os.access(provision / 'roles/nvidia/files/cybexos-nvidia', os.X_OK))

    def test_the_hardware_service_runs_on_every_installation_not_only_xps(self):
        unit = (ROOT / 'image/rootfs/usr/lib/systemd/system/cybexos-hardware-setup.service').read_text()
        self.assertIn('ConditionPathExists=/etc/cybexos/hardware.json', unit)
        self.assertIn('--hardware --automatic', unit)


class RoleContract(unittest.TestCase):
    def setUp(self):
        self.setup = tasks('roles/nvidia/tasks/setup.yml')
        self.block = named(self.setup, 'Install and verify the RPM Fusion NVIDIA driver')

    def test_detection_is_always_safe_and_setup_is_gated(self):
        main = tasks('roles/nvidia/tasks/main.yml')
        self.assertEqual(main[0]['ansible.builtin.import_tasks'], 'detect.yml')
        self.assertEqual(main[1]['when'], ['nvidia_is_present | bool', 'not ansible_check_mode'])
        probe = named(tasks('roles/nvidia/tasks/detect.yml'), 'Detect NVIDIA display controllers')
        self.assertEqual(probe['ansible.builtin.script'], 'cybexos-nvidia detect')
        self.assertFalse(probe['check_mode'])

    def test_driver_steps_reuse_rpm_fusion_and_never_fail_the_play(self):
        steps = [entry['name'] for entry in self.block['block']]
        self.assertLess(steps.index('Create the akmods signing key before the driver builds'),
                        steps.index('Install the NVIDIA driver, CUDA libraries and VA-API driver'),
                        'Secure Boot needs the module signed while it builds')
        self.assertLess(steps.index('Read the installed package inventory for RPM Fusion'),
                        steps.index('Enable RPM Fusion with the applications role\'s pinned keys'))
        rpmfusion = named(self.setup, 'Enable RPM Fusion with the applications role\'s pinned keys')
        self.assertEqual(rpmfusion['ansible.builtin.import_role'], {'name': 'apps', 'tasks_from': 'rpmfusion'})
        self.assertIn('ansible.builtin.import_tasks: rpmfusion.yml',
                      (ROOT / 'roles/apps/tasks/repos.yml').read_text())
        rescue = self.block['rescue'][0]['ansible.builtin.command']['argv']
        self.assertEqual(rescue[:2], ['/usr/local/libexec/cybexos-nvidia', 'record-failure'])
        defaults = yaml.safe_load((ROOT / 'roles/nvidia/defaults/main.yml').read_text())
        self.assertEqual(defaults['nvidia_driver_packages'],
                         ['akmod-nvidia', 'xorg-x11-drv-nvidia-cuda-libs', 'libva-nvidia-driver'])
        self.assertEqual(defaults['nvidia_support_packages'], ['akmods', 'mokutil'])
        self.assertFalse(defaults['nvidia_setup_automatic'])

    def test_hybrid_laptops_keep_the_integrated_gpu_as_renderer(self):
        defaults = yaml.safe_load((ROOT / 'roles/nvidia/defaults/main.yml').read_text())
        self.assertEqual(defaults['nvidia_hybrid_session_environment'], {'NVD_BACKEND': 'direct'})
        self.assertEqual(defaults['nvidia_session_environment'],
                         {'LIBVA_DRIVER_NAME': 'nvidia', '__GLX_VENDOR_LIBRARY_NAME': 'nvidia',
                          'NVD_BACKEND': 'direct'})
        for environment in (defaults['nvidia_session_environment'], defaults['nvidia_hybrid_session_environment']):
            self.assertNotIn('GBM_BACKEND', environment)
            self.assertNotIn('AQ_DRM_DEVICES', environment)
        switcheroo = named(self.setup, 'Enable GPU switching on hybrid laptops')
        self.assertEqual(switcheroo['when'], 'nvidia_is_hybrid | bool')
        base = yaml.safe_load((ROOT / 'roles/base/defaults/main.yml').read_text())
        self.assertIn('switcheroo-control', base['base_required_packages'])

    def test_secure_boot_is_never_disabled(self):
        for path in (ROOT / 'roles/nvidia').rglob('*'):
            if path.is_file():
                text = path.read_text()
                self.assertNotIn('--disable-validation', text, path)
                self.assertNotIn('nouveau.modeset=0', text, path)


class SessionEnvironment(unittest.TestCase):
    WRAPPERS = ('image/rootfs/usr/bin/hyprland-quickshell', 'roles/desktop/templates/hyprland-quickshell.j2')

    def snippets(self):
        return [SNIPPET.search((ROOT / relative).read_text()).group(0) for relative in self.WRAPPERS]

    def test_both_session_wrappers_share_the_snippet_and_publish_it(self):
        image, checkout = self.snippets()
        self.assertEqual(image, checkout)
        for relative in self.WRAPPERS:
            text = (ROOT / relative).read_text()
            for command in ('systemctl --user import-environment', 'dbus-update-activation-environment'):
                lines = []
                for line in text.split(command, 1)[1].splitlines():
                    lines.append(line)
                    if not line.endswith('\\'):
                        break
                self.assertIn('"${nvidia_environment[@]}"', '\n'.join(lines), (relative, command))
            self.assertLess(text.index('nvidia_environment=()'), text.index('systemctl --user import-environment'))

    def evaluate(self, loaded, lines):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            module = base / 'sys/module/nvidia_drm'
            if loaded:
                module.mkdir(parents=True)
            environment_file = base / 'nvidia-session.env'
            environment_file.write_text(lines)
            snippet = self.snippets()[0].replace('/sys/module/nvidia_drm', str(module)) \
                .replace('/etc/cybexos/nvidia-session.env', str(environment_file))
            script = 'set -euo pipefail\n' + snippet + \
                'printf "%s\\n" "${nvidia_environment[@]}"\n' \
                '{ env | grep -E "^(LIBVA|__GLX|NVD|GBM|LD_)" || true; } | sort\n'
            return subprocess.run(['bash', '-c', script], text=True, capture_output=True, check=True,
                                  env={'PATH': os.environ['PATH']}).stdout

    def test_variables_apply_only_while_the_nvidia_driver_is_loaded(self):
        content = ('# comment\nLIBVA_DRIVER_NAME=nvidia\n__GLX_VENDOR_LIBRARY_NAME=nvidia\nNVD_BACKEND=direct\n'
                   'GBM_BACKEND=nvidia-drm\nLD_PRELOAD=/tmp/evil.so\nNVD_BACKEND=$(touch /tmp/x)\n')
        output = self.evaluate(True, content)
        self.assertIn('LIBVA_DRIVER_NAME=nvidia', output)
        self.assertIn('__GLX_VENDOR_LIBRARY_NAME=nvidia', output)
        self.assertIn('NVD_BACKEND=direct', output)
        self.assertNotIn('GBM_BACKEND', output)
        self.assertNotIn('LD_PRELOAD', output)
        self.assertNotIn('touch', output)
        self.assertEqual(self.evaluate(False, content), '\n', 'a nouveau fallback boot gets nothing')

    def test_the_role_writes_only_names_the_wrapper_accepts(self):
        defaults = yaml.safe_load((ROOT / 'roles/nvidia/defaults/main.yml').read_text())
        accepted = re.search(r'case \$name in\n\s+([A-Z_|]+)\)', self.snippets()[0]).group(1).split('|')
        for environment in (defaults['nvidia_session_environment'], defaults['nvidia_hybrid_session_environment']):
            self.assertTrue(set(environment) <= set(accepted))

    def test_login_notification_runs_from_the_shared_session_start(self):
        start = (ROOT / 'roles/desktop/files/hyprland-session-start').read_text()
        self.assertIn('nvidia_helper=/usr/local/libexec/cybexos-nvidia', start)
        self.assertIn('exec "$nvidia_helper" notify) 9>&-', start, 'the background job must drop the session lock')


class HardwareStatus(unittest.TestCase):
    def test_nvidia_outcomes_fold_into_the_hardware_state(self):
        merge = configure.merge_nvidia
        self.assertEqual(merge('completed', '', None)[:2], ('completed', ''))
        self.assertEqual(merge('completed', '', {'state': 'ready'})[:2], ('completed', ''))
        self.assertEqual(merge('completed', '', {'state': 'reboot', 'reason': 'Restart.'})[:2], ('pending', 'Restart.'))
        self.assertEqual(merge('completed', '', {'state': 'enroll', 'key': 'pending'})[0], 'pending')
        self.assertEqual(merge('completed', '', {'state': 'enroll', 'key': 'skipped', 'reason': 'Not enrolled.'})[:2],
                         ('failed', 'Not enrolled.'))
        self.assertEqual(merge('pending', 'reboot required for camera validation', {'state': 'failed', 'reason': 'x'})[:2],
                         ('failed', 'x'))
        # A camera failure keeps its own reason.
        self.assertEqual(merge('failed', 'camera', {'state': 'reboot'})[:2], ('failed', 'camera'))

    def test_a_pending_nvidia_restart_reruns_setup_on_the_next_boot(self):
        account = pwd.struct_passwd(('john', 'x', 1000, 1000, '', '/home/john', '/usr/bin/fish'))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            provision = root / 'provision'
            provision.mkdir()
            (root / 'run/lock').mkdir(parents=True)

            def paths(value):
                return root / value.lstrip('/') if value.startswith(('/var/', '/run/')) else Path(value)
            boot = ['boot-one']
            outcomes = [{'state': 'reboot', 'reason': 'Restart to start using the NVIDIA driver.'}, {'state': 'ready'}]
            automatic = []

            def applied(*args):
                automatic.append(args[-1])
                result = root / 'var/lib/cybexos/hardware-result.json'
                result.parent.mkdir(parents=True, exist_ok=True)
                result.write_text(json.dumps({'reboot_required': False, 'camera_ready': False,
                                              'nvidia': outcomes.pop(0)}))
            with patch.object(configure, 'PROVISION', provision), patch.object(configure, 'Path', side_effect=paths), \
                 patch.object(configure.os, 'geteuid', return_value=0), \
                 patch.object(configure.os, 'uname', return_value=types.SimpleNamespace(release='kernel')), \
                 patch.object(configure, 'boot_id', side_effect=lambda: boot[0]), \
                 patch.object(configure.pwd, 'getpwall', return_value=[account]), \
                 patch.object(configure, 'drain'), \
                 patch.object(configure, 'configure', side_effect=applied) as apply, \
                 patch('sys.argv', ['configure-installed', '--hardware', '--automatic']):
                configure.main()
                status = json.loads((root / 'var/lib/cybexos/hardware-status.json').read_text())
                self.assertEqual((status['state'], status['nvidia_state']), ('pending', 'reboot'))
                configure.main()
                self.assertEqual(apply.call_count, 1, 'the same boot waits for the restart')
                boot[0] = 'boot-two'
                configure.main()
                status = json.loads((root / 'var/lib/cybexos/hardware-status.json').read_text())
                self.assertEqual((status['state'], status['nvidia_state']), ('completed', 'ready'))
                self.assertEqual(automatic, [True, True])

    def doctor_checks(self, policy, nvidia):
        with tempfile.TemporaryDirectory() as temporary:
            root, home = Path(temporary) / 'root', Path(temporary) / 'home'
            for path, value in (('etc/cybexos/hardware.json', policy),
                                ('usr/share/cybexos/build.json', {'source_revision': 'a' * 40})):
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text(json.dumps(value))

            def command(*argv):
                if argv[0] == '/usr/local/libexec/cybexos-nvidia':
                    return (0, json.dumps(nvidia)) if nvidia is not None else (127, '')
                return 0, ''
            return {entry['name']: entry for entry in doctor.collect(root, home, command)['checks']}

    def test_doctor_reports_the_driver_without_the_enrollment_password(self):
        checks = self.doctor_checks({'xps_2026': False, 'nvidia': True},
                                    {'state': 'enroll', 'key': 'pending', 'reason': 'Restart and enroll.'})
        self.assertEqual(checks['nvidia']['state'], 'pending')
        self.assertEqual(checks['nvidia']['action'], 'Restart and enroll.')
        self.assertNotEqual(checks['hardware']['state'], 'skipped')
        checks = self.doctor_checks({'nvidia': True}, {'state': 'enroll', 'key': 'skipped', 'reason': 'Run it.'})
        self.assertEqual(checks['nvidia']['state'], 'fail')
        checks = self.doctor_checks({'nvidia': True}, {'state': 'ready', 'driver_version': '615.78.08'})
        self.assertEqual((checks['nvidia']['state'], checks['nvidia']['detail']),
                         ('ok', 'NVIDIA driver 615.78.08 is active.'))
        checks = self.doctor_checks({'nvidia': True}, None)
        self.assertEqual(checks['nvidia']['state'], 'pending', 'setup has not run yet')
        checks = self.doctor_checks({'xps_2026': False, 'nvidia': False}, None)
        self.assertNotIn('nvidia', checks)
        self.assertEqual(checks['hardware']['state'], 'skipped')


class WelcomeWindow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
        cls.welcome = load('welcome_nvidia', 'image/rootfs/usr/bin/cybexos-welcome')

    def test_row_state_follows_the_status_file_and_restarts(self):
        state = self.welcome.Welcome.nvidia_state
        self.assertEqual(state({}, {}, 'b'), '')
        self.assertEqual(state({'nvidia': True}, {}, 'b'), 'pending')
        self.assertEqual(state({'nvidia': True}, {'state': 'ready', 'boot_id': 'a'}, 'b'), 'ready')
        self.assertEqual(state({'nvidia': True}, {'state': 'reboot', 'boot_id': 'b'}, 'b'), 'reboot')
        self.assertEqual(state({'nvidia': True}, {'state': 'reboot', 'boot_id': 'a'}, 'b'), 'checking')
        self.assertEqual(state({'nvidia': True}, {'state': 'enroll', 'key': 'pending', 'boot_id': 'b'}, 'b'), 'enroll')
        self.assertEqual(state({'nvidia': True}, {'state': 'enroll', 'key': 'skipped', 'boot_id': 'b'}, 'b'), 'skipped')
        self.assertEqual(state({'nvidia': True}, {'state': 'failed', 'boot_id': 'a'}, 'b'), 'failed')

    def test_password_is_shown_only_for_the_queued_key(self):
        password = self.welcome.Welcome.enrollment_password
        self.assertEqual(password({'key_sha256': 'k'}, {'key_sha256': 'k', 'password': '01234567'}), '01234567')
        self.assertEqual(password({'key_sha256': 'k'}, {'key_sha256': 'other', 'password': '01234567'}), '')
        self.assertEqual(password({'key_sha256': 'k'}, {}), '')
        self.assertEqual(password({}, {'password': '01234567'}), '')

    def test_window_shows_every_state(self):
        qml = (ROOT / 'image/rootfs/usr/share/cybexos/welcome/Main.qml').read_text()
        for state in ('ready', 'checking', 'reboot', 'enroll', 'skipped', 'failed'):
            self.assertIn(f'welcome.nvidiaState === "{state}"', qml)
        self.assertIn('welcome.nvidiaPassword', qml)
        self.assertIn('Enroll MOK', qml)


if __name__ == '__main__':
    unittest.main()
