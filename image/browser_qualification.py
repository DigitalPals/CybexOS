"""Connect a host browser to the guest's actual loopback Cockpit instance."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
from urllib.parse import urlsplit

from vm_testing import free_port, run

DRIVER = Path(__file__).with_name('real_browser_qualification.cjs')
DISCOVER = r'''
from pathlib import Path
for proc in Path('/proc').iterdir():
    if not proc.name.isdigit():
        continue
    try:
        args = proc.joinpath('cmdline').read_bytes().split(b'\0')
    except (PermissionError, FileNotFoundError, ProcessLookupError):
        continue
    if not any(arg.endswith(b'/cybexos-installer-browser') for arg in args):
        continue
    for arg in args:
        if arg.startswith(b'http://127.0.0.1') or arg.startswith(b'http://localhost'):
            print(arg.decode('ascii'))
            raise SystemExit(0)
raise SystemExit(1)
'''


def validate_guest_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost')
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path != '/cockpit/@localhost/cybexos-installer/index.html'):
        raise ValueError('Guest installer URL was not the expected loopback Cockpit page')
    port = parsed.port or 80
    if not 1 <= port <= 65535:
        raise ValueError('Guest installer port is invalid')
    return port


def discover_guest_port(vm, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run([*vm.ssh, 'python3 -'], input=DISCOVER, text=True,
                                capture_output=True, timeout=10)
        if result.returncode == 0:
            urls = [line for line in result.stdout.splitlines() if line.strip()]
            if len(urls) != 1:
                raise RuntimeError('Guest installer URL discovery was ambiguous')
            return validate_guest_url(urls[0])
        vm.alive()
        time.sleep(2)
    raise RuntimeError('Guest installer browser URL was not discovered')


def wait_tunnel(port, process, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('Installer Cockpit tunnel exited unexpectedly')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=1):
                return
        except OSError:
            time.sleep(0.2)
    raise RuntimeError('Installer Cockpit tunnel did not open')


def browser_dependencies():
    requested = os.environ.get('CYBEXOS_BROWSER')
    browser = (shutil.which(requested) or requested) if requested else next((shutil.which(name) for name in
        ('brave-origin', 'chromium', 'chromium-browser', 'google-chrome') if shutil.which(name)), None)
    if not browser or not os.access(browser, os.X_OK):
        raise RuntimeError('Install a Chromium browser or set CYBEXOS_BROWSER for graphical qualification')
    check = subprocess.run(['node', '-e',
        'if(Number(process.versions.node.split(".")[0])<20) process.exit(1); require("playwright-core");'],
        capture_output=True, text=True, timeout=10)
    if check.returncode:
        raise RuntimeError('Graphical qualification requires Node.js >=20 and playwright-core (see image/README.md)')
    return browser


def qualify_browser(vm, *, password, target_disk, unused_disk, encrypted, keyboard, locale,
                    timezone, install_timeout, require_policy_controls=True):
    browser = browser_dependencies()
    remote_port = discover_guest_port(vm)
    local_port = free_port()
    tunnel = subprocess.Popen([*vm.ssh[:-1], '-N', '-L',
        f'127.0.0.1:{local_port}:127.0.0.1:{remote_port}', vm.ssh[-1]],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_tunnel(local_port, tunnel)
        payload = {'url': f'http://127.0.0.1:{local_port}/cockpit/@localhost/cybexos-installer/index.html',
                   'browser': browser, 'password': password, 'target_disk': target_disk,
                   'target_serial': 'CYBEXOS-QUALIFY', 'unused_disk': unused_disk,
                   'encrypted': encrypted, 'keyboard': keyboard, 'locale': locale,
                   'timezone': timezone, 'install_timeout_ms': install_timeout * 1000,
                   'require_policy_controls': require_policy_controls}
        result = run(['node', str(DRIVER)], input=json.dumps(payload), text=True,
                     capture_output=True, timeout=install_timeout + 240)
        data = json.loads(result.stdout)
        if data.get('check') != 'graphical-installer' or data.get('selected_disk') != target_disk:
            raise RuntimeError('Browser driver did not confirm the selected disposable disk')
        return data
    finally:
        tunnel.terminate()
        try:
            tunnel.wait(timeout=5)
        except subprocess.TimeoutExpired:
            tunnel.kill()
            tunnel.wait()
