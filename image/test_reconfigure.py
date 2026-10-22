"""The ISO installation records ./install's choices and `cybex configure` changes them."""
import contextlib
import importlib.machinery
import importlib.util
import io
import grp
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

import jinja2
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
    def test_legacy_detection_retains_independent_docker_access_until_reconfigured(self):
        (self.root / 'etc/group').write_text('wheel:x:10:alice\ndocker:x:998:alice,bob\n')
        self.assertTrue(config.ensure(self.root, **self.options))
        self.assertIs(yaml.safe_load(self.path.read_text())['docker_sudoless'], True)
        self.path.unlink()
        self.assertTrue(self.generate())
        self.assertIs(yaml.safe_load(self.path.read_text())['docker_sudoless'], False,
                      'fresh installation still requires explicit opt-in')

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
             patch.object(configure, 'drain'), \
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
        # offline, hardware, reconcile, automatic (boot-time hardware setup only)
        self.assertEqual(calls[1][2:], (True, False, False, False))
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
            for name in ('usr/bin/cybexos-welcome', 'usr/libexec/cybexos-config',
                         'usr/libexec/cybexos-configure-installed'):
                stub = stubs / name
                stub.parent.mkdir(parents=True, exist_ok=True)
                stub.write_text(f'#!/bin/sh\necho {Path(name).name} "$@"\n')
                stub.chmod(0o755)
            script = stubs / 'cybex'
            script.write_text((ROOT / 'image/rootfs/usr/bin/cybex').read_text()
                              .replace(' /usr/', f' {stubs}/usr/'))
            sudo = stubs / 'sudo'
            sudo.write_text('#!/bin/sh\nexec "$@"\n')
            sudo.chmod(0o755)
            environment = {**os.environ, 'PATH': f'{stubs}:' + os.environ['PATH'], 'USER': 'bob'}
            environment.pop('SUDO_USER', None)
            def cybex(*arguments):
                return subprocess.run(['bash', str(script), *arguments], env=environment,
                                      capture_output=True, text=True, timeout=10)
            self.assertEqual(cybex('configure', '--check').stdout, 'cybexos-config --check\n')
            self.assertEqual(cybex('welcome').stdout, 'cybexos-welcome\n')
            self.assertEqual(cybex('repair').stdout, 'cybexos-configure-installed --user bob\n')
            self.assertEqual(cybex('repair', '--hardware').stdout,
                             'cybexos-configure-installed --user bob --hardware\n')
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


