"""The ISO installation records ./install's choices and `cybex configure` changes them."""
import contextlib
import importlib.machinery
import importlib.util
import io
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

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / 'inventory/group_vars/all.yml'


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


config = load('cybexos_config', 'image/rootfs/usr/libexec/cybexos-config')
configure = load('reconfigure_installed', 'image/rootfs/usr/libexec/cybexos-configure-installed')
target = load('reconfigure_target', 'image/live-rootfs/usr/libexec/cybexos-installer-target')


def account(name, uid, home=None):
    return pwd.struct_passwd((name, 'x', uid, uid, '', home or f'/home/{name}', '/usr/bin/fish'))


ENTRIES = [account('root', 0, '/root'), account('sddm', 990, '/var/lib/sddm'),
           account('liveuser', 1000), account('alice', 1001), account('service', 1002, '/srv/service')]


def group(gid):
    return {1001: 'alice', 1003: 'bob'}[gid]


def install_keys():
    """Key paths in ./install's generated configuration, in their order."""
    text = (ROOT / 'install').read_text()
    body = text[text.index('cat >"$temporary_config" <<EOF\n'):]
    body = body[body.index('\n') + 1:body.index('\nEOF\n')]
    keys, parent = [], None
    for indent, key in re.findall(r'^( *)([a-z0-9_]+):', body, re.MULTILINE):
        parent = key if not indent else parent
        keys.append(f'{parent}.{key}' if indent else key)
    return keys


def rendered_keys(text):
    keys, parent = [], None
    for indent, key in re.findall(r'^( *)([a-z0-9_]+):', text, re.MULTILINE):
        parent = key if not indent else parent
        keys.append(f'{parent}.{key}' if indent else key)
    return keys


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'etc/cybexos').mkdir(parents=True)
        zone = self.root / 'usr/share/zoneinfo/Europe/Amsterdam'
        zone.parent.mkdir(parents=True)
        zone.write_text('TZif')
        (self.root / 'usr/share/zoneinfo/UTC').write_text('TZif')
        (self.root / 'etc/localtime').symlink_to('../usr/share/zoneinfo/Europe/Amsterdam')
        (self.root / 'etc/hostname').write_text('studio\n')
        (self.root / 'etc/locale.conf').write_text('LANG="nl_NL.UTF-8"\n')
        (self.root / 'etc/vconsole.conf').write_text('KEYMAP="us-dvorak"\nXKBLAYOUT=us\nXKBVARIANT=dvorak\n')
        # Anaconda's chroot post script writes this placeholder before provisioning.
        self.login({'version': 1, 'user': '', 'autologin': False, 'live': False})
        self.options = dict(entries=ENTRIES, group=group, inventory=INVENTORY)

    def login(self, value):
        (self.root / 'etc/cybexos/login.json').write_text(json.dumps(value) + '\n')

    @property
    def path(self):
        return self.root / 'etc/cybexos/config.yml'

    def generate(self, **overrides):
        return config.ensure(self.root, **{**self.options, 'fresh_account': True, **overrides})


