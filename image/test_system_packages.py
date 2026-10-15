"""The checkout reads the ISO's actual package policy, including exclusions."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml
from system_packages import ROOT, contract


class SharedSystemPackages(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'image').mkdir()

    def policy(self, selections, dependencies='Requires: bash coreutils >= 9.5\n', options='--exclude-weakdeps'):
        (self.root / 'image/live.ks').write_text('%packages ' + options + '\n' + selections + '\n%end\n')
        (self.root / 'image/cybexos-desktop.spec').write_text(dependencies + '\n%description\nDesktop\n')
        return contract(self.root)

    def test_groups_constraints_and_exclusions_preserve_iso_meaning(self):
        result = self.policy('@core\nkernel\n-dracut-config-rescue\nbash # comment\n')
        self.assertEqual(result['packages'], ['bash', 'coreutils', 'kernel'])
        self.assertEqual(result['groups'], ['@core'])
        self.assertEqual(result['excluded'], ['dracut-config-rescue'])
        self.assertEqual(result['selectors'], ['@core', 'bash', 'coreutils >= 9.5', 'kernel'])
        self.assertIs(result['install_weak_deps'], False)

    def test_local_packages_are_supplied_by_checkout_roles_and_not_the_rpm_channel(self):
        result = self.policy('cybexos-desktop\n', 'Requires: cybexos-offline-apps >= 1:%{offline_version}\n'
                             'Requires: cybexos-offline-inputs = %{offline_inputs}\nRequires: bash\n')
        self.assertEqual(result['selectors'], ['bash'])

    def test_ambiguous_or_unsupported_policy_fails_before_dnf(self):
        for selected, dependencies, options in (
                ('bash\n-bash', '', '--exclude-weakdeps'),
                ('@^desktop', '', '--exclude-weakdeps'),
                ('bash*', '', '--exclude-weakdeps'),
                ('bash', 'Requires: (bash or zsh)', '--exclude-weakdeps'),
                ('bash', 'Requires: coreutils >= %{minimum}', '--exclude-weakdeps'),
                ('bash', 'Requires: coreutils >= 9\nRequires: coreutils >= 10', '--exclude-weakdeps'),
                ('bash', '', '')):
            with self.subTest(selected=selected, dependencies=dependencies, options=options), self.assertRaises(ValueError):
                self.policy(selected, dependencies, options)

    def test_real_checkout_and_compose_share_runtime_and_system_selections(self):
        result = contract()
        for name in ('python3-pyside6', 'kernel-modules-extra', 'anaconda-webui', 'sddm', 'quickshell'):
            self.assertIn(name, result['packages'])
        self.assertIn('@anaconda-tools', result['groups'])
        self.assertIn('dracut-config-rescue', result['excluded'])
        self.assertNotIn('cybexos-desktop', result['packages'])
        play = yaml.safe_load((ROOT / 'site.yml').read_text())[0]
        builder = yaml.safe_load((ROOT / 'image/applications.yml').read_text())[0]
        self.assertIs(play['module_defaults']['ansible.builtin.dnf']['install_weak_deps'], False)
        self.assertIs(builder['module_defaults']['ansible.builtin.dnf']['install_weak_deps'], False)
        self.assertIs(builder['vars']['apps_prepare_offline_payload'], True)
        prerequisite_commands = [line.strip() for line in (ROOT / 'install').read_text().splitlines()
                                 if 'sudo dnf ' in line and ' install ' in line]
        self.assertTrue(prerequisite_commands)
        for command in prerequisite_commands:
            self.assertIn('--setopt=install_weak_deps=False', command)
        tasks = yaml.safe_load((ROOT / 'roles/apps/tasks/main.yml').read_text())
        baseline = next(task for task in tasks if task.get('ansible.builtin.include_role', {}).get('tasks_from') == 'system-packages')
        self.assertIn('apps_prepare_offline_payload', baseline['when'])

    def test_initial_codec_transaction_uses_the_iso_providers_and_shared_repositories(self):
        tasks = yaml.safe_load((ROOT / 'roles/base/tasks/packages.yml').read_text())
        events = []
        for task in tasks:
            task = dict(task)
            if 'ansible.builtin.package_facts' in task:
                task.pop('ansible.builtin.package_facts')
                event = 'inventory'
            elif 'ansible.builtin.include_role' in task:
                self.assertEqual(task.pop('ansible.builtin.include_role'), {'name': 'apps', 'tasks_from': 'rpmfusion'})
                event = 'repositories'
            else:
                selection = task.pop('ansible.builtin.dnf')['name']
                task['vars'] = {'transaction_packages': selection}
                task['ansible.builtin.assert'] = {'that': [
                    "package_events == ['inventory', 'repositories']",
                    "['ffmpeg', 'fdk-aac', 'jack-audio-connection-kit', 'ocl-icd'] | difference(transaction_packages) | length == 0",
                ]}
                events.append(task)
                continue
            task['ansible.builtin.set_fact'] = {'package_events': "{{ package_events | default([]) + ['" + event + "'] }}"}
            events.append(task)
        baseline = yaml.safe_load((ROOT / 'roles/base/defaults/main.yml').read_text())
        play = self.root / 'initial-codecs.yml'
        play.write_text(yaml.safe_dump([{'hosts': 'localhost', 'gather_facts': False,
                                       'vars': baseline, 'tasks': events}]))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', '-c', 'local', str(play)],
                                capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
