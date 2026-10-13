#!/usr/bin/python3
"""Place vendor defaults below explicit user choices in each application's order."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

BEGIN = '# BEGIN CYBEXOS MANAGED INCLUDE'
END = '# END CYBEXOS MANAGED INCLUDE'
BLOCKS = {
    'kitty': 'include cybexos.conf',
    'git': '[include]\n  path = ~/.config/cybexos/gitconfig',
    # Reset the final user Host/Match scope before the fallback Include.
    'ssh': 'Host *\n  Include ~/.config/cybexos/ssh.conf',
}


def render(text, kind, absent=False):
    """Only move our exact include; a user-edited managed block is theirs."""
    lines = text.splitlines(keepends=True)
    begins = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == BEGIN]
    ends = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == END]
    if begins or ends:
        if len(begins) != 1 or len(ends) != 1 or ends[0] <= begins[0]:
            return text, True
        start, end = begins[0], ends[0]
        body = '\n'.join(line.strip() for line in lines[start + 1:end])
        accepted = ['\n'.join(line.strip() for line in BLOCKS[kind].splitlines())]
        if kind == 'ssh':
            accepted.append('Include ~/.ssh/config.d/cybexos.conf')
        if body not in accepted:
            return text, True
        lines = lines[:start] + lines[end + 1:]
    remaining = ''.join(lines)
    if absent:
        return remaining, False
    block = BEGIN + '\n' + BLOCKS[kind] + '\n' + END + '\n'
    if kind == 'ssh':
        # OpenSSH keeps the first obtained value. Kitty/Git scalar values use
        # the last one, so they put vendor defaults at the beginning instead.
        return remaining + ('\n' if remaining and not remaining.endswith('\n') else '') + block, False
    return block + remaining, False


def update(path, kind, absent=False, check=False):
    path = Path(path)
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        return {'changed': False, 'preserved': True}
    if path.exists() and not path.is_file():
        return {'changed': False, 'preserved': True}
    original = path.read_bytes() if path.exists() else b''
    try:
        desired, preserved = render(original.decode(), kind, absent)
    except UnicodeDecodeError:
        return {'changed': False, 'preserved': True}
    desired = desired.encode()
    if preserved or desired == original:
        return {'changed': False, 'preserved': preserved}
    if check:
        return {'changed': True, 'preserved': False}
    path.parent.mkdir(parents=True, exist_ok=True)
    if original:
        backup = path.with_name(path.name + '.cybexos-before-' + hashlib.sha256(original).hexdigest()[:16])
        try:
            with backup.open('xb') as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(original)
        except FileExistsError:
            pass
    fd, temporary = tempfile.mkstemp(prefix='.cybexos-include-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), path.stat().st_mode & 0o777 if path.exists()
                      else (0o600 if kind == 'ssh' else 0o644))
            stream.write(desired)
            stream.flush()
            os.fsync(stream.fileno())
        # Do not replace edits made while preparing the include.
        if (path.read_bytes() if path.exists() else b'') != original:
            return {'changed': False, 'preserved': True}
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return {'changed': True, 'preserved': False}


def personal_git_credentials(path):
    """Git credential helpers accumulate, unlike normal last-value settings.

    Respect personal helper chains (including nested includes) by omitting
    vendor authentication defaults whenever the account has its own helper.
    Only a boolean crosses the Ansible boundary, never credential commands.
    """
    path = Path(path)
    if not path.exists():
        return False
    result = subprocess.run(['git', 'config', '--file', str(path), '--includes',
                             '--show-origin', '--get-regexp', r'^credential(\..*)?\.helper$'],
                            capture_output=True, text=True, timeout=10, check=False)
    if result.returncode not in (0, 1):
        raise ValueError('Could not read personal Git credential configuration')
    vendor = path.parent / '.config/cybexos/gitconfig'
    return any(line.split('\t', 1)[0] != 'file:' + str(vendor)
               for line in result.stdout.splitlines())


def main():
    from ansible.module_utils.basic import AnsibleModule
    module = AnsibleModule(argument_spec={
        'path': {'type': 'path', 'required': True},
        'kind': {'choices': list(BLOCKS), 'required': True},
        'state': {'choices': ['present', 'absent'], 'default': 'present'},
        'inspect_git_credentials': {'type': 'bool', 'default': False},
    }, supports_check_mode=True)
    try:
        if module.params['inspect_git_credentials']:
            result = {'changed': False,
                      'personal_credentials': personal_git_credentials(module.params['path'])}
        else:
            result = update(module.params['path'], module.params['kind'],
                            absent=module.params['state'] == 'absent', check=module.check_mode)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        module.fail_json(msg=str(error))
    module.exit_json(**result)


if __name__ == '__main__':
    main()