class Generation(Fixture):
    def test_installation_records_the_installed_system_in_the_install_schema(self):
        self.assertTrue(self.generate())
        text = self.path.read_text()
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o644)
        self.assertEqual(rendered_keys(text), install_keys())
        saved = yaml.safe_load(text)
        inventory = yaml.safe_load(INVENTORY.read_text())
        self.assertEqual({key: saved[key] for key in ('primary_user', 'primary_group', 'primary_home')},
                         {'primary_user': 'alice', 'primary_group': 'alice', 'primary_home': '/home/alice'})
        self.assertEqual((saved['machine_hostname'], saved['machine_timezone'], saved['machine_locale'],
                          saved['regional_locale'], saved['machine_keyboard_layout'],
                          saved['machine_keyboard_variant']),
                         ('studio', 'Europe/Amsterdam', 'nl_NL.UTF-8', 'nl_NL.UTF-8', 'us', 'dvorak'))
        self.assertEqual(saved['features'], inventory['features'])
        self.assertIs(saved['passwordless_wheel'], False)
        for key in ('passwordless_local_polkit', 'docker_sudoless',
                    'xps_2026_camera_enabled', 'allow_insecure_sccache_transport'):
            self.assertIs(saved[key], inventory[key], key)
        self.assertIs(saved['manage_system_identity'], False)
        self.assertIs(saved['manage_personal_dotfiles'], True)
        self.assertIs(saved['desktop_autologin'], False)
        self.assertEqual(config.parse(text, root=self.root, entries=ENTRIES, group=group), saved)
        self.assertNotIn('password:', text)

    def test_repair_of_an_older_installation_keeps_its_login_and_dotfile_choices(self):
        self.login({'version': 1, 'user': 'alice', 'autologin': True, 'live': False})
        self.assertTrue(self.generate(fresh_account=False))
        saved = yaml.safe_load(self.path.read_text())
        self.assertIs(saved['desktop_autologin'], True)
        self.assertIs(saved['manage_personal_dotfiles'], False)

    def test_existing_configuration_is_never_overwritten(self):
        for existing in ('file', 'symlink'):
            with self.subTest(existing=existing):
                self.path.unlink(missing_ok=True)
                if existing == 'file':
                    self.path.write_text('primary_user: kept\n')
                else:
                    self.path.symlink_to(self.root / 'missing.yml')
                self.assertFalse(self.generate())
                if existing == 'file':
                    self.assertEqual(self.path.read_text(), 'primary_user: kept\n')
                else:
                    self.assertFalse((self.root / 'missing.yml').exists())
        self.assertEqual(sorted(path.name for path in self.path.parent.iterdir()), ['config.yml', 'login.json'])

    def test_ambiguous_accounts_are_resolved_only_by_the_login_policy(self):
        entries = ENTRIES + [account('bob', 1003)]
        self.assertIsNone(config.detect(self.root, entries, group, INVENTORY))
        self.assertFalse(self.generate(entries=entries))
        self.assertFalse(self.path.exists())
        self.login({'version': 1, 'user': 'bob', 'autologin': True, 'live': False})
        detected = config.detect(self.root, entries, group, INVENTORY)
        self.assertEqual((detected['primary_user'], detected['desktop_autologin']), ('bob', True))
        self.assertIsNone(config.detect(self.root, ENTRIES[:3], group, INVENTORY))

    def test_x11_keyboard_and_unusable_identity_fall_back_safely(self):
        (self.root / 'etc/vconsole.conf').write_text('KEYMAP=cz\n')
        x11 = self.root / 'etc/X11/xorg.conf.d/00-keyboard.conf'
        x11.parent.mkdir(parents=True)
        x11.write_text('Section "InputClass"\n        Option "XkbLayout" "cz,us"\n'
                       '        Option "XkbVariant" "qwerty,"\nEndSection\n')
        (self.root / 'etc/locale.conf').write_text('LANG=C.UTF-8\n')
        (self.root / 'etc/hostname').unlink()
        (self.root / 'etc/localtime').unlink()
        (self.root / 'etc/localtime').symlink_to('../usr/share/zoneinfo/../../../etc/shadow')
        values = config.detect(self.root, ENTRIES, group, INVENTORY)
        self.assertEqual((values['machine_keyboard_layout'], values['machine_keyboard_variant']), ('cz,us', 'qwerty,'))
        self.assertEqual((values['machine_locale'], values['machine_hostname'], values['machine_timezone']),
                         ('en_US.UTF-8', 'fedora', 'UTC'))
        x11.unlink()
        values = config.detect(self.root, ENTRIES, group, INVENTORY)
        self.assertEqual((values['machine_keyboard_layout'], values['machine_keyboard_variant']), ('us', ''))

    def test_validation_rejects_incomplete_or_foreign_configurations(self):
        self.generate()
        valid = yaml.safe_load(self.path.read_text())
        options = dict(root=self.root, entries=ENTRIES, group=group)
        broken = []
        for key, value in (('passwordless_wheel', 'yes'), ('machine_hostname', '-bad host'),
                           ('primary_home', '/home/other'), ('primary_user', 'liveuser'),
                           ('machine_timezone', 'Mars/Base'), ('config_schema_version', 2)):
            broken.append({**valid, key: value})
        broken.append({key: value for key, value in valid.items() if key != 'docker_sudoless'})
        broken.append({**valid, 'features': {**valid['features'], 'unknown': True}})
        broken.append({**valid, 'extra': True})
        for document in broken:
            with self.subTest(document=document), self.assertRaises(ValueError):
                config.validate(document, **options)
        with self.assertRaises(ValueError):
            config.parse('primary_user: [unterminated\n', **options)


class InstallerTarget(Fixture):
    def setUp(self):
        super().setUp()
        (self.root / 'etc/passwd').write_text('root:x:0:0::/root:/bin/bash\nalice:x:1001:1001::/home/alice:/bin/bash\n')
        (self.root / 'etc/shadow').write_text('root:!:1::::::\nalice:fixture-hash:1::::::\n')
        self.generate()

    def test_verified_autologin_decision_updates_only_the_saved_autologin_choice(self):
        before = self.path.read_text()
        target.finalize(self.root, {'account': {'username': 'alice', 'encrypted': True}}, True)
        after = self.path.read_text()
        self.assertIs(yaml.safe_load(after)['desktop_autologin'], True)
        self.assertEqual(after, before.replace('desktop_autologin: false', 'desktop_autologin: true'))
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o644)
        target.finalize(self.root, {'account': {'username': 'alice', 'encrypted': False}}, True)
        self.assertEqual(self.path.read_text(), before)
        self.assertEqual(sorted(path.name for path in self.path.parent.iterdir()),
                         ['config.yml', 'installation.json', 'login.json'])

    def test_configuration_for_another_account_or_none_fails_closed(self):
        text = self.path.read_text().replace("primary_user: 'alice'", "primary_user: 'bob'")
        self.path.write_text(text)
        with self.assertRaises(RuntimeError):
            target.finalize(self.root, {'account': {'username': 'alice', 'encrypted': True}}, True)
        self.assertEqual(self.path.read_text(), text)
        self.path.unlink()
        with self.assertRaises(FileNotFoundError):
            target.finalize(self.root, {'account': {'username': 'alice', 'encrypted': True}}, True)
        self.assertFalse(self.path.exists())


