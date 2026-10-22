"""Read-only desktop probes used after activation and authenticated trial boot."""
import re
import time

from .common import Failure, parse


LUA_HEALTH = '''
assert(not __nerdos_displays_error, "display preferences did not load")
assert(not __nerdos_input_error, "input preferences did not load")
assert(not __nerdos_workspaces_error, "workspace module did not load")
local state = __nerdos_workspaces
assert(type(state) == "table", "workspace module is absent")
assert(state.error == "", "workspace or titlebar runtime reported an error")
assert(state.capabilities.scrolling == true, "scrolling layout is unavailable")
assert(state.capabilities.titlebars == true, "native titlebar plugin is unavailable")
'''

# Read-only guard brackets: begin records the managed shell invocation that the
# probes inspect; end requires that same MainPID/InvocationID and validates its
# journal. Neither starts, restarts or stops a unit or terminates a process.
LIVE_BEGIN = '''
export QS_LIVE_READ_ONLY=1
source "$1" || exit 1
qs_live_begin || exit 1
qs_live_wait_ipc 15 shell ping >/dev/null || exit 1
printf 'qs-live-identity %s %s\\n' "$QS_LIVE_BEGIN_PID" "$QS_LIVE_BEGIN_INVOCATION"
'''
LIVE_END = '''
export QS_LIVE_READ_ONLY=1
source "$1" || exit 1
QS_LIVE_BEGIN_PID=$2
QS_LIVE_BEGIN_INVOCATION=$3
qs_live_end
'''


def system_services(run, declaration):
    if (not isinstance(declaration, dict) or declaration.get('schema') != 1
            or not isinstance(declaration.get('units'), list) or not declaration['units']):
        raise Failure('System health service declaration is missing or invalid; inspect /etc/nerdos/health-services.json')
    for unit in declaration['units']:
        if not isinstance(unit, str) or not re.fullmatch(r'[A-Za-z0-9_.@:-]+\.(service|target)', unit):
            raise Failure('Invalid system health unit declaration')
        try:
            active = run('systemctl', 'is-active', unit)
        except Exception as error:
            raise Failure(f'{unit} is not active; inspect systemctl status {unit} and its journal before retrying') from error
        if active != 'active':
            raise Failure(f'{unit} is not active; inspect systemctl status {unit} and its journal before retrying')


def user_services(prefix, run, declaration):
    if (not isinstance(declaration, dict) or declaration.get('schema') != 1
            or not isinstance(declaration.get('userUnits'), list)):
        raise Failure('Desktop health service declaration is missing or invalid; inspect /etc/nerdos/health-services.json')
    for unit in declaration['userUnits']:
        if not isinstance(unit, str) or not re.fullmatch(r'[A-Za-z0-9_.@:-]+\.service', unit):
            raise Failure('Invalid desktop health unit declaration')
        try:
            active = run(*prefix, 'systemctl', '--user', 'is-active', unit)
        except Exception as error:
            raise Failure(f'{unit} is not active in the desktop session; inspect systemctl --user status {unit} and its journal before retrying') from error
        if active != 'active':
            raise Failure(f'{unit} is not active in the desktop session; inspect systemctl --user status {unit} and its journal before retrying')


def desktop(prefix, run, guard, expected=None):
    # Every probe runs inside the guard bracket. A failed begin stops here; a
    # crash or restart at any point before end fails instead of inspecting, or
    # accepting, a replacement shell.
    begun = re.findall(r'^qs-live-identity ([1-9][0-9]*) ([0-9a-fA-F]{32})$',
                       run(*prefix, 'bash', '-c', LIVE_BEGIN, 'nerdos-health', str(guard)), re.M)
    if len(begun) != 1:
        raise Failure('Managed desktop service identity is unavailable; sign out and retry the selected generation')
    pid, invocation = begun[0]
    probes(prefix, run, pid, expected)
    run(*prefix, 'bash', '-c', LIVE_END, 'nerdos-health', str(guard), pid, invocation)


def probes(prefix, run, pid, expected):
    environment = run(*prefix, 'systemctl', '--user', 'show-environment')
    signature = next((s.split('=', 1)[1] for s in environment.splitlines()
                      if s.startswith('HYPRLAND_INSTANCE_SIGNATURE=')), None)
    if not signature:
        raise Failure('Compositor environment missing')
    hypr = [*prefix, f'HYPRLAND_INSTANCE_SIGNATURE={signature}', 'hyprctl']
    actual = parse(run(*hypr, '-j', 'version'))
    if expected is not None and actual.get('version') != expected['hyprland']:
        raise Failure('The authenticated desktop is running a different compositor version; sign out and retry the selected generation')
    errors = parse(run(*hypr, '-j', 'configerrors'))
    # Hyprland can represent an empty error buffer as [""]. Only blank
    # strings mean no error; malformed replies must still fail closed.
    if not isinstance(errors, list) or any(not isinstance(error, str) or error.strip() for error in errors):
        raise Failure('Hyprland configuration errors; inspect hyprctl configerrors')
    # Contained Lua failures and native plugin ABI failures are intentionally
    # absent from configerrors. They must still prevent a healthy deployment.
    if run(*hypr, 'eval', LUA_HEALTH) != 'ok':
        raise Failure('Hyprland workspace, titlebar, display or input health failed; inspect compositor diagnostics')
    for attempt in range(26):
        plugins = parse(run(*prefix, 'qs', 'ipc', '--pid', pid, 'call', 'shell', 'listPlugins'))
        if not isinstance(plugins, dict) or not isinstance(plugins.get('discovering'), bool):
            raise Failure('Personal plugin discovery health is unavailable; sign out and retry the selected generation')
        if not plugins['discovering']:
            break
        if attempt == 25:
            raise Failure('Personal plugin discovery did not settle; inspect nerd plugin list and retry')
        time.sleep(1)
    if not isinstance(plugins.get('discoveryError'), str) or plugins['discoveryError']:
        raise Failure('Personal plugin discovery failed; inspect nerd plugin list and its registry. Existing plugins and preferences were retained')
    if not isinstance(plugins, dict) or not isinstance(plugins.get('plugins'), list) or plugins.get('errors'):
        raise Failure('Personal plugins reported runtime errors; inspect nerd plugin list and the current shell journal')
    for plugin in plugins['plugins']:
        if not isinstance(plugin, dict) or (plugin.get('enabled') and plugin.get('error')):
            raise Failure('An enabled personal plugin is incompatible; its files and preferences were retained')
