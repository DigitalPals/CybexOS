"""Offline N→N+1 RPM and Btrfs recovery checks inside a task-owned VM."""
import json
from pathlib import Path
import re

from build_support import digest
from vm_testing import run

CANDIDATE = '/tmp/cybexos-qualification-candidate.rpm'
SNAPSHOT = '/usr/libexec/cybexos-system-snapshot'
MANAGED_MARKER = '# cybexos qualification: preserve this user edit'


def prepare_user_choices(vm, password, root_script):
    script = r'''python3 - <<'PY'
import json
from pathlib import Path
home = Path('/home/qualification')
managed = home / '.config/kitty/cybexos.conf'
assert managed.is_file(), 'Managed Kitty setting is missing before upgrade'
marker = b'\n# cybexos qualification: preserve this user edit\n'
original = managed.read_bytes()
assert marker not in original
managed.write_bytes(original + marker)
settings = home / '.config/cybexos/shell.json'
data = json.loads(settings.read_text())
# A pristine seed can omit position; the desktop's effective default is top.
position = data.get('position', 'top')
assert position in ('top', 'bottom')
data['position'] = 'bottom' if position == 'top' else 'top'
settings.write_text(json.dumps(data, indent=2) + '\n')
(home / 'qualification-personal-marker').write_text('qualification-preserve\n')
print(data['position'])
PY
chown qualification:qualification /home/qualification/qualification-personal-marker
'''
    desired = root_script(vm, script, password).stdout.strip()
    if desired not in ('top', 'bottom'):
        raise RuntimeError('User preference fixture did not return a valid position')
    return desired


def verify_user_choices(vm, password, root_script, position):
    if position not in ('top', 'bottom'):
        raise ValueError('Unknown qualification preference')
    script = "python3 - <<'PY'\nimport json\nfrom pathlib import Path\n"
    script += "home = Path('/home/qualification')\n"
    script += "assert (home / 'qualification-personal-marker').read_text() == 'qualification-preserve\\n'\n"
    script += "assert (home / '.config/kitty/cybexos.conf').read_text().count(" + repr(MANAGED_MARKER) + ") == 1\n"
    script += "assert json.loads((home / '.config/cybexos/shell.json').read_text())['position'] == " + repr(position) + "\nPY\n"
    root_script(vm, script, password)


def inspect_version(vm):
    script = '''python3 - <<'PY'
import json, subprocess
import rpm
def fields(command):
    result = subprocess.check_output(command, text=True).splitlines()
    assert len(result) == 4 and result[0] == 'cybexos-desktop'
    return {'name': result[0], 'epoch': result[1], 'version': result[2], 'release': result[3]}
format = '%{NAME}\\n%{EPOCHNUM}\\n%{VERSION}\\n%{RELEASE}\\n'
installed = fields(['rpm', '-q', '--qf', format, 'cybexos-desktop'])
candidate = fields(['rpm', '-qp', '--qf', format, '/tmp/cybexos-qualification-candidate.rpm'])
comparison = rpm.labelCompare(
    (candidate['epoch'], candidate['version'], candidate['release']),
    (installed['epoch'], installed['version'], installed['release']))
print(json.dumps({'installed': installed, 'candidate': candidate, 'comparison': comparison}))
PY
'''
    return json.loads(run([*vm.ssh, 'bash -s'], input=script, text=True,
                          capture_output=True, timeout=30).stdout)


def copy_candidate(vm, candidate):
    original = Path(candidate)
    if original.is_symlink():
        raise ValueError('Candidate RPM must be a regular .rpm file')
    candidate = original.resolve(strict=True)
    if not candidate.is_file() or candidate.suffix != '.rpm':
        raise ValueError('Candidate RPM must be a regular .rpm file')
    expected = digest(candidate)
    with candidate.open('rb') as stream:
        run([*vm.ssh, f'cat > {CANDIDATE}'], stdin=stream, capture_output=True, timeout=300)
    actual = run([*vm.ssh, f'sha256sum {CANDIDATE}'], text=True, capture_output=True,
                 timeout=30).stdout.split()[0]
    if actual != expected:
        raise RuntimeError('Candidate RPM changed in transfer to guest')
    return expected


