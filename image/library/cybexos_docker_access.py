#!/usr/bin/python3
"""Grant/revoke only Docker membership, retaining independently managed access."""
import grp
from pathlib import Path
import pwd
import subprocess


def reconcile(user, enabled, explicit=False, legacy_owner=False,
              state=Path('/var/lib/cybexos'), check=False):
    state = Path(state)
    marker = state / 'accounts' / user / 'docker'
    owned = marker.is_file() or (legacy_owner and (state / 'features/docker').is_file())
    account = pwd.getpwnam(user)
    try:
        group = grp.getgrnam('docker')
    except KeyError:
        group = None
    primary = group is not None and account.pw_gid == group.gr_gid
    member = primary or (group is not None and user in group.gr_mem)
    # A machine-wide saved opt-in is not authorization for every account.
    # Both grants and revocations need this account's intent or managed ownership.
    if not (explicit or owned):
        return {'changed': False, 'preserved': member}
    if not enabled and primary:
        raise ValueError('Docker is the primary group of this account. Choose a different '
                         'primary group before disabling Docker administrator access.')
    changed = member != enabled or (not enabled and marker.exists())
    if check:
        return {'changed': changed, 'preserved': False}
    if enabled and not member:
        # Persist intent before granting, so interruption cannot leave an unowned
        # root-equivalent grant. Existing administrator grants are never adopted.
        marker.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        marker.write_text('managed\n')
        marker.chmod(0o644)
        if group is None:
            subprocess.run(['groupadd', '--', 'docker'], check=True, capture_output=True)
        subprocess.run(['usermod', '--append', '--groups', 'docker', '--', user],
                       check=True, capture_output=True)
    elif not enabled:
        if member:
            subprocess.run(['gpasswd', '--delete', user, 'docker'], check=True, capture_output=True)
        # Keep ownership until revocation succeeds, allowing failed runs to retry.
        marker.unlink(missing_ok=True)
    return {'changed': changed, 'preserved': False}


def main():
    from ansible.module_utils.basic import AnsibleModule
    module = AnsibleModule(argument_spec={
        'user': {'type': 'str', 'required': True},
        'enabled': {'type': 'bool', 'required': True},
        'explicit': {'type': 'bool', 'default': False},
        'legacy_owner': {'type': 'bool', 'default': False},
    }, supports_check_mode=True)
    try:
        result = reconcile(**module.params, check=module.check_mode)
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        module.fail_json(msg=str(error))
    module.exit_json(**result)


if __name__ == '__main__':
    main()
