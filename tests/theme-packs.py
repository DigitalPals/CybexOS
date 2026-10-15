#!/usr/bin/env python3
"""Named theme packs: schema, catalogue, sharing and hostile sources.

Exercises scripts/theme_packs.py and its command line (theme-packs.py, which
`cybex theme` runs) against scratch theme roots, settings files and local Git
repositories. Nothing reaches the network or a running shell: the IPC helper
is a stub and Git sources are served over file://.
"""
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'roles/desktop/files/quickshell/scripts'
CLI = SCRIPTS / 'theme-packs.py'
sys.path.insert(0, str(SCRIPTS))
sys.dont_write_bytecode = True

import theme_packs as packs  # noqa: E402

PNG = b'\x89PNG\r\n\x1a\n' + b'\0' * 32
JPEG = b'\xff\xd8\xff\xe0' + b'\0' * 32
WEBP = b'RIFF\x10\0\0\0WEBPVP8 ' + b'\0' * 16


def theme_json(**fields):
    raw = {'schema': 1, 'name': 'Harbour', 'mode': 'dark', 'accent': '#5e81ac',
           'palette': {'background': '#202830', 'text': '#e6ecf2'}}
    raw.update(fields)
    return json.dumps(raw).encode()


class Scratch(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix='cybexos-theme-packs.'))
        self.addCleanup(shutil.rmtree, self.base, True)
        self.themes = self.base / 'data/cybexos/themes'
        self.config = self.base / 'config'
        self.home = self.base / 'home'
        self.home.mkdir()
        self.env = {**os.environ, 'HOME': str(self.home), 'XDG_CONFIG_HOME': str(self.config),
                    'XDG_DATA_HOME': str(self.base / 'data'), 'PYTHONDONTWRITEBYTECODE': '1',
                    'CYBEXOS_THEME_ROOT': str(self.themes),
                    'CYBEXOS_RUNTIME_HELPER': str(self.base / 'no-runtime')}
        self._environ = dict(os.environ)
        os.environ.update({key: self.env[key] for key in (
            'HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'CYBEXOS_THEME_ROOT')})
        self.addCleanup(self._restore)

    def _restore(self):
        os.environ.clear()
        os.environ.update(self._environ)

    def folder(self, name='source', files=None):
        directory = self.base / name
        directory.mkdir()
        for file, data in (files if files is not None else {'theme.json': theme_json()}).items():
            (directory / file).write_bytes(data)
        return directory

    def cli(self, *args, status=0, stdin=None):
        result = subprocess.run([sys.executable, '-B', str(CLI), *map(str, args)], env=self.env,
                                input=stdin, capture_output=True, text=True, cwd=self.base)
        self.assertEqual(result.returncode, status, result.stderr + result.stdout)
        return result

    def runtime_stub(self, answer=None, status=0):
        """A cybexos-runtime whose `ipc` logs its arguments and answers."""
        stub = self.base / 'runtime'
        log = self.base / 'ipc.log'
        body = f'printf "%s\\n" "$*" >>{log}\n'
        if answer is not None:
            body += f'printf "%s\\n" {json.dumps(answer)}\n'
        stub.write_text(f'#!/bin/sh\n{body}exit {status}\n')
        stub.chmod(0o755)
        self.env['CYBEXOS_RUNTIME_HELPER'] = str(stub)
        return log


class Schema(Scratch):
    def test_built_in_themes_are_valid_and_listed_first(self):
        listing = packs.catalogue()
        self.assertEqual(listing['invalid'], [])
        ids = [theme['id'] for theme in listing['themes']]
        self.assertEqual(ids[0], 'cybexos')
        self.assertGreaterEqual(len(ids), 8)
        for theme_id in ('nord', 'gruvbox', 'tokyo-night', 'catppuccin-mocha', 'catppuccin-latte',
                         'rose-pine', 'everforest', 'kanagawa'):
            self.assertIn(theme_id, ids)
        for theme in listing['themes']:
            self.assertTrue(theme['builtin'])
            self.assertEqual(theme['license'], 'MIT', theme['id'])
            self.assertTrue(theme['source'].startswith('https://'), theme['id'])
            self.assertEqual(theme['wallpaper'], '', 'built-ins carry no images')
            directory = Path(theme['path'])
            self.assertEqual(sorted(p.name for p in directory.iterdir()), ['theme.json'])
            # Stored canonically, so a re-save never churns the vendor files.
            self.assertEqual((directory / 'theme.json').read_text(), packs.canonical(theme))

    def test_the_default_theme_is_a_fresh_install(self):
        cybexos = packs.find('cybexos')
        patch = packs.settings_patch(cybexos)
        defaults = packs.APPEARANCE_DEFAULTS
        for key in ('themeMode', 'paletteMode', 'accent', 'barColorMode', 'themePalette'):
            self.assertEqual(patch[key], defaults[key], key)
        self.assertNotIn('font', patch, 'the default theme leaves the font alone')

    def test_settings_patch(self):
        nord = packs.settings_patch(packs.find('nord'))
        self.assertEqual(nord['theme'], 'nord')
        self.assertEqual(nord['paletteMode'], 'fixed')
        self.assertEqual(nord['barColorMode'], 'custom')
        self.assertEqual((nord['barCustomHue'], nord['barCustomSaturation'],
                          nord['barCustomLightness']), (220, 16, 22))
        self.assertEqual(nord['themePalette']['mode'], 'dark')
        self.assertEqual(nord['themePalette']['background'], '#2e3440')
        self.assertEqual(nord['themePalette']['textDim'], '', 'unset colours are derived')
        self.assertEqual(list(nord['themePalette']), ['mode', *packs.PALETTE_KEYS])
        preset = packs.validate(json.loads(theme_json(bar='graphite', font='plex')))
        patch = packs.settings_patch(preset, wall='theme-harbour.png')
        self.assertEqual(patch['barColorMode'], 'graphite')
        self.assertNotIn('barCustomHue', patch)
        self.assertEqual(patch['font'], 'plex')
        self.assertEqual(patch['wall'], 'theme-harbour.png')
        hsl = packs.validate(json.loads(theme_json(
            bar={'hue': 10, 'saturation': 20, 'lightness': 30})))
        self.assertEqual(packs.settings_patch(hsl)['barCustomHue'], 10)

    def test_validation_rejects_malformed_themes(self):
        bad = [
            {'name': 'x', 'mode': 'dark', 'accent': '#000000'},           # no schema
            {'schema': 2, 'name': 'x', 'mode': 'dark', 'accent': '#000000'},
            {'schema': 1, 'mode': 'dark', 'accent': '#000000'},           # no name
            {'schema': 1, 'name': '', 'mode': 'dark', 'accent': '#000000'},
            {'schema': 1, 'name': 'x' * 49, 'mode': 'dark', 'accent': '#000000'},
            {'schema': 1, 'name': 'a\nb', 'mode': 'dark', 'accent': '#000000'},
            {'schema': 1, 'name': '!!!', 'mode': 'dark', 'accent': '#000000'},
            {'schema': 1, 'name': 'x', 'id': 'Bad Id', 'mode': 'dark', 'accent': '#000000'},
            {'schema': 1, 'name': 'x', 'id': '../up', 'mode': 'dark', 'accent': '#000000'},
            {'schema': 1, 'name': 'x', 'mode': 'dim', 'accent': '#000000'},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': 'red'},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#fff'},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000', 'bar': 'neon'},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000',
             'bar': {'hue': 400, 'saturation': 1, 'lightness': 1}},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000', 'font': 'Comic Sans'},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000',
             'palette': {'background': '#000000', 'glow': '#ffffff'}},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000',
             'palette': {'text': 'white'}},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000',
             'accentSource': 'wallpaper', 'palette': {'text': '#ffffff'}},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000', 'wallpaper': '../a.png'},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000', 'wallpaper': 'a.svg'},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000', 'wallpaper': '.a.png'},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000', 'exec': 'rm -rf ~'},
            {'schema': 1, 'name': 'x', 'mode': 'dark', 'accent': '#000000', 'author': 7},
            [],
        ]
        for raw in bad:
            with self.subTest(raw=raw), self.assertRaises(packs.ThemeError):
                packs.validate(raw)

    def test_canonical_round_trip_and_ids(self):
        theme = packs.validate(json.loads(theme_json(name='Rosé Pine Moon', bar='#2E3440')))
        self.assertEqual(theme['id'], 'ros-pine-moon')
        self.assertEqual(theme['bar'], '#2e3440')
        self.assertEqual(packs.validate(json.loads(packs.canonical(theme))), theme)

    def test_images_must_be_what_they_claim(self):
        packs.check_image('a.png', PNG)
        packs.check_image('a.JPG', JPEG)
        packs.check_image('a.webp', WEBP)
        for name, data in (('a.png', JPEG), ('a.jpg', b'#!/bin/sh\n'), ('a.webp', b'RIFF0000WAVE'),
                           ('a.gif', b'GIF89a')):
            with self.subTest(name=name), self.assertRaises(packs.ThemeError):
                packs.check_image(name, data)


