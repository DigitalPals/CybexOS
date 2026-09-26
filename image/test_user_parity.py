"""Regressions for per-user workstation policy that ISO installations lacked."""
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

from desktop_payload import KITTY_INCLUDE, prepare_session, split_seed
from provision_payload import prepare_provision

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = yaml.safe_load((ROOT / 'inventory/group_vars/all.yml').read_text())
SHARED = {
    'roles/dotfiles/tasks/environment.yml': ('dotfiles', 'environment'),
    'roles/dotfiles/tasks/personal.yml': ('dotfiles', 'personal'),
    'roles/dotfiles/tasks/agent-skills.yml': ('dotfiles', 'agent-skills'),
    'roles/desktop/tasks/portals.yml': ('desktop', 'portals'),
    'roles/apps/tasks/voxtype-backend.yml': ('apps', 'voxtype-backend'),
}


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


INIT = load('parity_user_init', 'image/rootfs/usr/libexec/cybexos-user-init')


def tasks(relative):
    return yaml.safe_load((ROOT / relative).read_text())


def task(relative, name):
    return next(entry for entry in tasks(relative) if entry.get('name') == name)


def provision_plays():
    return tasks('image/provision.yml')[0]['tasks']


def unit(text):
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    parser.read_string(text)
    return parser


class ProvisioningContract(unittest.TestCase):
    def test_offline_gtk_task_skips_private_bus_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            attempted = root / 'bus-started'
            bus = root / 'dbus-run-session'
            bus.write_text('#!/bin/sh\nprintf attempted > "' + str(attempted) + '"\nexit 99\n')
            bus.chmod(0o755)
            gtk = dict(task('roles/dotfiles/tasks/personal.yml',
                            'Default GTK to dark until the shell applies its appearance'))
            gtk['become'] = False
            gtk['environment'] = {'PATH': str(root) + ':/usr/bin:/bin'}
            playbook = root / 'offline-gtk.yml'
            playbook.write_text(yaml.safe_dump([{
                'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
                'vars': {'primary_user': 'fixture', 'cybexos_offline': True,
                         'manage_personal_dotfiles': True},
                'tasks': [gtk, {'ansible.builtin.assert': {
                    'that': ['dotfiles_gtk_default.skipped | default(false)']}}],
            }]))
            result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(playbook)],
                                    text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(attempted.exists())

    def test_workstation_and_image_share_the_same_user_tasks(self):
        imports = {
            'roles/dotfiles/tasks/main.yml': ['environment.yml', 'personal.yml', 'agent-skills.yml'],
            'roles/desktop/tasks/main.yml': ['portals.yml'],
            'roles/apps/tasks/devtools.yml': ['voxtype-backend.yml'],
        }
        for relative, names in imports.items():
            imported = [entry.get('ansible.builtin.import_tasks') for entry in tasks(relative)]
            for name in names:
                self.assertIn(name, imported, relative)
        included = {}
        for entry in provision_plays():
            role = entry.get('ansible.builtin.include_role')
            if role and 'tasks_from' in role:
                included[(role['name'], role['tasks_from'])] = entry
        for relative, key in SHARED.items():
            self.assertIn(key, included, relative)
            # Personal and session policy is not part of the hardware-only run.
            self.assertIn('not cybexos_hardware_only | bool', str(included[key]['when']))
        voxtype = included[('apps', 'voxtype-backend')]
        self.assertIn('features.developer_tools | bool', voxtype['when'])
        self.assertTrue(voxtype['vars']['apps_voxtype_gpu_optional'])
        skills = included[('dotfiles', 'agent-skills')]
        self.assertEqual(skills['vars']['dotfiles_agent_skill_canonical'], '/usr/share/cybexos/agent-skills/cybexos')

    def test_moved_workstation_tasks_keep_their_gates(self):
        personal = 'roles/dotfiles/tasks/personal.yml'
        for name in ('Include the managed Kitty fragment without replacing user configuration',
                     'Install optional managed Git preferences',
                     'Include managed Git preferences without replacing user identity',
                     'Configure XDG user directories'):
            self.assertEqual(task(personal, name)['when'], 'manage_personal_dotfiles | bool', name)
        for name in ('Configure SSH to use the 1Password agent without private key references',
                     'Configure Brave managed policies'):
            self.assertEqual(set(task(personal, name)['when']),
                             {'manage_personal_dotfiles | bool', 'features.proprietary_apps | bool'}, name)
        self.assertIn('XDG_CODE_DIR="$HOME/Code"',
                      task(personal, 'Configure XDG user directories')['ansible.builtin.copy']['content'])
        firefox = task(personal, 'Converge only the CybexOS Firefox policy entry')
        self.assertIn('manage_personal_dotfiles', firefox['ansible.builtin.command']['argv'][1])
        # Offline targets leave GTK initialization to the first desktop login.
        gtk = task(personal, 'Default GTK to dark until the shell applies its appearance')
        self.assertIn('not cybexos_offline | default(false) | bool', gtk['when'])
        self.assertNotIn('failed_when', gtk)
        portals = task('roles/desktop/tasks/portals.yml', 'Configure portal preference without patching Fedora files')
        content = portals['ansible.builtin.copy']['content']
        self.assertIn('org.freedesktop.impl.portal.FileChooser=gtk', content)
        self.assertIn('org.freedesktop.impl.portal.Secret=gnome-keyring', content)
        environment = task('roles/dotfiles/tasks/environment.yml', 'Configure environment variables')
        self.assertEqual(environment['ansible.builtin.template']['dest'],
                         '{{ primary_home }}/.config/environment.d/10-cybexos.conf')
        # None of the shared tasks may need a running user manager offline.
        for relative in SHARED:
            self.assertNotIn('systemctl --user', (ROOT / relative).read_text(), relative)
            self.assertNotIn('scope: user', (ROOT / relative).read_text(), relative)

    def test_image_accounts_manage_personal_defaults_unless_saved_otherwise(self):
        default = next(entry for entry in provision_plays()
                       if entry.get('name') == 'Manage personal defaults on image installations by default')
        # set_fact outranks the inventory but never the saved configuration,
        # which configure-installed passes as extra vars.
        self.assertEqual(default['ansible.builtin.set_fact'], {'manage_personal_dotfiles': True})
        names = [entry.get('name') for entry in provision_plays()]
        self.assertLess(names.index('Manage personal defaults on image installations by default'),
                        names.index('Apply the shared personal defaults'))

    def test_voxtype_gpu_selection_is_optional_only_for_images(self):
        select = task('roles/apps/tasks/voxtype-backend.yml', 'Select Voxtype GPU backend')
        self.assertNotIn('become_user', select)
        self.assertIn('setup gpu --enable', select['ansible.builtin.command'])
        failed = jinja2.Environment().compile_expression(select['failed_when'].replace('| bool', '')
                                                        .replace('| default(false)', ''))
        self.assertTrue(failed(apps_voxtype_gpu_enable={'rc': 1}, apps_voxtype_gpu_optional=False))
        self.assertFalse(failed(apps_voxtype_gpu_enable={'rc': 1}, apps_voxtype_gpu_optional=True))
        self.assertFalse(failed(apps_voxtype_gpu_enable={'rc': 0}, apps_voxtype_gpu_optional=False))
        self.assertEqual(select['changed_when'], 'apps_voxtype_gpu_enable.rc == 0')

    def test_saved_features_override_the_packaged_shell_unit(self):
        block = next(entry for entry in provision_plays()
                     if entry.get('name') == 'Apply the configured desktop features to every account')
        self.assertEqual(block['when'], 'not cybexos_hardware_only | bool')
        steps = {entry['name']: entry for entry in block['block']}
        record = steps['Record the configured shell features']['ansible.builtin.copy']
        self.assertEqual(record['dest'], '/etc/systemd/user/quickshell.service.d/50-cybexos-features.conf')
        environment = jinja2.Environment(keep_trailing_newline=True)
        environment.filters.update(bool=bool, ternary=lambda value, yes, no: yes if value else no)
        for connected, developer in ((True, True), (False, True), (True, False)):
            text = environment.from_string(record['content']).render(
                features={'connected_widgets': connected, 'developer_tools': developer})
            self.assertEqual(text, '[Service]\n'
                             f'Environment=CYBEXOS_CONNECTED_WIDGETS={int(connected)}\n'
                             f'Environment=CYBEXOS_DEVELOPER_TOOLS={int(developer)}\n')
        mask = steps['Mask the Hermes bridge when connected widgets are deselected']
        self.assertEqual(mask['ansible.builtin.file']['src'], '/dev/null')
        self.assertIn('not features.connected_widgets | bool', mask['when'])
        # Only CybexOS's own mask is removed; an administrator's unit stays.
        unmask = steps['Unmask the Hermes bridge when connected widgets are selected']
        self.assertIn("image_hermes_mask.stat.lnk_source | default('') == '/dev/null'", unmask['when'])
        reload = steps["Reload the account's user manager after a feature change"]
        self.assertIn('not cybexos_offline | bool', reload['when'])

    def test_provisioning_payload_carries_every_shared_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)
            prepare_provision(ROOT, payload)
            provision = payload / 'usr/share/cybexos/provision'
            for relative in (*SHARED, 'roles/dotfiles/templates/environment.conf.j2',
                             'roles/dotfiles/files/kitty.conf', 'roles/dotfiles/files/manage-firefox-policy',
                             'roles/apps/handlers/main.yml', 'scripts/manage-agent-skills'):
                self.assertEqual((provision / relative).read_bytes(), (ROOT / relative).read_bytes(), relative)
            self.assertTrue(os.access(provision / 'scripts/manage-agent-skills', os.X_OK))
            for hardware in (False, True):
                values = {'primary_user': 'fixture', 'cybexos_offline': not hardware,
                          'cybexos_hardware_only': hardware}
                result = subprocess.run(['ansible-playbook', '-i', 'localhost,',
                                         str(provision / 'image/provision.yml'), '--syntax-check',
                                         '-e', json.dumps(values)],
                                        env={**os.environ, 'ANSIBLE_CONFIG': str(provision / 'image/provision.cfg'),
                                             'ANSIBLE_ROLES_PATH': str(provision / 'roles')},
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)


