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


if __name__ == '__main__':
    unittest.main()