class Catalogue(Scratch):
    def test_user_themes_follow_built_ins_and_bad_ones_are_reported(self):
        self.themes.mkdir(parents=True)
        (self.themes / 'personal.theme').write_text('original user theme\n')
        (self.themes / '.install-abc').mkdir()
        good = self.themes / 'harbour'
        good.mkdir()
        (good / 'theme.json').write_bytes(theme_json())
        wrong = self.themes / 'misnamed'
        wrong.mkdir()
        (wrong / 'theme.json').write_bytes(theme_json())
        shadow = self.themes / 'nord'
        shadow.mkdir()
        (shadow / 'theme.json').write_bytes(theme_json(name='Nord', id='nord'))
        (self.themes / 'linked').symlink_to(good)
        listing = packs.catalogue()
        user = [theme['id'] for theme in listing['themes'] if not theme['builtin']]
        self.assertEqual(user, ['harbour'])
        self.assertEqual({entry['id'] for entry in listing['invalid']}, {'misnamed', 'nord'})
        self.assertEqual((self.themes / 'personal.theme').read_text(), 'original user theme\n')
        cli = json.loads(self.cli('list', '--json').stdout)
        self.assertEqual([entry['id'] for entry in cli['themes']][-1], 'harbour')
        self.assertIn('patch', cli['themes'][0])
        text = self.cli('list')
        self.assertIn('harbour', text.stdout)
        self.assertIn('skipped misnamed', text.stderr)