class SessionPayload(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.payload = Path(self.temporary.name) / 'payload'
        self.vendor = self.payload / 'usr/share/cybexos'
        (self.vendor / 'bin').mkdir(parents=True)
        (self.vendor / 'runtime').mkdir()

    def test_seed_uses_the_managed_kitty_fragment_and_include(self):
        prepare_session(ROOT, self.payload, INVENTORY)
        kitty = self.vendor / 'user-seed/.config/kitty'
        self.assertEqual((kitty / 'cybexos.conf').read_bytes(), (ROOT / 'roles/dotfiles/files/kitty.conf').read_bytes())
        # Exactly what blockinfile writes for the workstation task, so repair
        # recognizes a seeded kitty.conf instead of appending a second include.
        include = task('roles/dotfiles/tasks/personal.yml',
                       'Include the managed Kitty fragment without replacing user configuration')
        options = include['ansible.builtin.blockinfile']
        marker = options['marker']
        self.assertEqual(KITTY_INCLUDE, '\n'.join((marker.replace('{mark}', 'BEGIN'), options['block'],
                                                   marker.replace('{mark}', 'END'))) + '\n')
        self.assertEqual((kitty / 'kitty.conf').read_text(), KITTY_INCLUDE)
        # The theme integration expects the generated palette to be included
        # from the fragment, after its fallback colours.
        self.assertTrue((kitty / 'cybexos.conf').read_text().rstrip().endswith(
            'include ~/.local/state/cybexos/theme/kitty.conf'))

    def test_seeding_after_offline_provisioning_keeps_the_provisioned_files(self):
        prepare_session(ROOT, self.payload, INVENTORY)
        contract = json.loads((ROOT / 'assets/desktop-contract.json').read_text())
        (self.vendor / 'seed-groups.json').write_text('{"totalBytes": 0}')
        split_seed(self.vendor, contract)
        self.assertTrue((self.vendor / 'essential-seed/.config/kitty/kitty.conf').is_file())
        home = Path(self.temporary.name) / 'alice'
        kitty = home / '.config/kitty'
        kitty.mkdir(parents=True)
        # configure-installed --offline runs before the account is seeded.
        provisioned = KITTY_INCLUDE + 'font_size 14.0\n'
        (kitty / 'kitty.conf').write_text(provisioned)
        with patch.dict(os.environ, {}, clear=True):
            INIT.initialize(home, self.vendor)
        self.assertEqual((kitty / 'kitty.conf').read_text(), provisioned)
        self.assertEqual((kitty / 'cybexos.conf').read_bytes(), (ROOT / 'roles/dotfiles/files/kitty.conf').read_bytes())

    def test_packaged_agent_skill_is_linked_for_installed_accounts(self):
        prepare_session(ROOT, self.payload, INVENTORY)
        skill = self.vendor / 'agent-skills/cybexos'
        for source in (ROOT / 'agent-skills/cybexos').rglob('*'):
            if source.is_file():
                target = skill / source.relative_to(ROOT / 'agent-skills/cybexos')
                self.assertEqual(target.read_bytes(), source.read_bytes())
        home = Path(self.temporary.name) / 'alice'
        home.mkdir()
        command = [str(ROOT / 'scripts/manage-agent-skills'), 'provision', '--home', str(home), '--canonical', str(skill)]
        first = subprocess.run(command, text=True, capture_output=True, env={**os.environ, 'HOME': str(home)})
        self.assertEqual(first.returncode, 0, first.stderr)
        for slot in ('.agents', '.claude', '.codex'):
            link = home / slot / 'skills/cybexos'
            self.assertTrue(link.is_symlink(), slot)
            self.assertEqual(link.resolve(), skill.resolve())
        again = subprocess.run(command, text=True, capture_output=True, env={**os.environ, 'HOME': str(home)})
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotRegex(again.stdout, '^CHANGED:')

    def test_shell_unit_follows_the_inventory_features(self):
        prepare_session(ROOT, self.payload, INVENTORY)
        rendered = (self.payload / 'usr/lib/systemd/user/quickshell.service').read_text()
        self.assertIn('Environment=CYBEXOS_CONNECTED_WIDGETS=%d\n' % INVENTORY['features']['connected_widgets'], rendered)
        self.assertIn('Environment=CYBEXOS_DEVELOPER_TOOLS=%d\n' % INVENTORY['features']['developer_tools'], rendered)
        self.assertFalse((ROOT / 'image/rootfs/usr/lib/systemd/user/quickshell.service').exists(),
                         'a verbatim rootfs copy would ignore the inventory')
        changed = {**INVENTORY, 'features': {**INVENTORY['features'], 'connected_widgets': False}}
        prepare_session(ROOT, self.payload, changed)
        rendered = unit((self.payload / 'usr/lib/systemd/user/quickshell.service').read_text())
        self.assertEqual(rendered['Service']['ExecStart'], '/usr/share/cybexos/bin/cybexos-runtime exec quickshell')
        self.assertIn('Environment=CYBEXOS_CONNECTED_WIDGETS=0\n',
                      (self.payload / 'usr/lib/systemd/user/quickshell.service').read_text())

    def test_external_monitor_watcher_runs_only_on_detected_xps_hardware(self):
        prepare_session(ROOT, self.payload, INVENTORY)
        watcher = self.payload / 'usr/libexec/cybexos-external-monitor-toggle'
        source = ROOT / 'roles/dotfiles/templates/external-monitor-toggle.j2'
        self.assertEqual(watcher.read_bytes(), source.read_bytes())
        self.assertNotRegex(source.read_text(), r'\{\{|\{%', 'copied without rendering')
        self.assertTrue(os.access(watcher, os.X_OK))
        image_unit = unit((ROOT / 'image/rootfs/usr/lib/systemd/user/external-monitor-toggle.service').read_text())
        self.assertEqual(image_unit['Unit']['ConditionEnvironment'], 'CYBEXOS_XPS_2026=1')
        self.assertEqual(image_unit['Service']['ExecStart'], '/usr/libexec/cybexos-external-monitor-toggle')
        workstation = task('roles/desktop/tasks/main.yml', 'Install external monitor watcher unit')
        expected = unit(workstation['ansible.builtin.copy']['content'])
        for section in ('Unit', 'Service', 'Install'):
            for key, value in expected[section].items():
                if key != 'ExecStart':
                    self.assertEqual(image_unit[section][key], value, key)
        target = unit((ROOT / 'image/rootfs/usr/lib/systemd/user/hyprland-session.target').read_text())
        self.assertIn('external-monitor-toggle.service', target['Unit']['Wants'].split())
        # The session wrapper derives the flag from /etc/cybexos/hardware.json
        # and must publish it to the user manager the condition reads.
        wrapper = (ROOT / 'image/rootfs/usr/bin/hyprland-quickshell').read_text()
        imports = wrapper.split('systemctl --user import-environment', 1)[1].split('\ndbus-update', 1)[0]
        self.assertIn('CYBEXOS_XPS_2026', imports)
        self.assertLess(wrapper.index('export CYBEXOS_XPS_2026'), wrapper.index('systemctl --user import-environment'))

    def test_session_path_matches_the_workstation_environment(self):
        wrapper = (ROOT / 'image/rootfs/usr/bin/hyprland-quickshell').read_text()
        path = next(line for line in wrapper.splitlines() if line.startswith('export PATH='))
        environment = jinja2.Environment()
        environment.filters['bool'] = bool
        environment.filters['ternary'] = lambda value, yes, no: yes if value else no
        rendered = environment.from_string((ROOT / 'roles/dotfiles/templates/environment.conf.j2').read_text()).render(
            primary_home='$HOME', features=INVENTORY['features'])
        workstation = next(line for line in rendered.splitlines() if line.startswith('PATH=')).split('=', 1)[1]
        for entry in workstation.split(':'):
            self.assertIn(entry, path.split('=', 1)[1].strip('"').split(':'))


if __name__ == '__main__':
    unittest.main()
