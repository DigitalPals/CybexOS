"""Capture real installed outcomes and compare checkout installation with ISO.

Capture is read-only and must run as root inside a disposable qualification
guest with a live graphical account. Never substitute fixture output for it.
"""
import argparse
import configparser
import grp
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import subprocess
import xml.etree.ElementTree as ET

SYSTEM_UNITS = ('NetworkManager.service', 'firewalld.service', 'avahi-daemon.service', 'cups.service',
                'fstrim.timer', 'fwupd-refresh.timer', 'tuned.service', 'tuned-ppd.service', 'bluetooth.service',
                'tailscaled.service', 'docker.socket', 'docker.service', 'sddm.service',
                'cybexos-recovery-refresh.service', 'cybexos-update-recover.service')
USER_UNITS = ('quickshell.service', 'hypridle.service', 'voxtype.service', 'hyprland-session.target',
              'cybexos-session-lock.service', 'cybexos-input-method.service')
COMMANDS = ('cybex', 'fastfetch', 'claude', 'opencode', 'codex', 'cargo', 'rustup', 'node', 'npm',
            'bun', 'lazygit', 'lazydocker', 'balena', 'mdview', 'awww', 'wayfreeze', 'voxtype',
            'localsend', 't3code-desktop', 'adb')
CHOICES = ('config_schema_version', 'machine_timezone', 'machine_locale', 'regional_locale',
           'machine_keyboard_layout', 'machine_keyboard_variant', 'manage_system_identity',
           'manage_personal_dotfiles', 'passwordless_wheel', 'passwordless_local_polkit',
           'docker_sudoless', 'desktop_autologin', 'start_optional_hardware_services',
           'allow_insecure_sccache_transport', 'features')
CAPTURE_FIELDS = {'format', 'installation', 'scenario', 'profile', 'source_revision', 'source_content_sha256',
                  'hardware', 'required_packages', 'installed_packages', 'flatpaks', 'commands', 'choices',
                  'system_units', 'user_units', 'settings', 'input', 'authentication', 'firewall',
                  'default_apps', 'personal', 'recovery', 'selinux', 'graphical_session', 'sole_managed_shell'}


def command(args, *, environment=None, accepted=(0,)):
    result = subprocess.run(args, env=environment, capture_output=True, text=True, timeout=40, check=False)
    if result.returncode not in accepted:
        raise RuntimeError('Installed outcome read failed: ' + ' '.join(args[:3]) + ' … ' + str(args[-1])[:160])
    return result.stdout.strip()


def read_json(path):
    return json.loads(Path(path).read_text())


def normalize(value, home):
    if isinstance(value, str):
        return value.replace(home, '$HOME').replace('/usr/share/cybexos/runtime', '$RUNTIME').replace('$HOME/.local/share/cybexos/runtime', '$RUNTIME')
    if isinstance(value, dict):
        return {key: normalize(item, home) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize(item, home) for item in value]
    return value


