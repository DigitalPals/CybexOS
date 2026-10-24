"""Exercise absent-only personal seeding and private SSH permissions."""
import importlib.machinery
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader('personal_init_checks', str(ROOT / 'lifecycle/bin/cybexos-personal-init'))
spec = importlib.util.spec_from_loader(loader.name, loader)
personal = importlib.util.module_from_spec(spec)
loader.exec_module(personal)


class PersonalInitTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='cybexos-personal-init-')
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name) / 'home'
        self.home.mkdir()
        self.defaults = ROOT / 'desktop/defaults'
        # The runtime default is copied from this source asset during packaging.
        self.defaults_fixture = Path(temporary.name) / 'defaults'
        self.defaults_fixture.mkdir()
        for name in ('fastfetch.jsonc', 'voxtype.toml'):
            (self.defaults_fixture / name).write_bytes((self.defaults / name).read_bytes())
        (self.defaults_fixture / 'prompt.json').write_bytes((ROOT / 'assets/EDM115-newline2.omp.json').read_bytes())

    def seed(self, proprietary):
        personal.initialize(self.home, self.defaults_fixture, Path('/vendor-share'), proprietary)

    def test_private_ssh_include_and_generation_following_skills(self):
        self.seed(True)
        config = self.home / '.ssh/config'
        self.assertEqual(config.read_text(), f'Include {self.defaults_fixture}/ssh.conf\n')
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(config.parent.stat().st_mode), 0o700)
        for base in ('.agents', '.claude', '.codex'):
            self.assertEqual(str((self.home / base / 'skills/cybexos').readlink()),
                             '/run/current-system/sw/share/cybexos/skill')

    def test_preserves_personal_configuration_and_user_authored_skills(self):
        self.seed(True)
        config = self.home / '.ssh/config'
        config.write_text('Host personal\n  HostName example.invalid\n')
        preference = self.home / '.config/voxtype/config.toml'
        preference.write_text('personal preference\n')
        skill = self.home / '.claude/skills/cybexos'
        skill.unlink()
        skill.mkdir()
        (skill / 'SKILL.md').write_text('User-authored skill\n')
        self.seed(True)
        self.assertEqual(config.read_text(), 'Host personal\n  HostName example.invalid\n')
        self.assertEqual(preference.read_text(), 'personal preference\n')
        self.assertEqual((skill / 'SKILL.md').read_text(), 'User-authored skill\n')

    def test_no_ssh_agent_integration_without_proprietary_choice(self):
        self.seed(False)
        self.assertFalse((self.home / '.ssh/config').exists())

    def test_developer_template_is_editable_and_preserves_personal_nvim(self):
        template = self.defaults_fixture / 'nvim'
        template.mkdir()
        (template / 'init.lua').write_text('require("config.lazy")\n')
        (template / 'init.lua').chmod(0o444)
        personal.initialize(self.home, self.defaults_fixture, Path('/vendor-share'), False, True)
        config = self.home / '.config/nvim/init.lua'
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o644)
        config.write_text('personal Neovim configuration\n')
        personal.initialize(self.home, self.defaults_fixture, Path('/vendor-share'), False, True)
        self.assertEqual(config.read_text(), 'personal Neovim configuration\n')


if __name__ == '__main__':
    unittest.main()
