"""Regressions for the installed-image policy gap found on the physical laptop."""
import configparser
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import jinja2
import yaml

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


policy = load('repository_policy', 'roles/apps/files/cybexos-repository-policy')
repair = load('repair_installed', 'image/repair-installed')
configure = load('configure_installed', 'image/rootfs/usr/libexec/cybexos-configure-installed')


class InstalledPolicy(unittest.TestCase):
    def test_automatic_hardware_checks_retry_after_a_kernel_change(self):
        import pwd
        import types
        account = pwd.struct_passwd(('john', 'x', 1000, 1000, '', '/home/john', '/usr/bin/fish'))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            provision = root / 'provision'
            provision.mkdir()
            (provision / 'policy').write_text('fixture')
            def paths(value):
                return root / value.lstrip('/') if value.startswith(('/var/', '/run/')) else Path(value)
            (root / 'run/lock').mkdir(parents=True)
            kernel = types.SimpleNamespace(release='kernel-one')
            with patch.object(configure, 'PROVISION', provision), patch.object(configure, 'Path', side_effect=paths), \
                 patch.object(configure.os, 'geteuid', return_value=0), patch.object(configure.os, 'uname', return_value=kernel), \
                 patch.object(configure.pwd, 'getpwall', return_value=[account]), patch.object(configure, 'configure') as apply, \
                 patch('sys.argv', ['configure-installed', '--hardware', '--automatic']):
                configure.main()
                configure.main()
                self.assertEqual(apply.call_count, 1)
                marker = root / 'var/lib/cybexos/hardware-configured'
                marker.rename(marker.with_name('hardware-unsupported'))
                with self.assertRaises(SystemExit):
                    configure.main()
                self.assertEqual(apply.call_count, 1)
                kernel.release = 'kernel-two'
                configure.main()
                self.assertEqual(apply.call_count, 2)
                self.assertFalse(marker.with_name('hardware-unsupported').exists())

    def test_camera_backup_and_restore_preserve_a_dangling_vendor_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'etc/v4l2-relayd.d/icamerasrc.conf'
            backup = root / 'var/lib/cybexos/backups/system/etc/v4l2-relayd.d/icamerasrc.conf'
            source.parent.mkdir(parents=True)
            backup.parent.mkdir(parents=True)
            source.symlink_to('/run/cybexos-fixture-missing-relay')
            for filename, task_name in (
                ('camera.yml', "Preserve Fedora's generic camera relay configuration"),
                ('camera-disabled.yml', "Restore Fedora's generic camera relay configuration"),
            ):
                tasks = yaml.safe_load((ROOT / 'roles/xps-2026/tasks' / filename).read_text())
                command = next(task['ansible.builtin.command']['argv'] for task in tasks if task['name'] == task_name)
                command = [str(root / arg.lstrip('/')) if arg.startswith(('/etc/', '/var/')) else arg for arg in command]
                subprocess.run(command, check=True)
                self.assertEqual(os.readlink(backup), '/run/cybexos-fixture-missing-relay')
                self.assertEqual(os.readlink(source), os.readlink(backup))
                if filename == 'camera.yml':
                    source.unlink()

    def test_session_target_can_start_services_ordered_after_graphical_session(self):
        with tempfile.TemporaryDirectory() as temporary:
            units = Path(temporary)
            target = ROOT / 'image/rootfs/usr/lib/systemd/user/hyprland-session.target'
            (units / target.name).write_text(target.read_text())
            for unit in ('graphical-session', 'graphical-session-pre'):
                (units / (unit + '.target')).write_text('[Unit]\nDescription=Fixture\n')
            for name in ('quickshell', 'hyprpolkitagent', 'hypridle', 'voxtype',
                         'hermes-menubar-bridge', 'cybexos-welcome', 'cybexos-app-seed'):
                (units / (name + '.service')).write_text(
                    '[Unit]\nAfter=graphical-session.target\n[Service]\nExecStart=/usr/bin/true\n')
            environment = {**os.environ, 'SYSTEMD_UNIT_PATH': str(units) + ':/usr/lib/systemd/user'}
            def verify():
                return subprocess.run(['systemd-analyze', '--user', 'verify', str(units / target.name)],
                                      env=environment, text=True, capture_output=True)
            result = verify()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('ordering cycle', result.stderr)
            # The same vendor ordering reproduced the pre-fix failure.
            (units / target.name).write_text(target.read_text().replace('DefaultDependencies=no', 'DefaultDependencies=yes'))
            self.assertIn('ordering cycle', verify().stderr)

    def test_repository_reconciliation_preserves_unknown_entries_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            legacy = root / 'etc/yum.repos.d/cybex-applications.repo'
            legacy.parent.mkdir(parents=True)
            original = '[openai-chatgpt]\nbaseurl=https://old.example\n[personal]\nbaseurl=https://personal.example\n'
            legacy.write_text(original)
            policies = ROOT / 'roles/apps/files'
            self.assertTrue(policy.configure(root, policies))
            self.assertFalse(policy.configure(root, policies))
            self.assertNotIn('[openai-chatgpt]', legacy.read_text())
            self.assertIn('[personal]', legacy.read_text())
            self.assertEqual((root / 'var/lib/cybexos/backups/repositories/cybex-applications.repo').read_text(), original)
            config = configparser.ConfigParser(interpolation=None)
            config.read(root / 'etc/dnf/repos.override.d/90-cybexos-vendors.repo')
            self.assertTrue(config['openai-chatgpt'].getboolean('repo_gpgcheck'))
            self.assertTrue(config['tailscale-stable'].getboolean('repo_gpgcheck'))
            self.assertTrue(all(section.getboolean('gpgcheck') for section in config.values() if section.name != 'DEFAULT'))
            (root / 'etc/yum.repos.d/chatgpt.repo').write_text('[openai-chatgpt]\ngpgcheck=0\n')
            self.assertTrue(policy.configure(root, policies))
            self.assertFalse(policy.configure(root, policies))

    def test_unsigned_policy_is_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'chatgpt.repo').write_text('[openai-chatgpt]\ngpgcheck=0\n')
            with self.assertRaises(ValueError):
                policy.configure(root / 'target', root, ['chatgpt'])
            self.assertFalse((root / 'target').exists())

    def test_image_includes_every_shared_baseline_package(self):
        packages, _ = repair.load_applications().package_names()
        baseline = yaml.safe_load((ROOT / 'roles/base/defaults/main.yml').read_text())
        self.assertTrue(set(baseline['base_required_packages']).issubset(packages))
        self.assertTrue({'nano', 'fuzzel', 'tuned-ppd', 'alsa-ucm', 'alsa-utils', 'alsa-sof-firmware',
                         'cirrus-audio-firmware', 'intel-vsc-firmware'}.issubset(packages))
        # Weak dependencies are off in the image, so firmware, microcode and
        # Fedora Workstation defaults must be named explicitly.
        self.assertTrue({'realtek-firmware', 'amd-ucode-firmware', 'microcode_ctl', 'switcheroo-control',
                         'xdg-user-dirs', 'gvfs-mtp', 'NetworkManager-openvpn-gnome', 'hplip',
                         'gstreamer1-plugin-openh264', 'ibus', 'bind-utils'}.issubset(packages))
        repositories = configparser.ConfigParser(interpolation=None)
        repositories.read(ROOT / 'image/build.repo')
        self.assertTrue(repositories['fedora-cisco-openh264'].getboolean('gpgcheck'))

    def test_installed_images_share_the_workstation_account_and_service_policy(self):
        tasks_dir = ROOT / 'roles/base/tasks'

        def flatten(name):
            for task in yaml.safe_load((tasks_dir / name).read_text()):
                if 'ansible.builtin.import_tasks' in task:
                    yield from flatten(task['ansible.builtin.import_tasks'])
                else:
                    yield task

        # The workstation and installed images apply the same task files.
        for entry in ('main.yml', 'image.yml'):
            imported = {task['ansible.builtin.import_tasks'] for task in yaml.safe_load((tasks_dir / entry).read_text())
                        if 'ansible.builtin.import_tasks' in task}
            self.assertTrue({'accounts.yml', 'mdns.yml', 'docker-activation.yml'}.issubset(imported), entry)
        image = {task['name']: task for task in flatten('image.yml')}
        workstation = {task['name']: task for task in flatten('main.yml')}
        for name in ('Enable user lingering', 'Enable user lingering in the offline installation target',
                     'Configure active local wheel Polkit authorization',
                     'Revoke passwordless local Polkit authorization when disabled',
                     'Enable Docker socket activation when requested', 'Start Docker on demand rather than at boot',
                     'Enable multicast DNS host resolution'):
            self.assertIn(name, image)
            self.assertEqual(image[name], workstation[name])
        # Anaconda's target has no logind: write the marker loginctl would.
        online = image['Enable user lingering']
        self.assertIn('loginctl enable-linger', online['ansible.builtin.command'])
        self.assertIn('not cybexos_offline', online['when'])
        offline = image['Enable user lingering in the offline installation target']['ansible.builtin.copy']
        self.assertEqual((offline['dest'], offline['owner'], offline['mode']),
                         ('/var/lib/systemd/linger/{{ primary_user }}', 'root', '0644'))
        self.assertEqual(image['Configure active local wheel Polkit authorization']['when'],
                         'passwordless_local_polkit | bool')
        inventory = yaml.safe_load((ROOT / 'inventory/group_vars/all.yml').read_text())
        self.assertIs(inventory['passwordless_local_polkit'], False)
        self.assertEqual(image['Start Docker on demand rather than at boot']['ansible.builtin.systemd_service'],
                         {'name': 'docker.service', 'enabled': False})
        self.assertFalse(any(task.get('ansible.builtin.systemd_service', {}).get('name') == 'docker.service'
                             and task['ansible.builtin.systemd_service'].get('enabled') is True
                             for task in image.values()))
        # cybex configure can deselect services the image installs for everyone.
        deselected = image['Turn off deselected image services']
        self.assertEqual({(item['unit'], item['feature']) for item in deselected['loop']},
                         {('docker.socket', 'docker'), ('docker.service', 'docker'),
                          ('tailscaled.service', 'tailscale')})
        self.assertIs(deselected['ansible.builtin.systemd_service']['enabled'], False)
        self.assertIn('not features[item.feature] | bool', deselected['when'])
        # authselect keeps a custom profile: only an existing feature is added.
        mdns = image['Enable multicast DNS host resolution']
        self.assertEqual(mdns['ansible.builtin.command']['argv'], ['authselect', 'enable-feature', 'with-mdns4'])
        self.assertIn("'with-mdns4' not in base_authselect_current.stdout.split()", mdns['when'])
        self.assertFalse(any('select' in task.get('ansible.builtin.command', {}).get('argv', [])
                             for task in image.values() if isinstance(task.get('ansible.builtin.command'), dict)))

    def test_repair_payload_uses_shared_sources_and_hardware_detection(self):
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            repair.prepare(payload)
            provision = payload / 'usr/share/cybexos/provision'
            for relative in ('roles/base/tasks/accounts.yml', 'roles/base/tasks/mdns.yml',
                             'roles/base/tasks/docker-activation.yml', 'roles/xps-2026/tasks/camera.yml',
                             'roles/dotfiles/files/fish-config.fish', 'roles/base/tasks/btrfs-scrub.yml',
                             'roles/apps/tasks/mpv.yml'):
                self.assertEqual((provision / relative).read_bytes(), (ROOT / relative).read_bytes())
            features = (payload / 'usr/share/cybexos/runtime/hypr/features.lua').read_text()
            self.assertIn('os.getenv("CYBEXOS_XPS_2026") == "1"', features)
            self.assertNotIn('{{', features)
            result = subprocess.run(['ansible-playbook', '-i', 'localhost,',
                                     str(provision / 'image/provision.yml'), '--syntax-check',
                                     '-e', '{"primary_user":"fixture","cybexos_offline":true,"cybexos_hardware_only":false}'],
                                    env={**os.environ, 'ANSIBLE_CONFIG': str(provision / 'image/provision.cfg'),
                                         'ANSIBLE_ROLES_PATH': str(provision / 'roles')},
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_localsend_ports_follow_the_application_without_enabling_other_network_services(self):
        inventory = yaml.safe_load((ROOT / 'inventory/group_vars/all.yml').read_text())
        env = jinja2.Environment(undefined=jinja2.StrictUndefined)
        env.filters['bool'] = bool
        source = (ROOT / 'roles/base/templates/cybexos-zone.xml.j2').read_text()
        rendered = env.from_string(source).render(**inventory)
        self.assertIn('port="53317" protocol="tcp"', rendered)
        self.assertIn('port="53317" protocol="udp"', rendered)
        self.assertNotIn('port="27036"', rendered)

    def test_localsend_forwards_selected_files_and_keeps_text_literal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / 'flatpak'
            binary.write_text('#!/usr/bin/python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
            binary.chmod(0o755)
            document = root / 'file with spaces.txt'
            document.write_text('fixture')
            result = subprocess.check_output(['bash', str(ROOT / 'assets/scripts/localsend'), str(document), '--text', 'a message'],
                                             env={**os.environ, 'PATH': str(root) + ':' + os.environ['PATH']}, text=True)
            self.assertEqual(json.loads(result), ['run', '--file-forwarding', 'org.localsend.localsend_app',
                                                  '@@', str(document), '@@', '--text', 'a message'])

    def test_clipboard_sharing_uses_a_description_without_clipboard_contents(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, body in (
                ('wl-paste', 'print("private fixture")'),
                ('systemd-run', 'import json,sys; print(json.dumps(sys.argv[1:]))'),
            ):
                tool = root / name
                tool.write_text('#!/usr/bin/python3\n' + body + '\n')
                tool.chmod(0o755)
            result = subprocess.check_output(['bash', str(ROOT / 'assets/scripts/localsend-share'), 'clipboard'],
                                             env={**os.environ, 'PATH': str(root) + ':' + os.environ['PATH']}, text=True)
            arguments = json.loads(result)
            self.assertIn('--description=Share clipboard via LocalSend', arguments)
            self.assertEqual(arguments[-3:], ['localsend', '--text', 'private fixture'])

    def test_configuring_a_non_admin_never_adds_wheel(self):
        import grp
        import pwd
        account = pwd.struct_passwd(('guest', 'x', 1001, 1001, '', '/home/guest', '/bin/bash'))
        def group_name(name):
            self.assertEqual(name, 'wheel')
            return grp.struct_group(('wheel', 'x', 10, ['john']))
        with patch.object(configure.grp, 'getgrnam', side_effect=group_name), \
             patch.object(configure.grp, 'getgrgid', return_value=grp.struct_group(('guest', 'x', 1001, []))), \
             patch.object(configure.subprocess, 'run') as run:
            configure.configure(account, offline=True)
        values = json.loads(run.call_args.args[0][-1])
        self.assertNotIn('wheel', values['base_account_groups'])
        self.assertTrue(values['cybexos_offline'])
        self.assertEqual(run.call_args.kwargs['env']['ANSIBLE_CONFIG'], str(configure.PROVISION / 'image/provision.cfg'))


if __name__ == '__main__':
    unittest.main()