class Install(Scratch):
    def test_local_folder_with_wallpaper_and_provenance(self):
        source = self.folder(files={
            'theme.json': theme_json(wallpaper='night.png', author='Someone'),
            'night.png': PNG, 'README.md': b'# Harbour\n', 'LICENSE': b'MIT\n'})
        theme = packs.install(str(source))
        installed = self.themes / 'harbour'
        self.assertEqual(theme['id'], 'harbour')
        # Only the theme itself is installed; documentation is not copied.
        self.assertEqual(sorted(p.name for p in installed.iterdir()),
                         ['.source.json', 'night.png', 'theme.json'])
        origin = json.loads((installed / '.source.json').read_text())
        self.assertEqual(origin['type'], 'local')
        self.assertEqual(origin['source'], str(source.resolve()))
        self.assertTrue(origin['installed'].endswith('Z'))
        with self.assertRaisesRegex(packs.ThemeError, 'already installed'):
            packs.install(str(source))
        (source / 'theme.json').write_bytes(theme_json(wallpaper='night.png', accent='#123456'))
        packs.install(str(source), replace=True)
        self.assertEqual(packs.find('harbour')['accent'], '#123456')
        self.assertEqual(list(self.themes.glob('.install-*')), [], 'staging is removed')

    def test_a_built_in_id_cannot_be_taken(self):
        source = self.folder(files={'theme.json': theme_json(name='Nord')})
        with self.assertRaisesRegex(packs.ThemeError, 'built-in'):
            packs.install(str(source))

    def test_hostile_folders_are_refused_without_trace(self):
        cases = {
            'script': {'theme.json': theme_json(), 'install.sh': b'#!/bin/sh\nrm -rf ~\n'},
            'dotfile': {'theme.json': theme_json(), '.bashrc': b'evil\n'},
            'qml': {'theme.json': theme_json(), 'Bar.qml': b'import QtQuick\nItem {}\n'},
            'fake image': {'theme.json': theme_json(wallpaper='w.png'), 'w.png': b'#!/bin/sh\n'},
            'missing image': {'theme.json': theme_json(wallpaper='w.png')},
            'huge json': {'theme.json': theme_json(description='x' * 200) + b' ' * 70000},
            'no theme': {'README.md': b'hi\n'},
            'empty': {},
        }
        for label, files in cases.items():
            with self.subTest(label):
                source = self.folder(label.replace(' ', '-'), files)
                with self.assertRaises(packs.ThemeError):
                    packs.install(str(source))
        linked = self.folder('linked')
        (linked / 'w.png').symlink_to('/etc/passwd')
        (linked / 'theme.json').write_bytes(theme_json(wallpaper='w.png'))
        with self.assertRaisesRegex(packs.ThemeError, 'symbolic link'):
            packs.install(str(linked))
        fifo = self.folder('fifo')
        os.mkfifo(fifo / 'w.png')
        (fifo / 'theme.json').write_bytes(theme_json(wallpaper='w.png'))
        with self.assertRaisesRegex(packs.ThemeError, 'special files'):
            packs.install(str(fifo))
        nested = self.folder('nested')
        (nested / 'hooks').mkdir()
        (nested / 'hooks/post-checkout').write_text('#!/bin/sh\ntouch pwned\n')
        with self.assertRaisesRegex(packs.ThemeError, 'folders'):
            packs.install(str(nested))
        self.assertEqual([p.name for p in self.themes.iterdir()], [])

    def tar(self, name, members):
        path = self.base / name
        with tarfile.open(path, 'w:gz') as archive:
            for member, data in members:
                if isinstance(member, tarfile.TarInfo):
                    archive.addfile(member, io.BytesIO(data) if data is not None else None)
                    continue
                info = tarfile.TarInfo(member)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        return path

    def test_archives(self):
        good = self.tar('good.tar.gz', [('harbour/theme.json', theme_json(wallpaper='w.jpg')),
                                        ('harbour/w.jpg', JPEG), ('harbour/LICENSE', b'MIT\n')])
        self.assertEqual(packs.install(str(good))['wallpaper'], 'w.jpg')
        flat = self.base / 'flat.zip'
        with zipfile.ZipFile(flat, 'w') as archive:
            archive.writestr('theme.json', theme_json(name='Flat'))
            archive.writestr('__MACOSX/._theme.json', b'junk')
        self.assertEqual(packs.install(str(flat))['id'], 'flat')

        symlink = tarfile.TarInfo('evil/theme.json')
        symlink.type, symlink.linkname = tarfile.SYMTYPE, '/etc/passwd'
        hardlink = tarfile.TarInfo('evil/w.png')
        hardlink.type, hardlink.linkname = tarfile.LNKTYPE, 'evil/theme.json'
        device = tarfile.TarInfo('evil/null')
        device.type = tarfile.CHRTYPE
        hostile = {
            'traversal': [('../../escape/theme.json', theme_json())],
            'absolute': [('/tmp/theme.json', theme_json())],
            'symlink': [(symlink, None)],
            'hardlink': [('evil/theme.json', theme_json()), (hardlink, None)],
            'device': [('evil/theme.json', theme_json()), (device, None)],
            'script': [('evil/theme.json', theme_json()), ('evil/run.sh', b'#!/bin/sh\n')],
            'many': [(f'evil/{n}.png', PNG) for n in range(70)],
            'two roots': [('a/theme.json', theme_json()), ('b/theme.json', theme_json())],
        }
        for label, members in hostile.items():
            with self.subTest(label):
                with self.assertRaises(packs.ThemeError):
                    packs.install(str(self.tar(label.replace(' ', '-') + '.tar.gz', members)))
        self.assertFalse((self.base / 'escape').exists())
        zipped = {
            'traversal': [('../theme.json', theme_json())],
            'symlink': [('theme.json', theme_json()), ('w.png', b'/etc/passwd', 0o120777)],
            'script': [('theme.json', theme_json()), ('x.py', b'print(1)\n')],
        }
        for label, entries in zipped.items():
            with self.subTest('zip ' + label):
                path = self.base / f'{label}.zip'
                with zipfile.ZipFile(path, 'w') as archive:
                    for entry in entries:
                        info = zipfile.ZipInfo(entry[0])
                        if len(entry) > 2:
                            info.external_attr = entry[2] << 16
                        archive.writestr(info, entry[1])
                with self.assertRaises(packs.ThemeError):
                    packs.install(str(path))
        bomb = self.base / 'bomb.zip'
        with zipfile.ZipFile(bomb, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('theme.json', theme_json())
            archive.writestr('w.png', PNG + b'\0' * (packs.MAX_IMAGE + 1))
        with self.assertRaisesRegex(packs.ThemeError, 'too large'):
            packs.install(str(bomb))
        self.assertEqual(sorted(p.name for p in self.themes.iterdir()), ['flat', 'harbour'])

    def test_only_https_git_sources_are_accepted(self):
        packs.check_url('https://github.com/someone/harbour-theme')
        for url in ('http://github.com/a/b', 'ssh://git@github.com/a/b', 'git@github.com:a/b',
                    'file:///etc', 'ext::sh -c touch% /tmp/pwned', 'git://github.com/a/b',
                    'https://user:secret@github.com/a/b', 'https://github.com/a/b c',
                    'https://-oProxyCommand=x/a', 'https://github.com', 'https://' + 'a' * 600):
            with self.subTest(url), self.assertRaises(packs.ThemeError):
                packs.check_url(url)
        for source in ('git@github.com:a/b', 'http://example.com/a/b', 'file:///tmp/x'):
            result = self.cli('install', source, status=1)
            self.assertIn('https://', result.stderr)


@unittest.skipUnless(shutil.which('git'), 'git is not installed')
class GitInstall(Scratch):
    def repository(self, files, extra=None):
        source = self.base / 'repository'
        source.mkdir()
        git = ['git', '-C', str(source), '-c', 'user.email=t@example.invalid', '-c', 'user.name=T']
        subprocess.run(git[:3] + ['init', '-q', '-b', 'main'], check=True)
        subprocess.run(git[:3] + ['config', 'uploadpack.allowFilter', 'true'], check=True)
        for name, data in files.items():
            (source / name).write_bytes(data)
        subprocess.run(git[:3] + ['add', '-A'], check=True)
        if extra:
            extra(source)  # stages what it adds itself
        subprocess.run(git + ['commit', '-q', '-m', 'theme'], check=True)
        commit = subprocess.run(git[:3] + ['rev-parse', 'HEAD'], check=True, text=True,
                                capture_output=True).stdout.strip()
        return 'file://' + str(source), commit

    def test_a_repository_installs_with_its_commit_recorded(self):
        # A hook of the user's own must not run either: nothing is checked out.
        url, commit = self.repository({'theme.json': theme_json(wallpaper='w.webp'), 'w.webp': WEBP,
                                       'README.md': b'# Harbour\n', '.gitignore': b'*.tmp\n'})
        hooks = self.base / 'hooks'
        hooks.mkdir()
        marker = self.base / 'hook-ran'
        for hook in ('post-checkout', 'post-merge', 'reference-transaction'):
            (hooks / hook).write_text(f'#!/bin/sh\ntouch {marker}\n')
            (hooks / hook).chmod(0o755)
        config = self.base / 'gitconfig'
        config.write_text(f'[core]\n\thooksPath = {hooks}\n')
        os.environ['GIT_CONFIG_GLOBAL'] = str(config)
        theme = packs.install(url, _allow_file_urls=True)
        installed = self.themes / theme['id']
        self.assertEqual(sorted(p.name for p in installed.iterdir()),
                         ['.source.json', 'theme.json', 'w.webp'])
        origin = json.loads((installed / '.source.json').read_text())
        self.assertEqual((origin['type'], origin['source'], origin['commit']), ('git', url, commit))
        self.assertEqual((installed / 'w.webp').read_bytes(), WEBP)
        self.assertFalse(marker.exists(), 'a hook ran during the install')
        listing = json.loads(self.cli('list', '--json').stdout)
        self.assertEqual(listing['themes'][-1]['installedFrom']['commit'], commit)

    def test_hostile_repositories_are_refused(self):
        def submodule(source):
            subprocess.run(['git', '-C', str(source), 'update-index', '--add', '--cacheinfo',
                            '160000,' + '1' * 40 + ',vendor'], check=True)

        def stage(source, name):
            subprocess.run(['git', '-C', str(source), 'add', '--', name], check=True)

        def gitmodules(source):
            (source / '.gitmodules').write_text('[submodule "x"]\n\tpath = x\n\turl = ../x\n')
            stage(source, '.gitmodules')

        def symlink(source):
            (source / 'w.png').symlink_to('/etc/passwd')
            stage(source, 'w.png')

        def nested(source):
            (source / '.githooks').mkdir()
            (source / '.githooks/post-checkout').write_text('#!/bin/sh\n')
            stage(source, '.githooks')
        cases = {
            'submodule': ({'theme.json': theme_json()}, submodule),
            'gitmodules': ({'theme.json': theme_json()}, gitmodules),
            'symlink': ({'theme.json': theme_json(wallpaper='w.png')}, symlink),
            'hooks folder': ({'theme.json': theme_json()}, nested),
            'script': ({'theme.json': theme_json(), 'post-checkout': b'#!/bin/sh\n'}, None),
            'invalid': ({'theme.json': b'{"schema": 1}'}, None),
        }
        for label, (files, extra) in cases.items():
            with self.subTest(label):
                shutil.rmtree(self.base / 'repository', ignore_errors=True)
                url, _ = self.repository(files, extra)
                with self.assertRaises(packs.ThemeError):
                    packs.install(url, _allow_file_urls=True)
        self.assertFalse(self.themes.exists() and any(
            not p.name.startswith('.') for p in self.themes.iterdir()))


class ApplyAndPersist(Scratch):
    def write_settings(self, value):
        path = self.config / 'cybexos/shell.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2) + '\n')
        return path

    def test_a_running_shell_receives_the_theme(self):
        log = self.runtime_stub('ok')
        path = self.write_settings({'v': packs.schema_version(), 'accent': '#ffffff'})
        before = path.read_text()
        self.assertIn('Applied Nord', self.cli('apply', 'nord').stdout)
        call = log.read_text().strip()
        self.assertTrue(call.startswith('ipc theme use '), call)
        payload = json.loads(call[len('ipc theme use '):])
        self.assertEqual(payload['id'], 'nord')
        self.assertEqual(payload['patch'], packs.settings_patch(packs.find('nord')))
        self.assertEqual(path.read_text(), before, 'the shell saves its own settings')

    def test_a_refusal_from_the_shell_is_reported(self):
        self.runtime_stub('error: the theme does not fit')
        path = self.write_settings({'v': packs.schema_version()})
        before = path.read_text()
        self.assertIn('does not fit', self.cli('apply', 'nord', status=1).stderr)
        self.assertEqual(path.read_text(), before)

    def test_without_a_shell_the_theme_waits_in_the_settings_file(self):
        self.runtime_stub(status=1)
        version = packs.schema_version()
        path = self.write_settings({'v': version, 'accent': '#ffffff', 'clock24': False,
                                    'futureKey': {'kept': True}})
        self.assertIn('when the shell starts', self.cli('apply', 'catppuccin-latte').stdout)
        saved = json.loads(path.read_text())
        patch = packs.settings_patch(packs.find('catppuccin-latte'))
        for key, value in patch.items():
            self.assertEqual(saved[key], value, key)
        self.assertEqual((saved['v'], saved['clock24'], saved['futureKey']),
                         (version, False, {'kept': True}))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        # No settings yet: a new sparse file at the current schema.
        path.unlink()
        self.cli('apply', 'nord')
        saved = json.loads(path.read_text())
        self.assertEqual(saved['v'], version)
        self.assertEqual(saved['theme'], 'nord')
        # A file from a newer shell is never rewritten by an older helper.
        newer = self.write_settings({'v': version + 1, 'accent': '#ffffff'})
        before = newer.read_text()
        self.assertIn('newer CybexOS', self.cli('apply', 'gruvbox', status=1).stderr)
        self.assertEqual(newer.read_text(), before)

    def test_a_theme_wallpaper_is_copied_without_replacing_files(self):
        self.runtime_stub(status=1)
        source = self.folder(files={'theme.json': theme_json(wallpaper='w.png'), 'w.png': PNG})
        packs.install(str(source))
        walls = self.base / 'walls'
        walls.mkdir()
        (walls / 'theme-harbour.png').write_bytes(JPEG)  # the user's own file
        os.mkfifo(walls / 'theme-harbour-2.png')  # never opened for reading
        self.write_settings({'v': packs.schema_version(), 'wallDir': str(walls)})
        payload = json.loads(self.cli('resolve', 'harbour').stdout)
        self.assertEqual(payload['patch']['wall'], 'theme-harbour-3.png')
        self.assertEqual((walls / 'theme-harbour.png').read_bytes(), JPEG)
        self.assertEqual((walls / 'theme-harbour-3.png').read_bytes(), PNG)
        # Applying again reuses the identical copy.
        again = json.loads(self.cli('resolve', 'harbour', '--wall-dir', walls).stdout)
        self.assertEqual(again['patch']['wall'], 'theme-harbour-3.png')
        self.assertEqual(sorted(p.name for p in walls.iterdir()),
                         ['theme-harbour-2.png', 'theme-harbour-3.png', 'theme-harbour.png'])
        self.cli('apply', 'harbour')
        self.assertEqual(json.loads((self.config / 'cybexos/shell.json').read_text())['wall'],
                         'theme-harbour-3.png')

    def test_unknown_themes_and_resolve_errors(self):
        self.assertIn('no theme called', self.cli('apply', 'missing', status=1).stderr)
        self.assertEqual(json.loads(self.cli('resolve', 'missing', status=1).stdout)['error'][:13],
                         'no theme call')


class ShareAndSave(Scratch):
    def test_export_install_round_trip_for_a_theme(self):
        exported = self.base / 'out'
        self.assertIn('Exported Nord', self.cli('export', 'nord', exported).stdout)
        self.assertEqual(sorted(p.name for p in (exported / 'nord').iterdir()), ['theme.json'])
        self.cli('export', 'nord', exported, status=1)  # never overwrites
        archive = self.base / 'share/nord.tar.gz'
        self.cli('export', 'gruvbox', archive)
        with tarfile.open(archive) as handle:
            self.assertEqual(handle.getnames(), ['gruvbox/theme.json'])
        # A built-in exported elsewhere installs under another id.
        theme = json.loads((exported / 'nord/theme.json').read_text())
        theme.update(id='my-nord', name='My Nord')
        (exported / 'nord/theme.json').write_text(json.dumps(theme))
        self.cli('install', exported / 'nord')
        mine = packs.find('my-nord')
        self.assertEqual(mine['palette'], packs.find('nord')['palette'])

    def test_export_current_carries_the_appearance_and_wallpaper(self):
        walls = self.base / 'walls'
        walls.mkdir()
        (walls / 'peak.jpg').write_bytes(JPEG)
        nord = packs.settings_patch(packs.find('nord'))
        settings = {'v': packs.schema_version(), **nord, 'accent': '#ABCDEF', 'font': 'plex',
                    'wall': 'peak.jpg', 'wallDir': str(walls)}
        path = self.config / 'cybexos/shell.json'
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(settings))
        self.cli('export', 'CURRENT', self.base / 'out', '--name', 'Night shift')
        folder = self.base / 'out/night-shift'
        exported = packs.validate(json.loads((folder / 'theme.json').read_text()))
        self.assertEqual(exported['accent'], '#abcdef')
        self.assertEqual(exported['font'], 'plex')
        self.assertEqual(exported['bar'], {'hue': 220, 'saturation': 16, 'lightness': 22})
        self.assertEqual(exported['palette']['background'], '#2e3440')
        self.assertEqual(exported['wallpaper'], 'wallpaper.jpg')
        self.assertEqual((folder / 'wallpaper.jpg').read_bytes(), JPEG)
        # The palette of a dark theme stays out of a light appearance.
        light = packs.theme_from_settings({**settings, 'themeMode': 'light'}, 'Light')
        self.assertEqual(light['palette'], {})
        # Installed again, the theme reproduces those settings exactly.
        installed = packs.install(str(folder))
        patch = packs.settings_patch(installed)
        for key in ('themeMode', 'paletteMode', 'font', 'barColorMode', 'barCustomHue',
                    'barCustomSaturation', 'barCustomLightness', 'themePalette'):
            self.assertEqual(patch[key], settings[key], key)

    def test_save_current_from_the_shell(self):
        settings = {**packs.APPEARANCE_DEFAULTS, 'themeMode': 'light', 'paletteMode': 'fixed',
                    'accent': '#8839ef'}
        line = json.dumps(settings) + '\n'
        first = json.loads(self.cli('save', '--name', ' My theme ', stdin=line).stdout)
        second = json.loads(self.cli('save', '--name', 'My theme', stdin=line).stdout)
        self.assertEqual((first['id'], second['id']), ('my-theme', 'my-theme-2'))
        self.assertEqual(first['name'], 'My theme')
        saved = packs.find('my-theme')
        self.assertEqual((saved['mode'], saved['accent']), ('light', '#8839ef'))
        self.assertEqual(json.loads((self.themes / 'my-theme/.source.json').read_text())['type'],
                         'saved')
        for bad in ('', 'x' * 49, 'a\tb'):
            self.assertIn('error', json.loads(self.cli('save', '--name', bad, stdin=line,
                                                       status=1).stdout))
        self.assertIn('error', json.loads(self.cli('save', '--name', 'X', stdin='[1]\n',
                                                   status=1).stdout))

    def test_remove(self):
        self.cli('install', self.folder())
        log = self.runtime_stub('')
        self.assertIn('Removed harbour', self.cli('remove', 'harbour').stdout)
        self.assertFalse((self.themes / 'harbour').exists())
        self.assertEqual(log.read_text().strip(), 'ipc theme refresh')
        self.assertIn('built-in', self.cli('remove', 'nord', status=1).stderr)
        self.assertIn('no user theme', self.cli('remove', 'harbour', status=1).stderr)
        self.assertIn('not a theme id', self.cli('remove', '../data', status=1).stderr)
        self.assertTrue((self.base / 'data').exists())


if __name__ == '__main__':
    unittest.main()