def capture(user, installation, scenario, profile, manifest, provenance):
    import yaml
    if os.geteuid() != 0 or user != 'qualification' or command(['systemd-detect-virt']) not in ('kvm', 'qemu'):
        raise RuntimeError('Capture requires the disposable qualification guest and account')
    account = pwd.getpwnam(user)
    home = Path(account.pw_dir)
    environment = {**os.environ, 'HOME': str(home), 'USER': user, 'LOGNAME': user,
                   'XDG_RUNTIME_DIR': '/run/user/' + str(account.pw_uid),
                   'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/' + str(account.pw_uid) + '/bus',
                   'PATH': ':'.join([str(home / relative) for relative in ('.local/bin', '.cargo/bin', '.npm-global/bin', 'Android/Sdk/platform-tools')]
                                    + ['/usr/local/bin', '/usr/bin', '/bin'])}
    def user_command(args, accepted=(0,)):
        return command(['runuser', '-u', user, '--', *args], environment=environment, accepted=accepted)
    for line in user_command(['systemctl', '--user', 'show-environment']).splitlines():
        if line.startswith(('HYPRLAND_INSTANCE_SIGNATURE=', 'WAYLAND_DISPLAY=')):
            key, value = line.split('=', 1)
            environment[key] = value
    if not environment.get('HYPRLAND_INSTANCE_SIGNATURE'):
        raise RuntimeError('Capture requires an actual running Hyprland desktop')
    build = read_json(provenance)
    for key, pattern in (('source_revision', r'[0-9a-f]{40,64}'), ('source_content_sha256', r'[0-9a-f]{64}')):
        if not re.fullmatch(pattern, str(build.get(key, ''))):
            raise RuntimeError('Installed build is missing exact source provenance')
    applications = read_json(manifest)
    required = {}
    for selector in applications['packages']:
        required[selector] = sorted(command(['rpm', '-q', '--qf', '%{NAME}.%{ARCH}=%{EVR}\n', selector]).splitlines())
    installed = sorted(command(['rpm', '-qa', '--qf', '%{NAME}.%{ARCH}=%{EVR}\n']).splitlines())
    flatpaks = sorted(command(['flatpak', 'list', '--system', '--app', '--columns=application,branch,commit']).splitlines())
    flatpak_ids = {line.split()[0] for line in flatpaks}
    if not set(applications['flatpaks']) <= flatpak_ids:
        raise RuntimeError('Installed Flatpak application contract is incomplete')
    executable = {}
    for name in COMMANDS:
        # No shell expansion; the user environment supplies both installation paths.
        executable[name] = user_command(['python3', '-c', 'import os,shutil,sys; p=shutil.which(sys.argv[1]); print(bool(p and os.access(p,os.X_OK)))', name]) == 'True'
    if not all(executable.values()):
        raise RuntimeError('Application commands missing: ' + ', '.join(name for name, present in executable.items() if not present))
    config = yaml.safe_load(Path('/etc/cybexos/config.yml').read_text())
    settings = json.loads(user_command(['cybexos-runtime', 'ipc', 'settings', 'values']))
    units = {}
    for name in SYSTEM_UNITS:
        units[name] = command(['systemctl', 'is-enabled', name], accepted=(0, 1, 3, 4))
    user_units = {}
    for name in USER_UNITS:
        # Static units are pulled into the session target; compare activation too.
        user_units[name] = {'enabled': user_command(['systemctl', '--user', 'is-enabled', name], accepted=(0, 1, 3, 4)),
                            'active': user_command(['systemctl', '--user', 'is-active', name], accepted=(0, 1, 3, 4))}
    main_pid = user_command(['systemctl', '--user', 'show', 'quickshell.service', '-p', 'MainPID', '--value'])
    processes = user_command(['pgrep', '-x', 'qs'], accepted=(0, 1)).splitlines()
    if processes != [main_pid] or main_pid in ('', '0'):
        raise RuntimeError('Managed Quickshell must be the sole running shell')
    sudo = subprocess.run(['runuser', '-u', user, '--', 'sudo', '-k', '-n', 'true'], capture_output=True, timeout=10)
    if sudo.returncode not in (0, 1) or (sudo.returncode == 0) != config.get('passwordless_wheel'):
        raise RuntimeError('Effective sudo authorization differs from the saved installation choice')
    login = read_json('/etc/cybexos/login.json')
    sddm = configparser.ConfigParser()
    sddm.read('/etc/sddm.conf')
    zone = ET.parse('/etc/firewalld/zones/cybexos.xml').getroot()
    policy = sorted(ET.tostring(node, encoding='unicode').strip() for node in zone)
    groups = sorted(group.gr_name for group in grp.getgrall() if user in group.gr_mem)
    keyboard = {}
    for name in ('kb_layout', 'kb_variant', 'kb_options', 'repeat_rate', 'sensitivity', 'touchpad:tap_to_click', 'touchpad:natural_scroll', 'touchpad:scroll_factor'):
        result = json.loads(user_command(['hyprctl', '-j', 'getoption', 'input:' + name]))
        keyboard[name] = {key: result[key] for key in ('int', 'float', 'str') if key in result}
    personal = {}
    for relative in ('.config/cybexos/input.json', '.config/cybexos/hypr/user.lua', 'qualification-personal-marker'):
        path = home / relative
        personal[relative] = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
    default_apps = {mime: user_command(['xdg-mime', 'query', 'default', mime]) for mime in
                    ('text/html', 'inode/directory', 'application/pdf', 'x-scheme-handler/http', 'x-scheme-handler/https')}
    if not all(default_apps.values()):
        raise RuntimeError('A standard application association is missing')
    recovery = next((path for path in ('/usr/libexec/cybexos-system-snapshot', '/usr/local/libexec/cybexos-system-snapshot') if Path(path).is_file()), None)
    if not recovery:
        raise RuntimeError('Recovery helper is missing')
    recovery_state = json.loads(command([recovery, 'list', '--json']))
    hardware = {name: Path('/sys/class/dmi/id/' + name).read_text().strip() for name in ('sys_vendor', 'product_name')}
    result = {'format': 1, 'installation': installation, 'scenario': scenario, 'profile': profile,
              'source_revision': build['source_revision'], 'source_content_sha256': build['source_content_sha256'],
              'hardware': hardware, 'required_packages': required, 'installed_packages': installed,
              'flatpaks': flatpaks, 'commands': executable, 'choices': {key: config.get(key) for key in CHOICES},
              'system_units': units, 'user_units': user_units, 'settings': settings, 'input': keyboard,
              'authentication': {'login': login, 'shell': account.pw_shell, 'groups': groups,
                                 'passwordless_sudo': sudo.returncode == 0,
                                 'passwordless_polkit': Path('/etc/polkit-1/rules.d/49-wheel-local.rules').exists(),
                                 'autologin_user': sddm.get('Autologin', 'User', fallback='')},
              'firewall': {'default_zone': command(['firewall-cmd', '--get-default-zone']), 'policy': policy,
                           'permanent_services': sorted(command(['firewall-cmd', '--permanent', '--zone=cybexos', '--list-services']).split()),
                           'permanent_ports': sorted(command(['firewall-cmd', '--permanent', '--zone=cybexos', '--list-ports']).split())},
              'default_apps': default_apps, 'personal': personal,
              'recovery': {'supported': recovery_state.get('supported'),
                           'root_filesystem': command(['findmnt', '-n', '-o', 'FSTYPE', '/'])},
              'selinux': command(['getenforce']), 'graphical_session': True, 'sole_managed_shell': True}
    return normalize(result, str(home))


