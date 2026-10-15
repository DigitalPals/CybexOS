"""Compare real checkout configuration with the ISO's installed policy."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import unittest

import yaml

from test_reconfigure import Fixture, ROOT, config, target


class InstallationParity(Fixture):
    def setUp(self):
        super().setUp()
        self.home = self.root / 'home/alice'
        self.home.mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.installer = self.root / 'install'
        self.installer.write_text((ROOT / 'install').read_text().replace(
            'repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)',
            'repo_dir=' + shlex.quote(str(ROOT)),
        ).replace('[[ -r /etc/fedora-release ]]', 'true'))
        for name, body in {
            'getent': f"printf '%s\\n' 'alice:x:1001:1001::{self.home}:/bin/bash'",
            'id': "printf '%s\\n' alice",
            'hostnamectl': "printf '%s\\n' studio",
            'timedatectl': "printf '%s\\n' Europe/Amsterdam",
            'locale': "printf '%s\\n' LANG=nl_NL.UTF-8",
            'localectl': 'case "$*" in *X11Layout*) echo us;; *X11Variant*) echo dvorak;; esac',
            'sudo': 'echo "--check must never elevate or install" >&2; exit 97',
        }.items():
            self.command(name, body)
        self.environment = dict(os.environ, HOME=str(self.home), SUDO_USER='alice',
                                CYBEXOS_CONFIG_FILE=str(self.path),
                                PATH=f"{self.bin}:{os.environ['PATH']}", PYTHONDONTWRITEBYTECODE='1')

    def command(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def encryption(self, encrypted, *, mixed=False, fail=False):
        self.command('findmnt', "printf '%s\\n' " + shlex.quote(json.dumps({'filesystems': [
            {'source': '/dev/mapper/root[/root]', 'target': '/', 'fstype': 'btrfs'}]})))
        self.command('btrfs', 'exit 1' if fail else "cat <<'EOF'\n"
                     "Label: none  uuid: 01234567-89ab-cdef-0123-456789abcdef\n"
                     "\tTotal devices 2 FS bytes used 4096\n"
                     "\tdevid    1 size 65536 used 4096 path /dev/mapper/first\n"
                     "\tdevid    2 size 65536 used 4096 path /dev/mapper/second\nEOF")
        first = {'blockdevices': [{'type': 'crypt' if encrypted else 'part'}]}
        second = {'blockdevices': [{'type': 'part' if mixed or not encrypted else 'crypt'}]}
        self.command('lsblk', 'case "$*" in\n*first) printf "%s\\n" ' + shlex.quote(json.dumps(first))
                     + ';;\n*) printf "%s\\n" ' + shlex.quote(json.dumps(second)) + ';;\nesac')

    def test_both_paths_select_graphical_boot_without_changing_the_running_session(self):
        tasks = yaml.safe_load((ROOT / 'roles/base/tasks/services.yml').read_text())
        selected = next(task for task in tasks if task.get('name') == 'Select graphical login for the next boot')
        policy = selected['ansible.builtin.file']
        self.assertEqual(policy['path'], '/etc/systemd/system/default.target')
        self.assertEqual(policy['src'], '/usr/lib/systemd/system/graphical.target')
        self.assertIn('systemctl set-default graphical.target', (ROOT / 'image/live.ks').read_text())
        for path in ('roles/base/tasks/main.yml', 'roles/base/tasks/image.yml'):
            self.assertIn('services.yml', (ROOT / path).read_text())
        # Run the actual shared Ansible module against only disposable paths.
        units = self.root / 'units'
        units.mkdir()
        graphical, console = units / 'graphical.target', units / 'multi-user.target'
        graphical.write_text('graphical fixture\n')
        console.write_text('console fixture\n')
        default = units / 'default.target'
        default.symlink_to(console)
        active = units / 'active.target'
        active.symlink_to(console)
        policy.update(path=str(default), src=str(graphical))
        playbook = self.root / 'graphical-boot.yml'
        playbook.write_text(yaml.safe_dump([{'hosts': 'localhost', 'connection': 'local',
                                           'gather_facts': False, 'become': False, 'tasks': [selected]}]))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(playbook)],
                                text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(default.resolve(), graphical)
        self.assertEqual(active.resolve(), console, 'the running session is not isolated or restarted')

    def checkout(self, *extra, interactive=False, answers=''):
        source = self.installer
        if interactive:
            # Replace terminal detection only; feed the actual questionnaire.
            source = self.root / 'interactive-install'
            source.write_text(self.installer.read_text().replace(
                '[[ $non_interactive == false && ! -t 0 ]]', 'false'))
        result = subprocess.run(['bash', str(source), '--check',
                                 *([] if interactive else ['--non-interactive']), *extra],
                                env=self.environment, input=answers, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return yaml.safe_load(result.stdout[result.stdout.index('---\n'):])

    def installed_iso(self, encrypted):
        self.path.unlink(missing_ok=True)
        self.generate()
        (self.root / 'etc/passwd').write_text('alice:x:1001:1001::/home/alice:/usr/bin/fish\n')
        (self.root / 'etc/shadow').write_text('root:!:1::::::\n')
        target.finalize(self.root, {'account': {'username': 'alice', 'encrypted': encrypted}}, encrypted)
        value = yaml.safe_load(self.path.read_text())
        self.path.unlink()
        # Same account-scoped policy; the checkout fixture's existing home is
        # under its disposable root instead of the host's real /home/alice.
        value['primary_home'] = str(self.home)
        return value

    def test_fresh_interactive_and_noninteractive_defaults_match_iso(self):
        for encrypted in (False, True):
            with self.subTest(encrypted=encrypted):
                self.encryption(encrypted)
                expected = self.installed_iso(encrypted)
                self.assertEqual(self.checkout(), expected)
                self.assertEqual(self.checkout(interactive=True, answers='\n' * 30), expected)
                self.assertIs(expected['passwordless_wheel'], False)
                self.assertIs(expected['manage_personal_dotfiles'], True)
                self.assertIs(expected['desktop_autologin'], encrypted)
                self.assertFalse((self.root / 'etc/sudoers.d/10-wheel-nopasswd').exists())
                self.assertFalse(self.path.exists())

    def test_generic_checkout_selects_the_isos_shared_hardware_packages(self):
        from test_installed_policy import repair
        applications = repair.load_applications()
        main = yaml.safe_load((ROOT / 'roles/xps-2026/tasks/main.yml').read_text())
        imports = [dict(task) for task in main if task.get('ansible.builtin.import_tasks') == 'packages.yml']
        self.assertEqual(len(imports), 1)
        package_tasks = yaml.safe_load((ROOT / 'roles/xps-2026/tasks/packages.yml').read_text())
        # Execute the actual import/feature conditions through Ansible. Replace
        # only DNF's side effect with recording the requested package names.
        for task in package_tasks:
            selected = task.pop('ansible.builtin.dnf')['name']
            task['ansible.builtin.set_fact'] = {
                'selected_hardware_packages': '{{ selected_hardware_packages | default([]) + '
                + json.dumps(selected if isinstance(selected, list) else [selected]) + ' }}'
            }
        fixture = self.root / 'hardware-packages.yml'
        fixture.write_text(yaml.safe_dump(package_tasks))
        imports[0]['ansible.builtin.import_tasks'] = str(fixture)
        packages, _ = applications.package_names()
        for proprietary in (True, False):
            output = self.root / 'selected-hardware-packages.json'
            play = self.root / 'generic-hardware.yml'
            play.write_text(yaml.safe_dump([{
                'hosts': 'localhost', 'gather_facts': False,
                'vars': {'xps_2026_is_supported': False, 'features': {'proprietary_apps': proprietary}},
                'tasks': imports + [{'ansible.builtin.copy': {
                    'dest': str(output), 'content': '{{ selected_hardware_packages | default([]) | to_json }}',
                    'mode': '0600'}}],
            }]))
            result = subprocess.run(['ansible-playbook', '-i', 'localhost,', '-c', 'local', str(play)],
                                    capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            selected = set(json.loads(output.read_text()))
            expected = {name for task in yaml.safe_load((ROOT / 'roles/xps-2026/tasks/packages.yml').read_text())
                        if proprietary or 'features.proprietary_apps | bool' not in task.get('when', [])
                        for name in ([task['ansible.builtin.dnf']['name']]
                                     if isinstance(task['ansible.builtin.dnf']['name'], str)
                                     else task['ansible.builtin.dnf']['name'])}
            self.assertEqual(selected, expected)
            self.assertLessEqual(selected, set(packages))
            self.assertIn('alsa-sof-firmware', selected)

    def test_explicit_first_account_choices_match_on_both_paths(self):
        # An unattended seed's `config` (or a factory reset's kept choices)
        # reaches the ISO through install-choices.json; the checkout installer
        # receives the same explicit choices as a saved configuration. Both go
        # through image/installation_policy.py and must produce one outcome.
        choices = {'manage_personal_dotfiles': False, 'passwordless_local_polkit': True,
                   'features': {'steam': False, 'connected_widgets': False, 'local_network_services': True}}
        pending = self.root / 'etc/cybexos/install-choices.json'
        for encrypted in (False, True):
            with self.subTest(encrypted=encrypted):
                self.encryption(encrypted)
                pending.write_text(json.dumps({'version': 1, 'choices': choices}))
                iso = self.installed_iso(encrypted)
                self.assertFalse(pending.exists(), 'recording config.yml consumes the choices')
                # Reconfiguring applies saved choices over the shared defaults.
                self.path.write_text(yaml.safe_dump(choices))
                checkout = self.checkout('--reconfigure')
                self.path.unlink()
                self.assertEqual(checkout, iso)
                self.assertIs(iso['manage_personal_dotfiles'], False)
                self.assertIs(iso['passwordless_local_polkit'], True)
                self.assertIs(iso['features']['steam'], False)
                self.assertIs(iso['features']['local_network_services'], True)
                self.assertIs(iso['desktop_autologin'], encrypted)

    def test_first_account_choices_are_validated_by_the_shared_policy(self):
        from installation_policy import apply_choices, choices
        self.encryption(False)
        pending = self.root / 'etc/cybexos/install-choices.json'
        for invalid in ({'desktop_autologin': True}, {'passwordless_wheel': True},
                        {'features': {'unknown': True}}, {'docker_sudoless': 'yes'}):
            with self.subTest(invalid=invalid):
                pending.write_text(json.dumps({'version': 1, 'choices': invalid}))
                self.path.unlink(missing_ok=True)
                with self.assertRaises(ValueError):
                    self.generate()
                with self.assertRaises(ValueError):
                    choices(invalid)
        pending.unlink()
        defaults = config.installation_defaults(Path(ROOT / 'inventory/group_vars/all.yml'))
        # Sudoless Docker is root-equivalent and exists only with Docker selected.
        applied = apply_choices(defaults, {'docker_sudoless': True, 'features': {'docker': False}})
        self.assertIs(applied['docker_sudoless'], False)
        self.assertIs(defaults['features']['docker'], True, 'the defaults are not modified')

    def test_existing_personal_files_do_not_select_another_product_default(self):
        self.encryption(True)
        (self.home / '.gitconfig').write_text('[user]\nname = Personal\n')
        value = self.checkout(interactive=True, answers='\n' * 30)
        self.assertIs(value['manage_personal_dotfiles'], True)
        self.assertEqual((self.home / '.gitconfig').read_text(), '[user]\nname = Personal\n')

    def test_mixed_or_unverifiable_btrfs_never_selects_autologin(self):
        for options in ({'mixed': True}, {'fail': True}):
            with self.subTest(options=options):
                self.encryption(True, **options)
                self.assertIs(self.checkout()['desktop_autologin'], False)

    def test_saved_choices_survive_reuse_and_reconfiguration_defaults(self):
        self.encryption(True)
        saved = self.checkout()
        saved.update(manage_personal_dotfiles=False, desktop_autologin=False, passwordless_wheel=True)
        saved['features'].update(steam=False, connected_widgets=False, podman=False, source_builds=False)
        original = config.render(saved)
        self.path.write_text(original)
        self.assertEqual(self.checkout(), saved)
        self.assertEqual(self.checkout('--reconfigure'), saved)
        self.assertEqual(self.checkout('--reconfigure', interactive=True, answers='\n' * 30), saved)
        self.assertEqual(self.path.read_text(), original)

    def test_source_personal_seeding_preserves_edits_like_iso_seeding(self):
        from test_desktop_payload import INIT
        selected = {'Install application configuration', 'Install Voxtype configuration',
                    'Install Oh My Posh theme from the active configuration',
                    'Install feature-aware MIME defaults', 'Configure npm user prefix'}
        tasks = [task for task in yaml.safe_load((ROOT / 'roles/dotfiles/tasks/main.yml').read_text())
                 if task.get('name') in selected]
        self.assertEqual(len(tasks), len(selected))
        for task in tasks:
            task['become'] = False
            task.pop('notify', None)
            options = task.get('ansible.builtin.copy') or task['ansible.builtin.template']
            if 'src' in options and not options['src'].startswith('{{ config_repo }}'):
                directory = 'templates' if 'ansible.builtin.template' in task else 'files'
                options['src'] = str(ROOT / 'roles/dotfiles' / directory) + '/' + options['src']
        paths = ('.config/fastfetch/config.jsonc', '.config/voxtype/config.toml',
                 '.config/oh-my-posh/EDM115-newline2.omp.json', '.config/mimeapps.list', '.npmrc')
        for relative in paths:
            (self.home / relative).parent.mkdir(parents=True, exist_ok=True)
        inventory = yaml.safe_load((ROOT / 'inventory/group_vars/all.yml').read_text())
        playbook = self.root / 'personal-seed.yml'
        playbook.write_text(yaml.safe_dump([{
            'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
            'vars': {'primary_home': str(self.home), 'primary_user': 'fixture',
                     'config_repo': str(ROOT), 'manage_personal_dotfiles': True,
                     'features': inventory['features']}, 'tasks': tasks,
        }]))

        def apply():
            result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(playbook)],
                                    env=os.environ, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        apply()
        # Exercise the ISO's actual merge operation with the freshly rendered
        # shared defaults, then edit both accounts before the next application.
        seed = self.root / 'seed'
        other = self.root / 'iso-account'
        for relative in paths:
            source = self.home / relative
            (seed / relative).parent.mkdir(parents=True, exist_ok=True)
            (seed / relative).write_bytes(source.read_bytes())
        INIT.seed_applications(seed, other)
        for relative in paths:
            self.assertEqual((self.home / relative).read_bytes(), (other / relative).read_bytes())
            for home in (self.home, other):
                (home / relative).write_text('Personal configuration survives upgrades\n')
        apply()
        INIT.seed_applications(seed, other)
        for relative in paths:
            self.assertEqual((self.home / relative).read_text(), 'Personal configuration survives upgrades\n')
            self.assertEqual((self.home / relative).read_bytes(), (other / relative).read_bytes())

    def test_packaged_policy_is_the_same_source_used_by_checkout(self):
        from installation_policy import defaults
        import tempfile
        from unittest.mock import patch
        from test_installed_policy import repair
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory)
            repair.prepare(payload)
            bundled = payload / 'usr/share/cybexos/lib/installation_policy.py'
            self.assertEqual(bundled.read_bytes(), (ROOT / 'image/installation_policy.py').read_bytes())
        inventory = yaml.safe_load((ROOT / 'inventory/group_vars/all.yml').read_text())
        inventory['features']['new_unhandled_choice'] = True
        with patch.object(Path, 'read_text', return_value=yaml.safe_dump(inventory)):
            with self.assertRaisesRegex(ValueError, 'both installer schemas'):
                defaults(Path('fixture'))

    def test_chatgpt_launcher_matches_checkout_and_iso_at_native_display_scale(self):
        from desktop_payload import prepare_app_launchers
        from test_desktop_payload import INIT

        launcher = '.local/share/applications/chatgpt.desktop'
        (self.home / launcher).parent.mkdir(parents=True)
        task = next(task for task in yaml.safe_load(
            (ROOT / 'roles/dotfiles/tasks/main.yml').read_text())
            if task.get('name') == 'Install MIME defaults and desktop launchers')
        task['become'] = False
        task['loop'] = [item for item in task['loop'] if item['name'] == 'chatgpt.desktop']
        task['ansible.builtin.copy']['src'] = str(ROOT / 'roles/dotfiles/files') + '/{{ item.name }}'
        playbook = self.root / 'chatgpt-launcher.yml'
        playbook.write_text(yaml.safe_dump([{
            'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
            'vars': {'primary_home': str(self.home), 'primary_user': 'fixture',
                     'features': {'proprietary_apps': True}},
            'tasks': [task],
        }]))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(playbook)],
                                env=os.environ, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        payload = self.root / 'payload'
        prepare_app_launchers(ROOT, payload)
        iso_home = self.root / 'iso-account'
        INIT.seed_applications(payload / 'usr/share/cybexos/user-seed', iso_home)
        self.assertEqual((self.home / launcher).read_bytes(), (iso_home / launcher).read_bytes())
        self.assertIn('Exec=chatgpt --ozone-platform=wayland %U',
                      (iso_home / launcher).read_text().splitlines())

    def test_default_web_apps_are_seeded_alike_and_a_removed_one_stays_removed(self):
        import shutil
        from unittest.mock import patch
        from test_desktop_payload import INIT
        from test_installed_policy import repair

        # Both packaging paths ship every contract helper as the ISO's
        # /usr/share/cybexos/bin; the checkout installs it as ~/.local/bin.
        contract = json.loads((ROOT / 'assets/desktop-contract.json').read_text())
        self.assertIn('cybexos-webapp', contract['userHelpers'])
        self.assertIn('helpers = contract["userHelpers"]', (ROOT / 'image/package').read_text())

        # Checkout: the dotfiles role's own task, run as the account.
        task = next(task for task in yaml.safe_load((ROOT / 'roles/dotfiles/tasks/main.yml').read_text())
                    if task.get('name') == 'Seed the default web apps once')
        task['become'] = False
        task.pop('become_user')
        helper = self.home / '.local/bin/cybexos-webapp'
        helper.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'assets/scripts/cybexos-webapp', helper)
        playbook = self.root / 'webapps.yml'
        playbook.write_text(yaml.safe_dump([{
            'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
            'vars': {'primary_home': str(self.home), 'primary_user': 'fixture'}, 'tasks': [task],
        }]))
        environment = {key: value for key, value in os.environ.items() if not key.startswith('XDG_')}

        def checkout():
            result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(playbook)],
                                    env=environment, text=True, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        # ISO: the packaged helper, seeded by cybexos-user-init at login.
        payload = self.root / 'payload'
        repair.prepare(payload)
        vendor = payload / 'usr/share/cybexos'
        iso_home = self.root / 'home/iso'
        iso_home.mkdir(parents=True)

        def iso():
            with patch.dict(os.environ, {'HOME': str(iso_home), 'PATH': os.environ['PATH']}, clear=True):
                INIT.initialize(iso_home, vendor, mode='essential')

        def outcome(home):
            files = {}
            roots = [home / '.local/share/cybexos/webapps', home / '.local/share/applications']
            for path in sorted(path for root in roots for path in root.rglob('*')):
                if path.is_file() and path.name != '.lock' and (
                        path.parent.name != 'applications' or path.name.startswith('cybexos-webapp-')):
                    files[str(path.relative_to(home))] = path.read_bytes().replace(
                        str(home).encode(), b'HOME')
            return files

        def remove(home):
            subprocess.run([str(home / '.local/bin/cybexos-webapp'), 'remove', 'youtube'],
                           env={**environment, 'HOME': str(home)}, check=True,
                           capture_output=True, timeout=30)

        checkout()
        iso()
        seeded = outcome(self.home)
        self.assertEqual(seeded, outcome(iso_home))
        for identifier in ('slack', 'whatsapp', 'youtube', 'google-photos', 'x'):
            self.assertIn(f'.local/share/applications/cybexos-webapp-{identifier}.desktop', seeded)
        self.assertIn(b'Exec=HOME/.local/bin/cybexos-webapp launch slack',
                      seeded['.local/share/applications/cybexos-webapp-slack.desktop'])

        # Removing a default is a choice both paths keep across updates.
        for home in (self.home, iso_home):
            remove(home)
        checkout()
        iso()
        kept = outcome(self.home)
        self.assertEqual(kept, outcome(iso_home))
        self.assertNotIn('.local/share/applications/cybexos-webapp-youtube.desktop', kept)
        self.assertIn('.local/share/applications/cybexos-webapp-slack.desktop', kept)

    def test_a_failing_web_app_seed_never_blocks_account_initialization(self):
        import contextlib
        import io
        from unittest.mock import patch
        from test_desktop_payload import INIT

        vendor = self.root / 'vendor'
        (vendor / 'bin').mkdir(parents=True)
        (vendor / 'bin/cybexos-webapp').write_text('raise RuntimeError("broken helper")\n')
        home = self.root / 'home/broken'
        home.mkdir(parents=True)
        errors = io.StringIO()
        with patch.dict(os.environ, {'HOME': str(home), 'PATH': os.environ['PATH']}, clear=True), \
                contextlib.redirect_stderr(errors):
            INIT.initialize(home, vendor, mode='essential')
        self.assertIn('default web apps were not seeded: broken helper', errors.getvalue())
        self.assertTrue((home / '.local/bin/cybexos-webapp').is_symlink())

    def test_firewall_zone_matches_checkout_and_iso_for_each_network_choice(self):
        from xml.etree import ElementTree
        import jinja2
        from desktop_payload import prepare_defaults

        def outcome(path):
            zone = ElementTree.parse(path).getroot()
            return (zone.get('target'),
                    sorted((port.get('port'), port.get('protocol')) for port in zone.iter('port')),
                    sorted(interface.get('name') for interface in zone.iter('interface')))

        inventory = yaml.safe_load((ROOT / 'inventory/group_vars/all.yml').read_text())
        sources = {'checkout': ('roles/base/tasks/main.yml', 'Configure strict firewalld zone'),
                   'iso': ('roles/base/tasks/image.yml', 'Apply the shared workstation firewall')}
        plays, expected = [], {}
        for enabled in (False, True):
            features = {**inventory['features'], 'local_network_services': enabled}
            tasks = []
            for path, name in sources.values():
                task = next(task for task in yaml.safe_load((ROOT / path).read_text())
                            if task.get('name') == name)
                for key in ('notify', 'register'):
                    task.pop(key, None)
                template = task['ansible.builtin.template']
                template.pop('owner')
                template.pop('group')
                template['src'] = str(ROOT / 'roles/base/templates' / template['src'])
                template['dest'] = str(self.root / f'{Path(path).stem}-{enabled}.xml')
                tasks.append(task)
            plays.append({'hosts': 'localhost', 'connection': 'local', 'gather_facts': False, 'become': False,
                          'vars': {'features': features, 'firewall_zone': inventory['firewall_zone'],
                                   'firewall_ports': inventory['firewall_ports']},
                          'tasks': tasks})
            # The ISO package renders the same template into its RPM payload.
            environment = jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
            environment.filters.update(bool=bool, ternary=lambda value, yes, no: yes if value else no)
            payload = self.root / f'payload-{enabled}'
            prepare_defaults(ROOT, payload, environment, {**inventory, 'features': features})
            expected[enabled] = outcome(payload / 'usr/lib/firewalld/zones/cybexos.xml')
        playbook = self.root / 'firewall-zone.yml'
        playbook.write_text(yaml.safe_dump(plays))
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(playbook)],
                                env=os.environ, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        for enabled, packaged in expected.items():
            for path, _ in sources.values():
                self.assertEqual(outcome(self.root / f'{Path(path).stem}-{enabled}.xml'), packaged, (path, enabled))
            target, ports, _ = packaged
            self.assertEqual(target, 'DROP')
            # Printer and scanner discovery needs mDNS replies on every install.
            self.assertIn(('5353', 'udp'), ports)
            self.assertIn(('53317', 'tcp'), ports)
            self.assertEqual(('27015', 'tcp') in ports, enabled)

    def test_hotspot_profiles_keep_networkmanager_shared_zone_on_both_paths(self):
        """The Settings hotspot serves DHCP and DNS from NetworkManager's
        nm-shared zone. Both paths ship the same helper that creates it there;
        the checkout's zone adoption must skip it, and the ISO never rebinds
        profiles, so its clients get addresses on either installation."""
        import importlib.util
        import jinja2

        spec = importlib.util.spec_from_file_location(
            'parity_network_tool', ROOT / 'roles/desktop/files/quickshell/scripts/network-tool.py')
        network_tool = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(network_tool)
        settings = dict(zip(network_tool.HOTSPOT_SETTINGS[::2], network_tool.HOTSPOT_SETTINGS[1::2]))
        self.assertEqual((settings['ipv4.method'], settings['connection.zone'], settings['connection.autoconnect']),
                         ('shared', 'nm-shared', 'no'))

        uuids = {'wired': '0b1c2d3e-0000-4000-8000-000000000001', 'wifi': '0b1c2d3e-0000-4000-8000-000000000002',
                 'hotspot': network_tool.HOTSPOT_UUID, 'vpn': '0b1c2d3e-0000-4000-8000-000000000004'}
        self.command('nmcli', '\n'.join([
            'case "$*" in',
            f"  '-t -f UUID,TYPE connection show') printf '%s\\n' {uuids['wired']}:802-3-ethernet "
            f"{uuids['wifi']}:802-11-wireless {uuids['hotspot']}:802-11-wireless {uuids['vpn']}:vpn ;;",
            f"  '-g ipv4.method connection show {uuids['hotspot']}') echo shared ;;",
            "  '-g ipv4.method connection show '*) echo auto ;;",
            f"  '-g connection.zone connection show {uuids['wired']}') echo public ;;",
            f"  '-g connection.zone connection show {uuids['wifi']}') echo cybexos ;;",
            f"  '-g connection.zone connection show {uuids['hotspot']}') echo nm-shared ;;",
            'esac']))
        tasks = yaml.safe_load((ROOT / 'roles/base/tasks/main.yml').read_text())
        task = next(task for task in tasks if task.get('name') == 'Find Ethernet and Wi-Fi profiles outside the strict zone')
        environment = jinja2.Environment()
        environment.filters['quote'] = shlex.quote
        inventory = yaml.safe_load((ROOT / 'inventory/group_vars/all.yml').read_text())
        script = environment.from_string(task['ansible.builtin.shell']).render(firewall_zone=inventory['firewall_zone'])
        result = subprocess.run(['bash', '-c', script], env=self.environment, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), [uuids['wired']],
                         'only the physical profile outside the strict zone is adopted; the hotspot keeps nm-shared')

        iso_sources = [path for path in (ROOT / 'image').rglob('*')
                       if path.is_file() and '__pycache__' not in path.parts
                       and not path.name.startswith('test_') and path.suffix != '.md']
        iso_sources += [ROOT / 'roles/base/tasks/image.yml', ROOT / 'roles/base/tasks/reconcile.yml']
        rebinding = [str(path.relative_to(ROOT)) for path in iso_sources
                     if 'connection.zone' in path.read_text(errors='replace')]
        self.assertEqual(rebinding, [], 'the ISO path leaves NetworkManager profile zones to NetworkManager')

    def test_sign_in_policy_matches_checkout_and_iso_from_their_starting_points(self):
        """Same authselect features and PAM files after either installation path."""
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader(
            'cybexos_auth_policy', str(ROOT / 'roles/base/files/cybexos-auth-policy'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        policy = importlib.util.module_from_spec(spec)
        loader.exec_module(policy)

        class Authselect:
            def __init__(self, features):
                self.features = list(features)

            def __call__(self, argv):
                if argv[0] == 'restorecon':
                    return 0, '', ''
                if argv[1] == 'current':
                    return 0, 'sssd ' + ' '.join(self.features), ''
                if argv[1] == 'list-features':
                    return 0, 'with-fingerprint\nwith-mdns4\nwith-pam-u2f\n', ''
                if argv[1] == 'enable-feature':
                    self.features += [] if argv[2] in self.features else [argv[2]]
                    return 0, '', ''
                raise AssertionError(argv)

        sudo = ('#%PAM-1.0\nauth       include      system-auth\naccount    include      system-auth\n'
                'password   include      system-auth\nsession    include      system-auth\n')
        kickstart = next(line for line in (ROOT / 'image/live.ks').read_text().splitlines()
                         if line.startswith('authselect select '))
        starts = {
            # A Fedora workstation before CybexOS, after the base role's mDNS step.
            'checkout': ['with-silent-lastlog', 'with-mdns4'],
            # The ISO's kickstart selection, which installations inherit.
            'iso': [word for word in kickstart.split()[3:] if word.startswith('with')],
        }
        outcomes = {}
        for name, features in starts.items():
            root = self.root / ('sign-in-' + name)
            (root / 'etc/pam.d').mkdir(parents=True)
            (root / 'etc/pam.d/sudo').write_text(sudo)
            (root / 'usr/lib/pam.d').mkdir(parents=True)
            (root / 'usr/lib/pam.d/polkit-1').write_text(policy.POLKIT_VENDOR_DEFAULT)
            (root / policy.FPRINTD_MODULE).parent.mkdir(parents=True)
            (root / policy.FPRINTD_MODULE).write_text('fixture')
            authselect = Authselect(features)
            policy.Policy(root, authselect).apply()
            outcomes[name] = (sorted(authselect.features),
                              {path.name: path.read_text() for path in sorted((root / 'etc/pam.d').iterdir())})
        self.assertEqual(outcomes['checkout'], outcomes['iso'])
        features, files = outcomes['iso']
        self.assertIn('with-fingerprint', features)
        self.assertFalse(any(feature.startswith('with-pam-u2f') for feature in features),
                         'a profile-wide u2f feature would let a key replace the SDDM password')
        self.assertEqual(sorted(files), ['cybexos-lock', 'polkit-1', 'sudo'])


if __name__ == '__main__':
    unittest.main()
