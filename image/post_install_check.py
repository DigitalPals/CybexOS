"""Run the installer's post-install scripts against the composed image.

Anaconda installs a live image by copying its root filesystem, then runs
live-rootfs/usr/share/anaconda/post-scripts/90-cybexos.ks in the copy. A
failing command there aborts every installation after the boot loader step,
which source fixtures cannot reveal. The builder reproduces that step before
packaging: a throwaway overlay of the image root receives an administrator
account like the one Anaconda creates, the Live /run shape Anaconda binds into
the target, and no network. The image root itself is never modified.
"""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import types

HOOK = 'usr/share/anaconda/post-scripts/90-cybexos.ks'
TARGET_HELPER = 'usr/libexec/cybexos-installer-target'
ACCOUNT = 'cybexcheck'


def chroot_post_script(text):
    """Return the body of the single chroot %post section Anaconda runs."""
    sections = re.findall(r'^%post\b([^\n]*)\n(.*?)^%end\s*$', text, re.MULTILINE | re.DOTALL)
    bodies = [body for options, body in sections if '--nochroot' not in options.split()]
    if len(bodies) != 1:
        raise ValueError('Expected exactly one chroot %post section in the installer hook')
    return bodies[0]


def load_target_helper(root):
    # Compile in memory: an import would write __pycache__ into the image root.
    path = root / TARGET_HELPER
    module = types.ModuleType('cybexos_installer_target')
    exec(compile(path.read_text(), str(path), 'exec'), module.__dict__)
    return module


def verify_target(root, username=ACCOUNT):
    """The installed-system state the post-install scripts must leave behind."""
    problems = []
    for path in ('etc/sudoers.d/cybexos-live', 'usr/lib/systemd/system/cybexos-live.service',
                 'usr/libexec/cybexos-installer-backend', 'usr/share/cockpit/cybexos-installer',
                 'etc/dracut.conf.d/99-live.conf', 'etc/anaconda/conf.d/20-cybexos.conf'):
        if (root / path).exists():
            problems.append(f'live-only /{path} remains')
    if not (root / 'var/lib/systemd/linger' / username).is_file():
        problems.append('user lingering was not enabled')
    try:
        login = json.loads((root / 'etc/cybexos/login.json').read_text())
        if login != {'version': 1, 'user': username, 'autologin': True, 'live': False}:
            problems.append(f'unexpected login policy {login}')
    except (OSError, ValueError):
        problems.append('the login policy is missing or invalid')
    config = root / 'etc/cybexos/config.yml'
    text = config.read_text() if config.is_file() else ''
    if f"primary_user: '{username}'" not in text or 'desktop_autologin: true' not in text:
        problems.append('the installation choices were not recorded')
    if not (root / 'etc/cybexos/hardware.json').is_file():
        problems.append('hardware detection did not run')
    if problems:
        raise RuntimeError('Post-install check: ' + '; '.join(problems))


def check_post_install(image_root, work_parent, run=subprocess.run):
    image_root = Path(image_root)
    script = chroot_post_script((image_root / HOOK).read_text())
    work = Path(tempfile.mkdtemp(prefix='post-install-check-', dir=work_parent))
    merged = work / 'root'
    mounts = []

    def mount(*arguments, target):
        run(['mount', *arguments, str(target)], check=True)
        mounts.append(target)

    try:
        for name in ('upper', 'work', 'root'):
            (work / name).mkdir()
        mount('-t', 'overlay', 'overlay', '-o',
              f'lowerdir={image_root},upperdir={work / "upper"},workdir={work / "work"}', target=merged)
        for name in ('proc', 'sys', 'dev', 'dev/pts'):
            mount('--bind', '/' + name, target=merged / name)
        # Anaconda binds the live /run, which has /run/lock, into the target.
        for name in ('run', 'tmp'):
            mount('-t', 'tmpfs', '-o', 'mode=0755' if name == 'run' else 'mode=1777', 'tmpfs', target=merged / name)
        (merged / 'run/lock').mkdir(mode=0o1777)
        (merged / 'run/lock').chmod(0o1777)
        run(['chroot', str(merged), 'useradd', '--create-home', '--groups', 'wheel',
             '--comment', 'Post-install check', ACCOUNT], check=True)
        (merged / 'tmp/cybexos-post.sh').write_text(script)
        log = work / 'post-install.log'
        with log.open('w') as stream:
            result = run(['unshare', '--net', 'chroot', str(merged), '/bin/bash', '-eux', '/tmp/cybexos-post.sh'],
                         stdout=stream, stderr=subprocess.STDOUT, check=False)
        if result.returncode:
            tail = log.read_text(errors='replace').splitlines()[-80:]
            raise RuntimeError('The installer post-install script failed in the composed image '
                               f'(exit {result.returncode}):\n' + '\n'.join(tail))
        # The --nochroot hook finalizes the target from outside; exercise the
        # same decision for a verified encrypted installation.
        load_target_helper(image_root).finalize(
            merged, {'phase': 'installing', 'account': {'username': ACCOUNT, 'encrypted': True}}, True)
        verify_target(merged)
    finally:
        stuck = [target for target in reversed(mounts)
                 if run(['umount', str(target)], check=False).returncode
                 and run(['umount', '--lazy', str(target)], check=False).returncode]
        # Never recurse into a directory that may still reach the builder's
        # /dev, /proc or /sys through a bind mount.
        if not stuck:
            shutil.rmtree(work, ignore_errors=True)
