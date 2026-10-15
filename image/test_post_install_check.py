"""Source-only fixtures for the builder's post-install check; nothing is mounted."""
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest

from post_install_check import ACCOUNT, HOOK, TARGET_HELPER, check_post_install, chroot_post_script, verify_target

ROOT = Path(__file__).resolve().parent


class FakeRunner:
    """Records commands; the post script call writes what a passing run leaves."""
    def __init__(self, post_exit=0, stuck=()):
        self.commands, self.post_exit, self.stuck = [], post_exit, stuck
        self.merged = None

    def __call__(self, command, check=False, stdout=None, stderr=None):
        self.commands.append(command)
        if command[0] == 'mount' and command[1] == '-t' and command[2] == 'overlay':
            self.merged = Path(command[-1])
            for name in ('proc', 'sys', 'dev/pts', 'run', 'tmp', 'etc'):
                (self.merged / name).mkdir(parents=True, exist_ok=True)
        if command[:2] == ['chroot', str(self.merged)] and command[2] == 'useradd':
            (self.merged / 'etc/passwd').write_text(f'root:x:0:0::/root:/bin/bash\n{ACCOUNT}:x:1000:1000::/home/{ACCOUNT}:/bin/bash\n')
            (self.merged / 'etc/shadow').write_text('root:!locked::0:99999:7:::\n')
        if command[0] == 'unshare':
            stdout.write('+ /usr/libexec/cybexos-configure-installed --offline\nfatal: fixture failure\n')
            if not self.post_exit:
                (self.merged / 'var/lib/systemd/linger').mkdir(parents=True)
                (self.merged / 'var/lib/systemd/linger' / ACCOUNT).touch()
                (self.merged / 'etc/cybexos').mkdir()
                (self.merged / 'etc/cybexos/config.yml').write_text(
                    f"primary_user: '{ACCOUNT}'\ndesktop_autologin: false\npasswordless_wheel: false\n")
                (self.merged / 'etc/cybexos/hardware.json').write_text('{"xps_2026": false}\n')
            return SimpleNamespace(returncode=self.post_exit)
        if command[0] == 'umount':
            return SimpleNamespace(returncode=1 if command[-1] in self.stuck else 0)
        return SimpleNamespace(returncode=0)


def image_fixture(directory):
    image = Path(directory) / 'image'
    for relative in (HOOK, TARGET_HELPER):
        (image / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / 'live-rootfs' / relative, image / relative)
    return image


class PostInstallCheck(unittest.TestCase):
    def test_extracts_only_the_chroot_section_of_the_real_hook(self):
        body = chroot_post_script((ROOT / 'live-rootfs' / HOOK).read_text())
        self.assertIn('/usr/libexec/cybexos-configure-installed --offline', body)
        self.assertIn('dracut --force --regenerate-all', body)
        self.assertNotIn('\n/usr/libexec/cybexos-installer-target\n', body)
        with self.assertRaises(ValueError):
            chroot_post_script('%post --nochroot\ntrue\n%end\n')

    def test_passing_run_uses_an_offline_overlay_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory:
            image, work = image_fixture(directory), Path(directory) / 'work'
            work.mkdir()
            runner = FakeRunner()
            check_post_install(image, work, run=runner)
            overlay = next(command for command in runner.commands if command[:3] == ['mount', '-t', 'overlay'])
            self.assertIn(f'lowerdir={image}', overlay[5])
            post = next(command for command in runner.commands if command[0] == 'unshare')
            self.assertEqual(post[:2], ['unshare', '--net'])
            mounted = [command[-1] for command in runner.commands if command[0] == 'mount']
            unmounted = [command[-1] for command in runner.commands if command[0] == 'umount']
            self.assertEqual(unmounted, list(reversed(mounted)))
            self.assertEqual(list(work.iterdir()), [])
            # The image root is only ever a read-only overlay layer.
            self.assertEqual(sorted(str(path.relative_to(image)) for path in image.rglob('*') if path.is_file()),
                             sorted([HOOK, TARGET_HELPER]))

    def test_failed_script_reports_its_output(self):
        with tempfile.TemporaryDirectory() as directory:
            image, work = image_fixture(directory), Path(directory) / 'work'
            work.mkdir()
            with self.assertRaisesRegex(RuntimeError, '(?s)exit 2[)]:\n.*fatal: fixture failure'):
                check_post_install(image, work, run=FakeRunner(post_exit=2))
            self.assertEqual(list(work.iterdir()), [])

    def test_stuck_mount_keeps_the_work_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            image, work = image_fixture(directory), Path(directory) / 'work'
            work.mkdir()
            runner = FakeRunner(stuck=())
            original = runner.__call__

            def stuck_dev(command, **kwargs):
                if command[0] == 'umount' and command[-1].endswith('/root/dev'):
                    runner.commands.append(command)
                    return SimpleNamespace(returncode=1)
                return original(command, **kwargs)
            check_post_install(image, work, run=stuck_dev)
            self.assertEqual(len(list(work.iterdir())), 1)

    def test_verification_names_each_missing_result(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'etc/sudoers.d').mkdir(parents=True)
            (root / 'etc/sudoers.d/cybexos-live').touch()
            with self.assertRaises(RuntimeError) as raised:
                verify_target(root)
            for problem in ('/etc/sudoers.d/cybexos-live remains', 'lingering', 'login policy',
                            'installation choices', 'hardware detection'):
                self.assertIn(problem, str(raised.exception))

    def test_compose_runs_the_check_before_packaging(self):
        compose = (ROOT / 'compose').read_text()
        self.assertLess(compose.index('check_post_install(creator._instroot'), compose.index('creator.package()'))
        self.assertLess(compose.index('creator.configure()'), compose.index('check_post_install(creator._instroot'))


if __name__ == '__main__':
    unittest.main()