def create_recovery_point(vm, password, root_script):
    root_script(vm, "test -f /usr/libexec/cybexos-system-snapshot\n", password)
    point = root_script(vm, f'{SNAPSHOT} create qualification-before-rpm-upgrade\n', password,
                        timeout=300).stdout.strip().splitlines()[-1]
    if not re.fullmatch(r'[0-9A-Za-z_-]{8,80}', point):
        raise RuntimeError('Recovery point ID was not valid')
    index = json.loads(root_script(vm, f'{SNAPSHOT} list --json\n', password).stdout)
    if not index.get('bootMenu') or not any(item.get('id') == point and item.get('bootable')
                                         for item in index.get('points', [])):
        raise RuntimeError('Recovery point did not have a bootable GRUB entry')
    return point


def upgrade(vm, candidate, password, root_script):
    sha = copy_candidate(vm, candidate)
    versions = inspect_version(vm)
    if versions['comparison'] <= 0:
        raise RuntimeError('Candidate RPM is not newer than the baseline installed RPM')
    config_before = root_script(vm, 'sha256sum /etc/cybexos/config.yml\n', password).stdout.split()[0]
    root_script(vm, f"dnf -y --disablerepo='*' install {CANDIDATE}\n"
                "systemctl daemon-reload\n"
                "systemctl start cybexos-reconcile.service\n", password, timeout=1200)
    status = json.loads(root_script(vm, '/usr/libexec/cybexos-reconcile --status\n', password).stdout)
    if (status.get('state') != 'ready' or status.get('pending') is not False
            or status.get('version') != status.get('desiredVersion')):
        raise RuntimeError('Installed RPM reconciliation did not finish successfully')
    accounts = status.get('accounts', {})
    if not isinstance(accounts, dict) or accounts.get('qualification', {}).get('state') != 'ready':
        raise RuntimeError('Installed account reconciliation did not finish successfully')
    after = inspect_version(vm)
    if after['installed'] != versions['candidate']:
        raise RuntimeError('Installed desktop RPM did not match the candidate version')
    root_script(vm, f"test ! -e {CANDIDATE}.password\n", password)
    config_after = root_script(vm, 'sha256sum /etc/cybexos/config.yml\n', password).stdout.split()[0]
    if config_after != config_before:
        raise RuntimeError('RPM upgrade changed saved installation choices')
    return sha, versions


def select_recovery_boot(vm, point, password, root_script):
    if not re.fullmatch(r'[0-9A-Za-z_-]{8,80}', point):
        raise ValueError('Invalid recovery point ID')
    script = "python3 - <<'PY'\nimport subprocess\n"
    script += "subprocess.run(['grub2-reboot', " + repr('cybexos-recovery>cybexos-recovery-' + point) + "], check=True)\nPY\n"
    root_script(vm, script, password)


def verify_recovery_boot(vm, point, password, root_script):
    index = json.loads(root_script(vm, f'{SNAPSHOT} list --json\n', password).stdout)
    if index.get('recoveryBoot') is not True:
        raise RuntimeError('VM did not boot the requested recovery point')
    if not any(item.get('id') == point for item in index.get('points', [])):
        raise RuntimeError('Requested recovery point was unavailable after boot')
    root_script(vm, f'{SNAPSHOT} restore {point}\n', password, timeout=600)


def verify_restored(vm, before, password, root_script):
    script = "test \"$(cat /home/qualification/qualification-personal-marker)\" = qualification-preserve\n"
    root_script(vm, script, password)
    result = run([*vm.ssh, 'rpm -q --qf "%{NAME}\\n%{EPOCHNUM}\\n%{VERSION}\\n%{RELEASE}\\n" cybexos-desktop'],
                 text=True, capture_output=True, timeout=30).stdout.splitlines()
    if result != [before[key] for key in ('name', 'epoch', 'version', 'release')]:
        raise RuntimeError('Recovery restore did not return to the baseline desktop RPM')