class DockerAccessTransitions(unittest.TestCase):
    """Run the shipped policy against a disposable account database.

    Only the OS account boundary is replaced. Real subprocesses change the
    fixture's groups; the shipped policy decisions run unchanged.
    """
    def setUp(self):
        from provision_payload import prepare_provision
        self.temporary = tempfile.TemporaryDirectory(prefix='cybexos-docker-policy-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        prepare_provision(ROOT, self.root / 'payload')
        self.policy = load('docker_access_transition', 'image/library/cybexos_docker_access.py')
        shipped = self.root / 'payload/usr/share/cybexos/provision/image/library/cybexos_docker_access.py'
        self.assertEqual(shipped.read_bytes(), (ROOT / 'image/library/cybexos_docker_access.py').read_bytes())
        self.packaged_policy = load('docker_access_packaged', shipped)
        access = Path('roles/base/tasks/docker-access.yml')
        self.assertEqual((self.root / 'payload/usr/share/cybexos/provision' / access).read_bytes(),
                         (ROOT / access).read_bytes())
        self.caller = next(task['cybexos_docker_access'] for task in
                           yaml.safe_load((ROOT / access).read_text()) if 'cybexos_docker_access' in task)
        self.templates = jinja2.Environment(undefined=jinja2.StrictUndefined)
        self.templates.filters['bool'] = bool
        self.database = self.root / 'groups.json'
        self.database.write_text(json.dumps({'wheel': ['alice'], 'audio': ['alice'], 'docker': ['bob']}))
        self.marker = self.root / 'state/accounts/alice/docker'
        self.tool = self.root / 'account-tool.py'
        self.tool.write_text('''import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
groups = json.loads(path.read_text())
command, *args = sys.argv[2:]
if command == 'groupadd':
    groups[args[-1]] = []
elif command == 'usermod':
    user = args[-1]
    if '--append' not in args:
        groups = {key: [name for name in users if name != user] for key, users in groups.items()}
    groups[args[args.index('--groups') + 1]].append(user)
elif command == 'gpasswd':
    assert args[0] == '--delete'
    groups[args[2]].remove(args[1])
else:
    raise AssertionError(command)
path.write_text(json.dumps(groups))
''')
        run = subprocess.run

        def account_command(argv, **kwargs):
            self.assertIn(argv[0], ('groupadd', 'usermod', 'gpasswd'))
            return run([sys.executable, '-B', str(self.tool), str(self.database), *argv],
                       timeout=10, **kwargs)

        def docker_group(name):
            self.assertIn(name, ('docker', 'wheel'))
            values = self.groups()
            if name not in values:
                raise KeyError(name)
            return grp.struct_group((name, 'x', 998 if name == 'docker' else 10, values[name]))

        for replacement in (patch.object(self.policy.pwd, 'getpwnam', lambda name: account(name, 1001)),
                            patch.object(self.policy.grp, 'getgrnam', docker_group),
                            patch.object(self.policy.subprocess, 'run', account_command)):
            replacement.start()
            self.addCleanup(replacement.stop)

    def groups(self):
        return json.loads(self.database.read_text())

    def apply(self, enabled, **kwargs):
        return self.policy.reconcile('alice', enabled, state=self.root / 'state', **kwargs)

    def apply_saved(self, user, saved, *, reconcile=True, enabled=True, check=False,
                    direct_install=False):
        """Render the shared caller, then run its actual policy for each account."""
        values = {'base_docker_saved': saved, 'primary_user': user,
                  'features': {'docker': True}, 'docker_sudoless': enabled,
                  'cybexos_reconcile': reconcile,
                  'cybexos_docker_direct_install': direct_install}
        return self.apply_values(values, check=check)

    def apply_values(self, values, check=False):
        arguments = {key: yaml.safe_load(self.templates.from_string(value).render(**values))
                     for key, value in self.caller.items()}
        return self.policy.reconcile(**arguments, state=self.root / 'state', check=check)

    def installed_wrapper(self, user, saved, *flags):
        """Run the real installed entrypoint through its Ansible launch boundary.

        Keep argument selection, saved-file precedence and the selected-account
        override intact; only privileged OS/systemd operations are substituted.
        The rendered shared task and shipped account policy execute unchanged.
        """
        saved_path = self.root / 'etc/cybexos/config.yml'
        saved_path.parent.mkdir(parents=True, exist_ok=True)
        saved_path.write_text(yaml.safe_dump(saved))
        entries = [account('alice', 1001), account('bob', 1003)]
        results, commands = [], []

        def paths(value):
            return self.root / value.lstrip('/') if value.startswith(('/etc/', '/run/', '/var/')) else Path(value)

        def contained(command, **_options):
            commands.append(command)
            if command[0] != '/usr/bin/ansible-playbook':
                self.assertEqual(command[-2:], ['/usr/libexec/cybexos-user-init', '--essential'])
                self.assertIn(user, command)
                return
            values = yaml.safe_load(INVENTORY.read_text())
            extra = command[command.index('--extra-vars'):]
            self.assertEqual(extra[0::2], ['--extra-vars', '--extra-vars'])
            self.assertEqual(extra[1], '@' + str(saved_path))
            for text in extra[1::2]:
                values.update(yaml.safe_load(Path(text[1:]).read_text())
                              if text.startswith('@') else json.loads(text))
            self.assertEqual(values['primary_user'], user)
            self.assertEqual(values['cybexos_reconcile'], '--reconcile' in flags)
            self.assertIs(values['cybexos_docker_direct_install'], False)
            values['base_docker_saved'] = yaml.safe_load(saved_path.read_text())
            results.append(self.apply_values(values))

        (self.root / 'run/lock').mkdir(parents=True, exist_ok=True)
        settings = types.SimpleNamespace(CONFIG=saved_path, ensure=lambda **_options: False)
        with patch.object(configure, 'PROVISION', self.root / 'payload/usr/share/cybexos/provision'), \
                patch.object(configure, 'Path', side_effect=paths), \
                patch.object(configure.os, 'geteuid', return_value=0), \
                patch.object(configure.pwd, 'getpwall', return_value=entries), \
                patch.object(configure.grp, 'getgrgid', side_effect=lambda gid: types.SimpleNamespace(gr_name=group(gid))), \
                patch.object(configure, 'load', return_value=settings), \
                patch.object(configure, 'drain'), \
                patch.object(configure.signal, 'signal'), \
                patch.object(configure, 'contained', side_effect=contained), \
                patch.object(configure, 'retire_legacy_fish'), \
                patch.object(configure, 'record_login'), \
                patch('sys.argv', ['configure-installed', '--user', user, *flags]):
            configure.main()
        self.assertEqual(len(results), 1)
        self.assertEqual(len(commands), 2 if '--reconcile' in flags else 1)
        return results[0]

    def test_checkout_iso_and_reconcile_share_the_policy_and_preserve_other_groups(self):
        for entry in ('main', 'image', 'reconcile'):
            tasks = yaml.safe_load((ROOT / f'roles/base/tasks/{entry}.yml').read_text())
            imports = {task.get('ansible.builtin.import_tasks') for task in tasks}
            self.assertIn('docker-access.yml' if entry == 'reconcile' else 'accounts.yml', imports)
        accounts = yaml.safe_load((ROOT / 'roles/base/tasks/accounts.yml').read_text())
        self.assertIn('docker-access.yml', {task.get('ansible.builtin.import_tasks') for task in accounts})
        for entry, policy in (('checkout', self.policy), ('ISO configure/RPM reconciliation', self.packaged_policy)):
            with self.subTest(entry=entry):
                self.policy = policy
                self.assertTrue(self.apply(True, explicit=True)['changed'])
                self.assertTrue(self.marker.is_file())
                self.assertFalse(self.apply(True, explicit=True)['changed'])
                self.assertTrue(self.apply(False)['changed'])
                self.assertFalse(self.marker.exists())
                self.assertEqual(self.groups(), {'wheel': ['alice'], 'audio': ['alice'], 'docker': ['bob']})
                self.assertFalse(self.apply(False)['changed'])

    def test_explicit_iso_opt_out_revokes_legacy_unmarked_membership(self):
        self.database.write_text(json.dumps({**self.groups(), 'docker': ['alice', 'bob']}))
        self.assertEqual(self.apply(False), {'changed': False, 'preserved': True})
        self.assertTrue(self.apply(False, explicit=True)['changed'])
        self.assertEqual(self.groups()['docker'], ['bob'])

    def test_preexisting_administrator_grant_is_not_adopted_by_automatic_work(self):
        self.database.write_text(json.dumps({**self.groups(), 'docker': ['alice', 'bob']}))
        self.assertFalse(self.apply(True)['changed'])
        self.assertFalse(self.marker.exists())
        self.assertTrue(self.apply(False)['preserved'])
        legacy = self.root / 'state/features/docker'
        legacy.parent.mkdir(parents=True)
        legacy.write_text('managed\n')
        self.assertTrue(self.apply(False)['preserved'], 'another account cannot inherit legacy ownership')
        self.assertTrue(self.apply(False, legacy_owner=True)['changed'])

    def test_failed_revoke_retains_ownership_and_retries_without_touching_other_groups(self):
        self.apply(True, explicit=True)
        with patch.object(self.policy.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['gpasswd'])):
            with self.assertRaises(subprocess.CalledProcessError):
                self.apply(False)
        self.assertTrue(self.marker.is_file())
        self.assertIn('alice', self.groups()['docker'])
        self.assertTrue(self.apply(False)['changed'])
        self.assertEqual(self.groups(), {'wheel': ['alice'], 'audio': ['alice'], 'docker': ['bob']})

    def test_check_mode_and_missing_docker_group_are_safe(self):
        self.assertFalse(self.apply(True, check=True)['changed'])
        self.assertTrue(self.apply(True, explicit=True, check=True)['changed'])
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.groups()['docker'], ['bob'])
        self.database.write_text(json.dumps({'wheel': ['alice'], 'audio': ['alice']}))
        self.assertFalse(self.apply(False, explicit=True)['changed'])
        self.assertFalse(self.apply(True)['changed'])
        self.assertNotIn('docker', self.groups())
        self.assertTrue(self.apply(True, explicit=True)['changed'])
        self.assertEqual(self.groups(), {'wheel': ['alice'], 'audio': ['alice'], 'docker': ['alice']})

    def test_saved_primary_opt_in_never_grants_secondary_accounts_or_adopts_admin_access(self):
        saved = {'primary_user': 'alice', 'docker_sudoless': True}
        for entry, policy in (('checkout', self.policy), ('ISO/RPM', self.packaged_policy)):
            with self.subTest(entry=entry):
                self.policy = policy
                for user in ('alice', 'charlie', 'bob'):
                    self.apply_saved(user, saved)
                self.assertEqual(self.groups(),
                                 {'wheel': ['alice'], 'audio': ['alice'], 'docker': ['bob', 'alice']})
                self.assertTrue(self.marker.is_file())
                self.assertFalse((self.root / 'state/accounts/charlie/docker').exists())
                self.assertFalse((self.root / 'state/accounts/bob/docker').exists())
                # A later saved opt-out removes only the primary account's managed grant.
                for user in ('alice', 'charlie', 'bob'):
                    self.apply_saved(user, {**saved, 'docker_sudoless': False}, enabled=False)
                self.assertEqual(self.groups(),
                                 {'wheel': ['alice'], 'audio': ['alice'], 'docker': ['bob']})
                self.assertFalse(self.marker.exists())

    def test_missing_or_other_accounts_saved_choice_does_not_authorize_automatic_grants(self):
        for saved in ({}, {'primary_user': 'alice'},
                      {'primary_user': 'other', 'docker_sudoless': True}):
            with self.subTest(saved=saved):
                for user in ('alice', 'charlie', 'bob'):
                    self.assertFalse(self.apply_saved(user, saved, check=True)['changed'])
                    self.assertFalse(self.apply_saved(user, saved)['changed'])
                self.assertEqual(self.groups()['docker'], ['bob'])
                self.assertFalse((self.root / 'state/accounts').exists())

    def test_automatic_repair_keeps_account_ownership_and_scopes_legacy_ownership(self):
        self.apply(True, explicit=True)
        # Simulate drift of a previously managed membership, plus legacy ownership.
        self.database.write_text(json.dumps({**self.groups(), 'docker': ['bob']}))
        legacy = self.root / 'state/features/docker'
        legacy.parent.mkdir(parents=True)
        legacy.write_text('managed\n')
        saved = {'primary_user': 'charlie'}
        for user in ('alice', 'charlie', 'dana', 'bob'):
            self.apply_saved(user, saved)
        self.assertEqual(self.groups()['docker'], ['bob', 'alice', 'charlie'])
        self.assertFalse((self.root / 'state/accounts/dana/docker').exists())
        self.assertFalse((self.root / 'state/accounts/bob/docker').exists())

    def test_direct_checkout_opt_in_is_explicit_without_a_saved_choice(self):
        self.assertTrue(self.apply_saved('alice', {}, reconcile=False, direct_install=True)['changed'])
        self.assertTrue(self.marker.is_file())
        # A default opt-out still cannot revoke a separate administrator grant.
        legacy = self.root / 'state/features/docker'
        legacy.parent.mkdir(parents=True)
        legacy.write_text('managed\n')
        self.assertTrue(self.apply_saved('bob', {}, reconcile=False, enabled=False,
                                         direct_install=True)['preserved'])
        self.assertEqual(self.groups()['docker'], ['bob', 'alice'])

    def test_secondary_repair_needs_its_own_intent_even_with_a_legacy_machine_marker(self):
        legacy = self.root / 'state/features/docker'
        legacy.parent.mkdir(parents=True)
        for policy in (self.policy, self.packaged_policy):
            self.policy = policy
            for saved_value in (True, False):
                for legacy_present in (False, True):
                    for admin in (False, True):
                        with self.subTest(policy=policy.__name__, saved=saved_value,
                                          legacy=legacy_present, admin=admin):
                            legacy.write_text('managed\n') if legacy_present else legacy.unlink(missing_ok=True)
                            groups = {'wheel': ['alice', 'bob'], 'audio': ['alice', 'bob'],
                                      'docker': ['bob'] if admin else []}
                            self.database.write_text(json.dumps(groups))
                            saved = {'primary_user': 'alice', 'docker_sudoless': saved_value}
                            for reconcile in (False, True):
                                self.assertEqual(self.apply_saved('bob', saved, reconcile=reconcile,
                                                                  enabled=saved_value),
                                                 {'changed': False, 'preserved': admin})
                                self.assertEqual(self.groups(), groups)
                                self.assertFalse((self.root / 'state/accounts/bob/docker').exists())

    def test_actual_installed_wrapper_scopes_saved_docker_intent_for_repair_iso_and_rpm(self):
        legacy = self.root / 'state/features/docker'
        legacy.parent.mkdir(parents=True)
        legacy.write_text('managed\n')
        for policy in (self.policy, self.packaged_policy):
            self.policy = policy
            for saved_value in (True, False):
                # The installed helper must override even a stale direct-install
                # variable loaded from the saved file, after selecting Bob.
                saved = {'primary_user': 'alice', 'docker_sudoless': saved_value,
                         'cybexos_docker_direct_install': True}
                for flags in ((), ('--offline',), ('--reconcile',)):
                    for admin in (False, True):
                        with self.subTest(policy=policy.__name__, saved=saved_value,
                                          flags=flags, admin=admin):
                            groups = {'wheel': ['alice'], 'audio': ['alice', 'bob'],
                                      'docker': ['bob'] if admin else []}
                            self.database.write_text(json.dumps(groups))
                            self.assertEqual(self.installed_wrapper('bob', saved, *flags),
                                             {'changed': False, 'preserved': admin})
                            self.assertEqual(self.groups(), groups)
                            self.assertFalse((self.root / 'state/accounts/bob/docker').exists())

    def test_actual_repair_preserves_primary_opt_out_and_owned_account_convergence(self):
        legacy = self.root / 'state/features/docker'
        legacy.parent.mkdir(parents=True)
        legacy.write_text('managed\n')
        for flags in ((), ('--offline',), ('--reconcile',)):
            with self.subTest(flags=flags):
                groups = {'wheel': ['alice'], 'audio': ['alice', 'bob'], 'docker': ['alice', 'bob']}
                for legacy_present in (False, True):
                    legacy.write_text('managed\n') if legacy_present else legacy.unlink(missing_ok=True)
                    self.database.write_text(json.dumps(groups))
                    self.assertTrue(self.installed_wrapper('alice', {'primary_user': 'alice',
                                                                    'docker_sudoless': False}, *flags)['changed'])
                    self.assertEqual(self.groups(), {**groups, 'docker': ['bob']})
                # Bob's per-account ownership permits restoration after drift,
                # then revocation, even while the saved choice belongs to Alice.
                marker = self.root / 'state/accounts/bob/docker'
                marker.parent.mkdir(parents=True, exist_ok=True)
                marker.write_text('managed\n')
                self.database.write_text(json.dumps({**groups, 'docker': []}))
                self.assertTrue(self.installed_wrapper('bob', {'primary_user': 'alice',
                                                              'docker_sudoless': True}, *flags)['changed'])
                self.assertTrue(marker.is_file())
                self.assertEqual(self.groups(), {**groups, 'docker': ['bob']})
                self.assertTrue(self.installed_wrapper('bob', {'primary_user': 'alice',
                                                              'docker_sudoless': False}, *flags)['changed'])
                self.assertFalse(marker.exists())
                self.assertEqual(self.groups(), {**groups, 'docker': []})

    def test_primary_docker_group_fails_without_claiming_access_was_revoked(self):
        with patch.object(self.policy.pwd, 'getpwnam', lambda name: account(name, 998)):
            with self.assertRaisesRegex(ValueError, 'primary group'):
                self.apply(False, explicit=True)
        self.assertEqual(self.groups(), {'wheel': ['alice'], 'audio': ['alice'], 'docker': ['bob']})


if __name__ == '__main__':
    unittest.main()
