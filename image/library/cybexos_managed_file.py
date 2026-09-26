#!/usr/bin/python3
"""Maintain vendor defaults only while their bytes still match our last write."""
import hashlib
import json
import os
from pathlib import Path
import tempfile


def atomic(path, data, mode=0o600):
    fd, temporary = tempfile.mkstemp(prefix='.cybexos-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def manage(destination, content, ledger, absent=False, mode=0o644, check=False):
    """Unknown/custom files and symlinks are never adopted or overwritten.

    Persist ownership before publishing new bytes, recording both old and new
    digests, so interrupted publication is recoverable on the next invocation.
    """
    destination, ledger = Path(destination), Path(ledger)
    previous = json.loads(ledger.read_text()) if ledger.exists() else {}
    key = str(destination)
    old = previous.get(key, [])
    if isinstance(old, str):
        old = [old]
    if destination.is_symlink() or any(p.is_symlink() for p in destination.parents):
        return {'changed': False, 'preserved': True}
    if destination.exists() and not destination.is_file():
        return {'changed': False, 'preserved': True}
    current = destination.read_bytes() if destination.exists() else None
    digest = hashlib.sha256(current).hexdigest() if current is not None else None
    desired = None if absent else hashlib.sha256(content).hexdigest()
    if digest is not None and digest != desired and digest not in old:
        return {'changed': False, 'preserved': True}
    # A user deletion is an override once we have adopted an existing file.
    if current is None and old:
        return {'changed': False, 'preserved': True}
    changed = current != (None if absent else content)
    if check:
        return {'changed': changed, 'preserved': False}
    ledger.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if changed and current is not None:
        backup = ledger.parent / 'backups' / hashlib.sha256(key.encode()).hexdigest() / digest
        backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not backup.exists():
            atomic(backup, current, destination.stat().st_mode & 0o777)
    previous[key] = list(dict.fromkeys(x for x in (digest, desired) if x))
    atomic(ledger, (json.dumps(previous, sort_keys=True) + '\n').encode())
    if changed:
        if absent:
            destination.unlink(missing_ok=True)
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            atomic(destination, content, mode)
    previous[key] = [desired] if desired else []
    atomic(ledger, (json.dumps(previous, sort_keys=True) + '\n').encode())
    return {'changed': changed, 'preserved': False}


def main():
    from ansible.module_utils.basic import AnsibleModule
    module = AnsibleModule(argument_spec={
        'dest': {'type': 'path', 'required': True},
        'content': {'type': 'str', 'default': ''},
        'state': {'choices': ['present', 'absent'], 'default': 'present'},
        'mode': {'type': 'str', 'default': '0644'},
    }, supports_check_mode=True)
    try:
        result = manage(module.params['dest'], module.params['content'].encode(),
                        '/var/lib/cybexos/reconcile/managed-files.json',
                        absent=module.params['state'] == 'absent',
                        mode=int(module.params['mode'], 8), check=module.check_mode)
    except (OSError, ValueError) as error:
        module.fail_json(msg=str(error))
    module.exit_json(**result)


if __name__ == '__main__':
    main()