class ConfigureInstalled(Fixture):
    def settings(self):
        return types.SimpleNamespace(
            CONFIG=self.path, render=config.render,
            parse=lambda text: config.parse(text, root=self.root, entries=ENTRIES, group=group),
            current=lambda: config.current(self.root, **self.options),
            write=lambda text, path=self.path: config.write(text, path),
            ensure=lambda **options: config.ensure(self.root, **{**self.options, **options}))

    def test_saving_autologin_requires_a_verified_encrypted_root(self):
        values = config.detect(self.root, ENTRIES, group, INVENTORY)
        values['desktop_autologin'] = True
        with patch.object(configure, 'encrypted_root', return_value=False), self.assertRaises(SystemExit):
            configure.save_config(self.settings(), config.render(values), 'alice')
        self.assertFalse(self.path.exists())
        with self.assertRaises(SystemExit):
            configure.save_config(self.settings(), config.render(values), 'bob')
        with self.assertRaises(SystemExit):
            configure.save_config(self.settings(), 'features: nope\n', 'alice')
        self.assertFalse(self.path.exists())
        with patch.object(configure, 'encrypted_root', return_value=True):
            configure.save_config(self.settings(), config.render(values), 'alice')
        self.assertIs(yaml.safe_load(self.path.read_text())['desktop_autologin'], True)
        with patch.object(configure, 'load', side_effect=FileNotFoundError):
            self.assertFalse(configure.encrypted_root())

    def test_repair_records_the_saved_login_intent(self):
        login = self.root / 'etc/cybexos/login.json'
        with patch.object(configure, 'LOGIN', login):
            configure.record_login(self.settings())
            self.assertEqual(json.loads(login.read_text())['user'], '')
            self.generate()
            self.path.write_text(self.path.read_text().replace('desktop_autologin: false', 'desktop_autologin: true'))
            configure.record_login(self.settings())
        self.assertEqual(json.loads(login.read_text()),
                         {'version': 1, 'user': 'alice', 'autologin': True, 'live': False})
        self.assertEqual(login.stat().st_mode & 0o777, 0o644)

    def run_main(self, arguments, stdin=''):
        calls = []
        settings = types.SimpleNamespace(
            ensure=lambda **options: calls.append(('ensure', options)) or True,
            CONFIG=self.path)
        entries = [account('alice', 1001)]
        def paths(value):
            return self.root / value.lstrip('/') if value.startswith('/run/') else Path(value)
        (self.root / 'run/lock').mkdir(parents=True, exist_ok=True)
        (self.root / 'provision').mkdir(exist_ok=True)
        with patch.object(configure, 'PROVISION', self.root / 'provision'), \
             patch.object(configure, 'Path', side_effect=paths), \
             patch.object(configure.os, 'geteuid', return_value=0), \
             patch.object(configure.pwd, 'getpwall', return_value=entries), \
             patch.object(configure, 'load', return_value=settings), \
             patch.object(configure, 'configure', side_effect=lambda *args: calls.append(('configure',) + args)), \
             patch.object(configure, 'retire_legacy_fish'), \
             patch.object(configure, 'save_config', side_effect=lambda *args: calls.append(('save',) + args)), \
             patch.object(configure, 'record_login', side_effect=lambda *args: calls.append(('login',))), \
             patch('sys.stdin', io.StringIO(stdin)), patch('sys.argv', ['configure-installed', *arguments]), \
             contextlib.redirect_stdout(io.StringIO()):
            configure.main()
        return settings, calls

    def test_configuration_is_recorded_before_provisioning_consumes_it(self):
        settings, calls = self.run_main(['--offline'])
        self.assertEqual([call[0] for call in calls], ['ensure', 'configure'])
        self.assertEqual(calls[0][1], {'fresh_account': True})
        self.assertEqual(calls[1][2:], (True, False, False))
        settings, calls = self.run_main(['--user', 'alice'])
        self.assertEqual([call[0] for call in calls], ['ensure', 'configure', 'login'])
        self.assertEqual(calls[0][1], {'fresh_account': False})
        settings, calls = self.run_main(['--user', 'alice', '--save-config'], 'config text')
        self.assertEqual([call[0] for call in calls], ['save', 'configure', 'login'])
        self.assertEqual(calls[0][1:], (settings, 'config text', 'alice'))