def compare(iso, checkout, exceptions):
    """No implicit allowlist: every extra package difference needs a reason."""
    if iso.get('installation') != 'iso' or checkout.get('installation') != 'checkout':
        raise ValueError('Comparison requires ISO and checkout captures')
    for key in ('source_revision', 'source_content_sha256', 'scenario', 'profile', 'hardware'):
        if not iso.get(key) or iso[key] != checkout.get(key):
            raise ValueError('Installed outcomes cannot be compared: mismatched ' + key)
    for result in (iso, checkout):
        if CAPTURE_FIELDS - set(result):
            raise ValueError('Installed outcomes are incomplete: ' + ', '.join(sorted(CAPTURE_FIELDS - set(result))))
        if result.get('format') != 1 or result.get('graphical_session') is not True or result.get('sole_managed_shell') is not True:
            raise ValueError('Installed outcomes lack a verified graphical session')
        for key in ('required_packages', 'settings', 'commands', 'choices', 'system_units', 'user_units', 'input', 'authentication', 'firewall', 'default_apps', 'recovery'):
            if not isinstance(result[key], dict) or not result[key]:
                raise ValueError('Installed outcomes have no effective ' + key)
    ignored = {'installation', 'installed_packages'}
    differences = {key: {'iso': iso.get(key), 'checkout': checkout.get(key)} for key in sorted(set(iso) | set(checkout))
                   if key not in ignored and iso.get(key) != checkout.get(key)}
    package_delta = {}
    for side, other in (('iso', 'checkout'), ('checkout', 'iso')):
        own = iso if side == 'iso' else checkout
        peer = checkout if other == 'checkout' else iso
        delta = sorted(set(own['installed_packages']) - set(peer['installed_packages']))
        approved = exceptions.get(side, {})
        if not isinstance(approved, dict) or any(not isinstance(reason, str) or len(reason.strip()) < 12 for reason in approved.values()):
            raise ValueError('Every package exception must include a review reason')
        unreviewed = [package for package in delta if package.split('=', 1)[0] not in approved]
        package_delta[side] = {'all': delta, 'unreviewed': unreviewed}
    reviewed = not any(item['unreviewed'] for item in package_delta.values())
    return {'format': 1, 'status': 'failed' if differences or not reviewed else 'passed',
            'source_revision': iso['source_revision'], 'source_content_sha256': iso['source_content_sha256'],
            'scenario': iso['scenario'], 'profile': iso['profile'], 'differences': differences, 'package_delta': package_delta,
            'checks': ['real-installed-outcomes', 'same-source-content', 'graphical-session'] + (['package-delta-reviewed'] if reviewed else [])}


def capture_guest(vm, root_script, password, *, installation, scenario, profile, manifest, provenance):
    args = ['--capture', '--user', 'qualification', '--installation', installation, '--scenario', scenario,
            '--profile', profile, '--manifest', manifest, '--provenance', provenance]
    script = 'python3 - ' + shlex.join(args) + " <<'CYBEXOS_OUTCOMES_PY'\n" + Path(__file__).read_text() + '\nCYBEXOS_OUTCOMES_PY\n'
    try:
        return json.loads(root_script(vm, script, password, timeout=300).stdout)
    except subprocess.CalledProcessError as error:
        detail = ((error.stdout or '') + (error.stderr or '')).replace(password, '[redacted]')[-4000:]
        raise RuntimeError('Installed outcome capture failed: ' + detail) from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', action='store_true')
    parser.add_argument('--user', default='qualification')
    parser.add_argument('--installation', choices=('iso', 'checkout'))
    parser.add_argument('--scenario')
    parser.add_argument('--profile', default='fresh')
    parser.add_argument('--manifest')
    parser.add_argument('--provenance')
    parser.add_argument('--iso', type=Path)
    parser.add_argument('--checkout', type=Path)
    parser.add_argument('--exceptions', type=Path, default=Path(__file__).with_name('parity-exceptions.json'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.capture:
        if not all((args.installation, args.scenario, args.manifest, args.provenance)):
            parser.error('Capture needs installation, scenario, manifest and provenance')
        result = capture(args.user, args.installation, args.scenario, args.profile, args.manifest, args.provenance)
    else:
        if not all((args.iso, args.checkout, args.output)):
            parser.error('Comparison needs --iso --checkout --output')
        result = compare(read_json(args.iso), read_json(args.checkout), read_json(args.exceptions))
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True))
    return 1 if result.get('status') == 'failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