class CybexConfigure(Fixture):
    def configure(self, answers, arguments=(), interactive=True):
        replies = iter(answers)
        commands = []
        def run(command, **kwargs):
            commands.append((command, kwargs))
            return types.SimpleNamespace(returncode=0)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            status = config.main(list(arguments), read=lambda prompt: next(replies), run=run,
                                 interactive=interactive, root=self.root, **self.options)
        return status, commands, output.getvalue()

    def test_answers_are_saved_and_applied_through_the_root_helper(self):
        self.generate()
        # Docker, Tailscale, widgets, LAN ports, sudo, Polkit, sudoless Docker,
        # autologin, dotfiles, confirmation.
        status, commands, output = self.configure(['', 'n', 'no', 'y', 'n', 'y', 'maybe', 'y', '', 'n', 'yes'])
        self.assertEqual(status, 0)
        [(command, options)] = commands
        self.assertEqual(command, ['sudo', '/usr/libexec/cybexos-configure-installed',
                                   '--user', 'alice', '--save-config'])
        saved = config.parse(options['input'], root=self.root, entries=ENTRIES, group=group)
        self.assertEqual({key: saved['features'][key] for key in ('docker', 'tailscale', 'connected_widgets',
                                                                  'local_network_services')},
                         {'docker': True, 'tailscale': False, 'connected_widgets': False,
                          'local_network_services': True})
        self.assertEqual((saved['passwordless_wheel'], saved['passwordless_local_polkit'], saved['docker_sudoless'],
                          saved['desktop_autologin'], saved['manage_personal_dotfiles']),
                         (False, True, True, False, False))
        self.assertIn('Configuration summary', output)

    def test_docker_sudoless_is_not_offered_without_docker_and_cancel_applies_nothing(self):
        self.generate()
        status, commands, output = self.configure(['n', '', '', '', '', '', '', '', ''])
        self.assertEqual((status, commands), (0, []))
        self.assertNotIn('without sudo? (The docker group', output)
        self.assertIn('Configuration cancelled.', output)

    def test_check_prints_without_a_terminal_and_questions_require_one(self):
        status, commands, output = self.configure([], ['--check'], interactive=False)
        self.assertEqual((status, commands), (0, []))
        self.assertEqual(yaml.safe_load(output)['primary_user'], 'alice')
        self.assertFalse(self.path.exists())
        self.assertEqual(self.configure([], interactive=False)[:2], (2, []))

    def test_cli_dispatches_configure_and_explains_uninstall(self):
        with tempfile.TemporaryDirectory() as temporary:
            stubs = Path(temporary)
            for name in ('usr/bin/cybexos-welcome', 'usr/libexec/cybexos-config'):
                stub = stubs / name
                stub.parent.mkdir(parents=True, exist_ok=True)
                stub.write_text(f'#!/bin/sh\necho {Path(name).name} "$@"\n')
                stub.chmod(0o755)
            script = stubs / 'cybex'
            script.write_text((ROOT / 'image/rootfs/usr/bin/cybex').read_text()
                              .replace(' /usr/', f' {stubs}/usr/'))
            def cybex(*arguments):
                return subprocess.run(['bash', str(script), *arguments], capture_output=True, text=True)
            self.assertEqual(cybex('configure', '--check').stdout, 'cybexos-config --check\n')
            self.assertEqual(cybex('welcome').stdout, 'cybexos-welcome\n')
            result = cybex('uninstall')
            self.assertEqual(result.returncode, 2)
            self.assertIn('not available on a CybexOS system installed from the ISO', result.stderr)
            self.assertNotIn('Unknown command', result.stderr)
            self.assertIn('configure     Change installation choices', cybex('help').stdout)
            self.assertEqual(cybex('bogus').returncode, 2)

    def test_installation_hook_records_choices_before_seeding(self):
        hook = (ROOT / 'image/live-rootfs/usr/share/anaconda/post-scripts/90-cybexos.ks').read_text()
        self.assertLess(hook.index('/usr/libexec/cybexos-configure-installed --offline'),
                        hook.index('restorecon -RF /etc/cybexos\n/usr/libexec/cybexos-seed-installed-users'))
        self.assertLess(hook.index('cybexos-configure-installed --offline'), hook.index('\n/usr/libexec/cybexos-installer-target\n'))
        self.assertTrue(os.access(ROOT / 'image/rootfs/usr/libexec/cybexos-config', os.X_OK))


if __name__ == '__main__':
    unittest.main()
