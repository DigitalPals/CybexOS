"""Public updater crash/recovery qualification in the existing encrypted guest.

The guest-only DNF adapter selects the already checksum/signature-verified
local candidate transaction, with repositories disabled. It executes real DNF;
no updater, health, storage, authorization or recovery code is substituted.
"""
import base64
import inspect
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import signal
import subprocess
import sys
import time

from build_support import digest
from vm_testing import run

ROOT = Path(__file__).resolve().parents[1]
WORK = '/run/cybexos-qualification-public'
SOURCE = WORK + '/source'
UPDATER = SOURCE + '/assets/scripts/cybexos-update-run'
OBSERVER = '/usr/local/libexec/cybexos-qualification-recovery-observer'
UNIT = 'cybexos-qualification-recovery-observer.service'
EVIDENCE = '/home/qualification/qualification-public-recovery.json'
# Use an actual vendor-manifest member whose original bytes are recorded.
VENDOR = '/home/qualification/.local/share/applications/localsend-share-folder.desktop'

# One root process, authenticated before launch, owns the control protocol for
# exactly one boot/cycle. Opening another SSH session after DNF can block in
# pam_systemd while PID 1 reconnects its public bus. This channel is control
# only: PUBLIC_HEALTH must still run through fresh ordinary SSH after it closes.
CONTROL_SERVER = r'''
import base64, ctypes, json, os, pathlib, selectors, signal, subprocess, sys, time
boot_path = pathlib.Path('/proc/sys/kernel/random/boot_id')
boot = boot_path.read_text().strip()
deadline = time.monotonic() + 1500
# Adopt escaped command descendants so EOF, cancellation and timeouts can
# terminate/reap them too, including children which called setsid().
if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
    raise RuntimeError('Cannot own control command descendants')
def interrupted(*_args):
    raise RuntimeError('Control process interrupted')
for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
    signal.signal(sig, interrupted)
def emit(event, **values):
    print(json.dumps(dict(event=event, boot=boot_path.read_text().strip(), **values)), flush=True)
def reap():
    # Each request's children are private to this process. Kill by parentage,
    # then reap adopted descendants; never signal an unrelated guest process.
    for _ in range(100):
        children = []
        for entry in pathlib.Path('/proc').glob('[0-9]*/stat'):
            try:
                fields = entry.read_text().rsplit(')', 1)[1].split()
                if int(fields[1]) == os.getpid():
                    children.append(int(entry.parent.name))
            except (FileNotFoundError, ProcessLookupError):
                pass
        for pid in children:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        while True:
            try: pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError: return
            if not pid: break
        time.sleep(.01)
    raise RuntimeError('Control command descendants did not drain')
buffer = b''
emit('ready', protocol=1, uid=os.geteuid())
sequence = 0
try:
    while True:
        with selectors.DefaultSelector() as poll:
            poll.register(0, selectors.EVENT_READ)
            while b'\n' not in buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not poll.select(remaining):
                    raise RuntimeError('Control cycle deadline expired')
                chunk = os.read(0, 65536)
                if not chunk: raise EOFError('Control input closed')
                buffer += chunk
                if len(buffer) > 4194304: raise ValueError('Excessive control request')
        line, buffer = buffer.split(b'\n', 1)
        request = json.loads(line)
        sequence += 1
        if type(request.get('id')) is not int or request['id'] != sequence or boot_path.read_text().strip() != boot:
            raise ValueError('Control sequence or boot changed')
        if request == {'id': sequence, 'op': 'close'}:
            emit('closed', id=sequence)
            break
        if (set(request) != {'id', 'op', 'script', 'timeout'} or request['op'] != 'run'
                or not isinstance(request['script'], str)
                or not 0 < request['timeout'] <= 120):
            raise ValueError('Invalid control request')
        end = min(deadline, time.monotonic() + request['timeout'])
        process = subprocess.Popen(['bash', '-e', '-s'], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            # Scripts are bounded; nonblocking input also handles a command
            # which exits without reading its entire script.
            pending = memoryview(request['script'].encode())
            with selectors.DefaultSelector() as poll:
                poll.register(0, selectors.EVENT_READ, 'control')
                for stream, name in ((process.stdout, 'stdout'), (process.stderr, 'stderr')):
                    os.set_blocking(stream.fileno(), False)
                    poll.register(stream, selectors.EVENT_READ, name)
                os.set_blocking(process.stdin.fileno(), False)
                poll.register(process.stdin, selectors.EVENT_WRITE, 'script')
                while len(poll.get_map()) > 1:
                    remaining = end - time.monotonic()
                    if remaining <= 0: raise TimeoutError('Control request expired')
                    for key, _ in poll.select(remaining):
                        if key.data == 'control':
                            # The protocol is strictly request/response. Extra
                            # input or EOF during execution invalidates it.
                            raise EOFError('Control input changed during request')
                        if key.data == 'script':
                            try: pending = pending[os.write(key.fd, pending):]
                            except BrokenPipeError: pending = memoryview(b'')
                            if not pending:
                                poll.unregister(key.fileobj)
                                key.fileobj.close()
                        else:
                            data = os.read(key.fd, 32768)
                            if data:
                                emit('output', id=sequence, stream=key.data,
                                     data=base64.b64encode(data).decode('ascii'))
                            else:
                                poll.unregister(key.fileobj)
                                key.fileobj.close()
                code = process.wait(timeout=max(.001, end - time.monotonic()))
        finally:
            if process.poll() is None:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            # Reap the direct child through Popen, then all adopted children.
            process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if not stream.closed: stream.close()
            reap()
        emit('result', id=sequence, returncode=code)
finally:
    reap()
'''


class PublicControl:
    """Bounded, non-reconnecting root control; never qualifies public health."""

    def __init__(self, vm, password):
        self.vm, self.password = vm, password
        self.process = None
        self.broken = False
        self.boot = None
        self.sequence = 0
        self.buffer = b''
        self.launch_attempted = False
        self.identifier = None
        self.drained = False
        self.drain_attempted = False
        self.keep_fixture = False

    @property
    def available(self):
        return self.process is not None and not self.broken and self.process.poll() is None

    def remaining(self, bound):
        remaining = min(bound, self.deadline - time.monotonic())
        if remaining <= 0:
            self.broken = True
            raise RuntimeError('Public control cycle exceeded the qualification deadline')
        return remaining

    def __enter__(self):
        self.deadline = time.monotonic() + 1500
        try:
            command = "sudo -k -S -p '' python3 -u -c " + shlex.quote(CONTROL_SERVER)
            self.process = subprocess.Popen([*self.vm.ssh, command], stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                            start_new_session=True)
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                os.set_blocking(stream.fileno(), False)
            end = time.monotonic() + self.remaining(15)
            self._send((self.password + '\n').encode(), end)
            ready = self._receive(end)
            if (set(ready) != {'event', 'boot', 'protocol', 'uid'} or ready['event'] != 'ready'
                    or type(ready['protocol']) is not int or ready['protocol'] != 1
                    or type(ready['uid']) is not int or ready['uid'] != 0
                    or not isinstance(ready['boot'], str)
                    or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', ready['boot'])):
                raise RuntimeError('Invalid public control ready handshake')
            self.boot = ready['boot']
            return self
        except BaseException as error:
            self.broken = True
            self.close(failed=True)
            if isinstance(error, (EOFError, TimeoutError, ValueError, OSError)):
                raise RuntimeError('Public control failed before ready: ' + type(error).__name__) from None
            raise

    def _send(self, data, end):
        with selectors.DefaultSelector() as poll:
            poll.register(self.process.stdin, selectors.EVENT_WRITE)
            while data:
                if time.monotonic() >= end or not poll.select(max(0, end - time.monotonic())):
                    raise TimeoutError('Public control request timed out')
                data = data[os.write(self.process.stdin.fileno(), data):]

    def _receive(self, end):
        with selectors.DefaultSelector() as poll:
            poll.register(self.process.stdout, selectors.EVENT_READ, 'protocol')
            poll.register(self.process.stderr, selectors.EVENT_READ, 'diagnostic')
            while b'\n' not in self.buffer:
                if time.monotonic() >= end:
                    raise TimeoutError('Public control request timed out')
                events = poll.select(max(0, end - time.monotonic()))
                if not events:
                    raise TimeoutError('Public control request timed out')
                for key, _ in events:
                    data = os.read(key.fd, 65536)
                    if key.data == 'diagnostic':
                        # Authentication diagnostics are never protocol or
                        # health evidence, and may contain sensitive text.
                        if not data:
                            poll.unregister(key.fileobj)
                        continue
                    if not data:
                        raise EOFError('Public control SSH closed')
                    self.buffer += data
                    if len(self.buffer) > 4194304:
                        raise ValueError('Excessive public control response')
            line, self.buffer = self.buffer.split(b'\n', 1)
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError('Invalid public control response')
        return value

    def __call__(self, _vm, script, _password, timeout=120, *, shutdown=False):
        if not self.available:
            raise RuntimeError('Public control is unavailable; reconnect is forbidden')
        output = {'stdout': bytearray(), 'stderr': bytearray()}
        try:
            bound = self.remaining(min(timeout, 120))
            end = time.monotonic() + bound
            self.sequence += 1
            request = {'id': self.sequence, 'op': 'run', 'script': script, 'timeout': bound}
            self._send((json.dumps(request) + '\n').encode(), end)
            while True:
                value = self._receive(end)
                if (value.get('boot') != self.boot or type(value.get('id')) is not int
                        or value['id'] != self.sequence):
                    raise ValueError('Public control boot or sequence changed')
                if (set(value) == {'event', 'boot', 'id', 'stream', 'data'}
                        and value['event'] == 'output' and value['stream'] in output):
                    output[value['stream']] += base64.b64decode(value['data'], validate=True)
                    if sum(map(len, output.values())) > 8388608:
                        raise ValueError('Excessive public control output')
                elif (set(value) == {'event', 'boot', 'id', 'returncode'}
                        and value['event'] == 'result' and type(value['returncode']) is int):
                    break
                else:
                    raise ValueError('Malformed public control response')
        except BaseException as error:
            self.broken = True
            # Only poweroff_guest may accept the expected shutdown disconnect,
            # after seeing its unpredictable preparation marker and QEMU exit.
            if shutdown and isinstance(error, EOFError):
                raise subprocess.CalledProcessError(255, ['public-control-shutdown'],
                    output=output['stdout'].decode(errors='replace'),
                    stderr=output['stderr'].decode(errors='replace')) from None
            if isinstance(error, (EOFError, TimeoutError, ValueError, OSError)):
                raise RuntimeError('Public control failed: ' + type(error).__name__) from None
            raise
        result = subprocess.CompletedProcess(['public-control'], value['returncode'],
            output['stdout'].decode(errors='replace'), output['stderr'].decode(errors='replace'))
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, result.args,
                output=result.stdout.replace(self.password, '[redacted]'),
                stderr=result.stderr.replace(self.password, '[redacted]'))
        return result

    def start(self):
        self.launch_attempted = True
        self.identifier = start_public(self.vm, self.password, timeout=self.remaining(90))
        # Detect a changed boot even when the ordinary launcher returned a
        # plausible run record. No evidence is awarded on this channel alone.
        self(self.vm, 'true\n', self.password)
        return self.identifier

    def ensure_drained(self):
        if self.drained:
            return True
        if self.drain_attempted or not self.available:
            return False
        if self.launch_attempted and not self.identifier:
            return False
        self.drain_attempted = True
        if self.identifier:
            stop_interrupted(self.vm, self.password, self, self.identifier, {}, strict=False)
        self.drained = True
        return True

    def cleanup_staging(self, vm, script, password, timeout=30):
        if self.ensure_drained():
            self(vm, script, password, timeout=timeout)
        # Lost control leaves guest files/workers to the owned VM teardown.

    def poweroff(self):
        from vm_testing import poweroff_guest
        def execute(vm, script, password):
            return self(vm, script, password, shutdown='systemctl poweroff --no-block\n' in script)
        process = self.vm.process
        control = self
        class BoundedProcess:
            def wait(self, timeout):
                # Preparation consumed part of the cycle too. Recompute at
                # the actual QEMU wait, retaining the existing 90s upper bound.
                return process.wait(timeout=control.remaining(timeout))
            def __getattr__(self, name):
                return getattr(process, name)
        self.vm.process = BoundedProcess()
        try:
            poweroff_guest(self.vm, self.password, execute, timeout=self.remaining(90))
        finally:
            self.vm.process = process
        self.keep_fixture = True  # The pre-login observer must survive reboot.

    def close(self, *, failed=False):
        if self.process is None:
            return
        error = None
        try:
            if self.available and not self.keep_fixture:
                end = time.monotonic() + self.remaining(5)
                self.sequence += 1
                self._send((json.dumps({'id': self.sequence, 'op': 'close'}) + '\n').encode(), end)
                reply = self._receive(end)
                if (type(reply.get('id')) is not int
                        or reply != {'event': 'closed', 'boot': self.boot, 'id': self.sequence}):
                    raise RuntimeError('Invalid public control close acknowledgement')
            elif not failed and not self.keep_fixture:
                raise RuntimeError('Public control was lost before close')
        except BaseException as caught:
            error = caught
        finally:
            self.broken = True
            self.process.stdin.close()
            try:
                code = self.process.wait(timeout=3)
                expected = (0, 255) if self.keep_fixture else (0,)
                if code not in expected and not failed and error is None:
                    error = RuntimeError('Public control SSH exited unsuccessfully')
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(self.process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    self.process.wait()
                if not failed and error is None:
                    error = RuntimeError('Public control SSH did not close')
            self.process.stdout.close()
            self.process.stderr.close()
        if error is not None and not failed:
            raise error

    def __exit__(self, kind, _value, _traceback):
        failed = kind is not None
        try:
            if not self.keep_fixture and self.ensure_drained():
                cleanup_fixture(self.vm, self.password, self)
        except BaseException:
            if not failed:
                raise
        finally:
            self.close(failed=failed or sys.exc_info()[0] is not None)

# This process runs before the recovery service, independently of logins, and
# writes outside root so the first recovery boot's evidence survives root swap.
OBSERVER_SCRIPT = r'''#!/usr/bin/python3
import glob, json, pathlib, signal, subprocess, time
# Reboot may be queued immediately after the durable terminal write. Finish
# observing that write before our unit stops; mixed kill mode keeps the probe alive.
signal.signal(signal.SIGTERM, lambda *_args: None)
home = pathlib.Path('/home/qualification')
output = home / 'qualification-public-recovery.json'
identifier = (home / 'qualification-public-run-id').read_text().strip()
boot = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
if output.exists() and json.loads(output.read_text()).get('state') == 'rolled-back':
    pathlib.Path('/run/cybexos-qualification-observer-ready').touch()
    raise SystemExit(0)
seen = []
for _ in range(12000):
    candidates = ['/usr/libexec/cybexos-update-transaction'] + glob.glob(
        '/usr/local/libexec/cybexos-update-bootstrap.d/*/cybexos-update-transaction')
    helper = next((p for p in candidates if pathlib.Path(p).is_file()), None)
    if helper:
        result = subprocess.run([helper, 'status', identifier], capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            record = json.loads(result.stdout)
            if record['state'] in ('applying', 'rolling-back', 'rolled-back'):
                # Check the real systemd ordering barrier while recovery runs.
                for unit in ('sddm.service', 'systemd-user-sessions.service'):
                    state = subprocess.check_output(['systemctl', 'show', unit, '-p', 'ActiveState', '--value'], text=True).strip()
                    assert state not in ('active', 'activating', 'reloading'), 'Login started before recovery settled'
                assert pathlib.Path('/run/nologin').exists(), 'Login barrier is absent'
                if record['state'] not in seen:
                    seen.append(record['state'])
                value = {'bootId': boot, 'transaction': identifier, 'states': seen,
                         'preLogin': True, 'state': record['state']}
                temporary = output.with_suffix('.tmp')
                temporary.write_text(json.dumps(value) + '\n')
                temporary.replace(output)
                pathlib.Path('/run/cybexos-qualification-observer-ready').touch()
                if record['state'] == 'rolled-back':
                    break
            elif record['state'] in ('committed', 'aborted'):
                raise RuntimeError('The interrupted transaction did not recover')
    time.sleep(0.1)
else:
    raise RuntimeError('Boot recovery did not settle within its deadline')
'''

DNF_ADAPTER = r'''#!/usr/bin/python3
import hashlib, json, os, pathlib, subprocess, sys, time
work = pathlib.Path('/run/cybexos-qualification-public')
config = json.loads((work / 'dnf.json').read_text())
args = sys.argv[1:]
expected = ['-y', 'upgrade', '--refresh', '--no-best']
assert args in (expected, expected + ['--downloadonly']), 'Unexpected qualification DNF invocation'
for record in config['rpms']:
    path = pathlib.Path(record['path'])
    assert path.is_file() and not path.is_symlink() and path.stat().st_uid == 0
    assert hashlib.sha256(path.read_bytes()).hexdigest() == record['sha256'], 'Staged candidate changed'
command = ['/usr/bin/dnf', '-y', '--disablerepo=*', 'install']
if '--downloadonly' in args:
    command.append('--downloadonly')
subprocess.run(command + [r['path'] for r in config['rpms']], check=True, timeout=1200)
if '--downloadonly' not in args and config['interrupt']:
    vendor = pathlib.Path(config['vendor'])
    vendor.unlink()
    vendor.write_bytes(b'qualification candidate vendor bytes\n')
    pathlib.Path('/etc/cybexos/qualification-public-root').write_text('applied\n')
    # A personal edit made AFTER the checkpoint must also survive rollback.
    pathlib.Path('/home/qualification/qualification-public-personal').write_text('after-checkpoint\n')
    heartbeat = work / 'heartbeat'
    code = 'import pathlib,sys,time\np=pathlib.Path(sys.argv[1])\nwhile True:\n p.open("a").write("worker\\n"); time.sleep(.05)\n'
    child = subprocess.Popen(['/usr/bin/python3', '-c', code, str(heartbeat)], start_new_session=True)
    (work / 'applied.json').write_text(json.dumps({'pid': os.getpid(), 'detachedPid': child.pid}))
    # The host kills the real updater unit here. Expiry fails the qualification
    # and exercises normal updater error handling, never an unbounded fixture.
    for _ in range(3000):
        time.sleep(.1)
    raise RuntimeError('Qualification interruption was not delivered')
'''


# Run only inside the already-owned candidate guest. Local fixtures substitute
# the manager boundary; this release check exercises actual systemd runtime
# limits, setsid and lock lifetime against the installed helper.
PROVISION_TIMEOUT = r'''python3 - <<'PY'
import fcntl, importlib.machinery, importlib.util, pathlib, subprocess, tempfile, time
loader = importlib.machinery.SourceFileLoader('qualification_provision', '/usr/libexec/cybexos-configure-installed')
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='cybexos-qualification-provision-', dir='/run') as temporary:
    directory = pathlib.Path(temporary)
    heartbeat = directory / 'heartbeat'
    overlap = directory / 'overlap'
    worker = directory / 'worker.py'
    code = 'import fcntl,pathlib,sys,time\nheartbeat,overlap=map(pathlib.Path,sys.argv[1:])\nwhile True:\n with open("/run/lock/cybexos/provision.lock","a") as lock:\n  try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)\n  except BlockingIOError: pass\n  else: overlap.touch()\n with heartbeat.open("a") as stream: stream.write("descendant\\n")\n time.sleep(.02)\n'
    worker.write_text('import subprocess,sys,time\nsubprocess.Popen([sys.executable,"-c",' + repr(code) + ',sys.argv[1],sys.argv[2]],start_new_session=True)\ntime.sleep(120)\n')
    environment = {'PATH':'/usr/sbin:/usr/bin:/sbin:/bin','HOME':'/root',
                   'LANG':'C.UTF-8','PYTHONDONTWRITEBYTECODE':'1'}
    lockdir = pathlib.Path('/run/lock/cybexos')
    lockdir.mkdir(exist_ok=True)
    with (lockdir / 'provision.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            module.contained(['/usr/bin/python3', str(worker), str(heartbeat), str(overlap)], env=environment, timeout=2)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
        else:
            raise RuntimeError('The deliberately timed-out provisioning workload succeeded')
        assert heartbeat.is_file() and heartbeat.stat().st_size > 0, 'Detached writer never ran'
        settled = heartbeat.read_bytes()
        assert not overlap.exists(), 'Provisioning serialization was released early'
        assert not module.populated(), 'Provisioning cgroup was still populated after timeout'
        time.sleep(.2)
        assert heartbeat.read_bytes() == settled, 'Detached worker wrote after timeout'
        retry = 'import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); before=p.read_bytes(); time.sleep(.2); assert p.read_bytes()==before'
        module.contained(['/usr/bin/python3','-c',retry,str(heartbeat)], env=environment, timeout=10)
        assert heartbeat.read_bytes() == settled and not overlap.exists(), 'Retry overlapped a timed-out worker'
PY
'''


PUBLIC_HEALTH = r'''import json, os, pwd, shlex, subprocess, time
deadline = time.monotonic() + 45
# Pin public inspection to the ordinary system bus, even if SSH inherited a
# bus-address environment variable. Never fall back to /run/systemd/private.
os.environ['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=/run/dbus/system_bus_socket'
def command(args):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError('Public manager health inspection exceeded its deadline')
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True,
                              timeout=min(10, remaining)).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        stderr = error.stderr or ''
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors='replace')
        if len(stderr) > 2000:
            stderr = '[stderr omitted: ' + str(len(stderr)) + ' characters exceeds 2000-character limit]'
        reason = ('timed out' if isinstance(error, subprocess.TimeoutExpired)
                  else 'exited ' + str(error.returncode))
        raise RuntimeError('Public health command ' + os.path.basename(args[0]) + ' ' + reason
                           + ': ' + stderr) from None
version = shlex.split(command(['/usr/bin/busctl', '--system', '--timeout=10',
    'get-property', 'org.freedesktop.systemd1', '/org/freedesktop/systemd1',
    'org.freedesktop.systemd1.Manager', 'Version']))
if len(version) != 2 or version[0] != 's' or not version[1].strip():
    raise RuntimeError('Public system bus did not return Manager.Version')
account = pwd.getpwuid(os.getuid())
if account.pw_name != 'qualification' or account.pw_uid < 1000:
    raise RuntimeError('Public health inspection requires the ordinary qualification SSH account')
# Read the existing user's session directly. The Fedora RPM trigger's root
# --user -M bridge is precisely the path that may have missed marked work.
os.environ['XDG_RUNTIME_DIR'] = '/run/user/' + str(account.pw_uid)
os.environ['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=' + os.environ['XDG_RUNTIME_DIR'] + '/bus'
evidence = {'public_manager_version': version[1], 'ssh_user': account.pw_name,
            'ssh_uid': account.pw_uid}
for scope in ('system', 'user'):
    client = ['/usr/bin/systemctl', '--' + scope, '--no-pager']
    listing = json.loads(command(client + ['list-units', '--all', '--output=json']))
    if not isinstance(listing, list) or not listing or len(listing) > 2048:
        raise RuntimeError('Invalid or excessive ' + scope + ' unit inventory')
    names = sorted({row['unit'] for row in listing} | set(required[scope]))
    properties = ('Id', 'Markers', 'LoadState', 'ActiveState', 'SubState', 'UnitFileState', 'Result')
    units = {}
    for offset in range(0, len(names), 64):
        output = command(client + ['show', '--all',
                         '--property=' + ','.join(properties), '--', *names[offset:offset + 64]])
        for block in output.strip().split('\n\n'):
            values = dict(line.split('=', 1) for line in block.splitlines())
            name = values['Id']
            if name in units or not set(('Id', 'Markers', 'LoadState', 'ActiveState', 'SubState')) <= values.keys():
                raise RuntimeError('Incomplete or duplicate ' + scope + ' unit state: ' + name)
            values['Markers'] = values['Markers'].split()
            units[name] = values
    if set(units) != set(names):
        raise RuntimeError('Incomplete ' + scope + ' unit inventory')
    evidence[scope] = units
print(json.dumps(evidence))
'''


def required_service_states():
    # Read the shared workstation service policy, rather than inventing a
    # separate baseline. RPM posttrans enables the additional packaged units;
    # only its --now watchers must be active. Enabled oneshots may be inactive.
    import yaml
    defaults = yaml.safe_load((ROOT / 'roles/base/defaults/main.yml').read_text())
    system = {name: {'enabled': True, 'active': True} for name in defaults['base_core_services']}
    system['sddm.service'] = {'active': True}
    for name in ('cybexos-titlebars-build.path', 'cybexos-reconcile.timer'):
        system[name] = {'enabled': True, 'active': True}
    for name in ('cybexos-titlebars-build.service', 'cybexos-recovery-refresh.service',
                 'cybexos-update-recover.service', 'cybexos-major-upgrade-validate.timer',
                 'cybexos-hardware-setup.timer', 'cybexos-first-boot.service', 'cybexos-new-owner.service'):
        system[name] = {'enabled': True}
    # These are the running desktop services already required by TestVM.audit.
    user = {name + '.service': {'active': True} for name in ('quickshell', 'hypridle', 'voxtype')}
    return {'system': system, 'user': user}


def validate_public_health(evidence, required):
    if (not isinstance(evidence.get('public_manager_version'), str)
            or not evidence['public_manager_version'].strip()
            or evidence.get('ssh_user') != 'qualification'
            or type(evidence.get('ssh_uid')) is not int or evidence['ssh_uid'] < 1000):
        raise RuntimeError('Public manager or ordinary SSH health evidence is missing')
    for scope in ('system', 'user'):
        units = evidence.get(scope)
        if not isinstance(units, dict) or not units:
            raise RuntimeError('Missing ' + scope + ' unit health evidence')
        for name, state in units.items():
            markers = state.get('Markers')
            if not isinstance(markers, list) or not all(isinstance(item, str) for item in markers):
                raise RuntimeError('Missing ' + scope + ' unit markers: ' + name)
            pending = sorted(set(markers) & {'needs-restart', 'needs-reload'})
            if pending:
                raise RuntimeError('Pending RPM-trigger work in ' + scope + ' unit ' + name + ': ' + ', '.join(pending))
            # Other marker types are retained verbatim, not cleared or treated
            # as a request to restart anything during read-only qualification.
        for name, policy in required[scope].items():
            state = units.get(name, {})
            if (state.get('LoadState') != 'loaded'
                    or state.get('ActiveState') not in ('active', 'inactive')
                    or state.get('Result', 'success') != 'success'
                    or (name.endswith('.service') and state.get('Result') != 'success')
                    or (policy.get('active') and state.get('ActiveState') != 'active')
                    or (policy.get('enabled') and state.get('UnitFileState') != 'enabled')):
                raise RuntimeError('Required ' + scope + ' unit is unhealthy: ' + name)


def verify_public_health(vm, password, root_script):
    required = required_service_states()
    script = 'required = ' + repr(required) + '\n' + PUBLIC_HEALTH
    try:
        # This query uses the actual public system bus from ordinary SSH. A
        # root-private daemon-reload cannot stand in for this health evidence.
        result = run([*vm.ssh, 'python3 -'], input=script, text=True, capture_output=True, timeout=55)
        evidence = json.loads(result.stdout)
        validate_public_health(evidence, required)
        sudo = subprocess.run([*vm.ssh, 'sudo -k -n true'], capture_output=True, text=True, timeout=15)
        if sudo.returncode != 1:
            raise RuntimeError('Post-update sudo no longer requires ordinary password authentication')
        authenticated = root_script(vm, 'id -u\n', password, timeout=15)
        if authenticated.stdout.strip() != '0':
            raise RuntimeError('Post-update password-authenticated sudo is not functional')
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        reason = ('timed out' if isinstance(error, subprocess.TimeoutExpired)
                  else f'exited {error.returncode}')
        details = []
        for value in (error.stdout, error.stderr):
            if isinstance(value, bytes):
                value = value.decode(errors='replace')
            if value:
                details.append(value.replace(password, '[redacted]'))
        raise RuntimeError('Post-update public health inspection failed (' + reason + '): ' +
                           '\n'.join(details)[-5000:]) from None
    evidence['password_authenticated_sudo'] = True
    evidence['service_requirements'] = required
    return evidence


def transfer_source(vm, password, root_script):
    files = ['assets/scripts/cybexos-update-run', 'site.yml', 'tests/run']
    files += ['roles/base/files/' + name for name in (
        'cybexos-system-snapshot', 'cybexos-update-transaction', 'cybexos-update-recover',
        'cybexos-major-upgrade', 'cybexos-update-bootstrap', 'cybexos-vendor-paths.json',
        'cybexos-update-recover.service', 'cybexos-update-recover-login.conf')]
    # root_script's authenticated channel writes reviewed source as data; it
    # grants neither a new sudo policy nor a production qualification switch.
    script = "python3 - <<'PY'\nfrom pathlib import Path\nimport time\n"
    script += f'root = Path({SOURCE!r})\nroot.mkdir(parents=True, exist_ok=True, mode=0o755)\n'
    for relative in files:
        content = (ROOT / relative).read_text()
        script += (f'p = root / {relative!r}\np.parent.mkdir(parents=True, exist_ok=True)\n'
                   f'p.write_text({content!r})\np.chmod(0o755)\n')
    script += 'PY\n'
    root_script(vm, script, password)
    return digest(ROOT / 'assets/scripts/cybexos-update-run')


def provision_fixture(vm, password, root_script, rpms, interrupt):
    records = [{'path': path, 'sha256': sha} for path, sha in rpms]
    script = "python3 - <<'PY'\nfrom pathlib import Path\nimport json\n"
    script += f'work = Path({WORK!r})\nwork.mkdir(parents=True, exist_ok=True, mode=0o755)\n'
    script += "adapter = Path('/usr/local/bin/dnf')\nassert not adapter.exists() and not adapter.is_symlink(), 'Refusing to replace an existing DNF command'\n"
    script += f'adapter.write_text({DNF_ADAPTER!r})\nadapter.chmod(0o755)\n'
    config = {'rpms': records, 'interrupt': interrupt, 'vendor': VENDOR}
    script += f'(work / "dnf.json").write_text({json.dumps(config)!r})\n'
    script += "Path('/etc/cybexos/qualification-public-root').write_text('before\\n')\n"
    script += f"vendor = Path({VENDOR!r})\nif not vendor.exists() and not vendor.is_symlink():\n vendor.parent.mkdir(parents=True, exist_ok=True)\n vendor.write_text('[Desktop Entry]\\nType=Application\\nName=Qualification sentinel\\nExec=/usr/bin/true\\n')\n"
    if interrupt:
        script += f'Path({OBSERVER!r}).write_text({OBSERVER_SCRIPT!r})\nPath({OBSERVER!r}).chmod(0o755)\n'
        unit = ('[Unit]\nDescription=Observe disposable qualification recovery before login\n'
                'After=local-fs.target\nRequiresMountsFor=/home /var\n'
                'Before=cybexos-update-recover.service systemd-user-sessions.service sddm.service\n'
                '[Service]\nType=simple\nExecStart=' + OBSERVER + '\n'
                'ExecStartPost=/usr/bin/timeout 30 /usr/bin/bash -c "until test -e /run/cybexos-qualification-observer-ready; do sleep .1; done"\n'
                'KillMode=mixed\nTimeoutStopSec=30\n[Install]\nWantedBy=multi-user.target\n')
        script += f'Path("/etc/systemd/system/{UNIT}").write_text({unit!r})\n'
    script += 'PY\n'
    script += 'restorecon /usr/local/bin/dnf\n'
    if interrupt:
        script += f'restorecon {OBSERVER} /etc/systemd/system/{UNIT}\n'
        script += f'systemctl daemon-reload\nsystemctl enable {UNIT}\n'
    root_script(vm, script, password)


def start_public(vm, password, *, timeout=90):
    # Authenticate through the existing sudo policy. The client's cached
    # authorization launches the normal root worker; no testing environment
    # override or passwordless rule is installed.
    # With -v, sudo's -k deliberately prevents retaining the validated ticket.
    # Invalidate separately so the following ordinary validation caches it.
    def diagnostics(stdout, stderr):
        values = []
        for label, value in (('stdout', stdout), ('stderr', stderr)):
            if isinstance(value, bytes):
                value = value.decode(errors='replace')
            if value:
                values.append(label + ': ' + value.replace(password, '[redacted]'))
        return '\n'.join(values)[-5000:]

    try:
        result = run([*vm.ssh, "sudo -k && sudo -S -p '' -v && exec " + shlex.quote(UPDATER) +
                      ' start --json --no-flatpak --system-unit'], input=password + '\n', text=True,
                     capture_output=True, timeout=timeout)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        reason = ('timed out' if isinstance(error, subprocess.TimeoutExpired)
                  else f'exited {error.returncode}')
        raise RuntimeError('Public updater launch ' + reason + ': ' +
                           diagnostics(error.stdout, error.stderr)) from None
    try:
        status = json.loads(result.stdout)
    except ValueError:
        raise RuntimeError('Public updater did not return a run record: ' +
                           diagnostics(result.stdout, result.stderr)) from None
    if (not re.fullmatch(r'\d{8}-\d{6}-\d+-\d+', str(status.get('id', '')))
            or status.get('systemUnit') is not True or status.get('state') not in ('queued', 'running')):
        raise RuntimeError('Public updater did not launch its durable system worker')
    return status['id']


def guest_record(vm, password, root_script, identifier):
    script = "python3 - <<'PY'\nimport json\nfrom pathlib import Path\n"
    script += f"root = Path('/home/qualification/.local/state/cybexos/update/logs') / {identifier!r}\n"
    script += "print((root / 'status.json').read_text())\nPY\n"
    return json.loads(root_script(vm, script, password).stdout)


def transaction(vm, password, root_script, identifier):
    script = "python3 - <<'PY'\nimport glob, pathlib, subprocess\n"
    script += "candidates = ['/usr/libexec/cybexos-update-transaction'] + glob.glob('/usr/local/libexec/cybexos-update-bootstrap.d/*/cybexos-update-transaction')\n"
    script += "helper = next(p for p in candidates if pathlib.Path(p).is_file())\n"
    script += f"subprocess.run([helper, 'status', {identifier!r}], check=True)\nPY\n"
    return json.loads(root_script(vm, script, password).stdout)


def wait_public(vm, password, root_script, identifier, *, interrupted=False):
    deadline = root_script.deadline if isinstance(root_script, PublicControl) else time.monotonic() + 1500
    while time.monotonic() < deadline:
        status = guest_record(vm, password, root_script, identifier)
        if interrupted:
            result = root_script(vm, f'if test -f {WORK}/applied.json; then cat {WORK}/applied.json; fi\n', password)
            if result.stdout.strip():
                if transaction(vm, password, root_script, identifier)['state'] != 'applying':
                    raise RuntimeError('Interruption boundary is outside the durable applying state')
                return status, json.loads(result.stdout)
        if status['state'] in ('done', 'failed', 'cancelled'):
            if interrupted or status['state'] != 'done' or status.get('exitCode') != 0:
                raise RuntimeError('Public updater did not reach the expected boundary: ' + status['state'])
            record = transaction(vm, password, root_script, identifier)
            if record['state'] != 'committed':
                raise RuntimeError('Public updater returned success without committing its journal')
            return status, record
        time.sleep(1)
    raise RuntimeError('Public updater exceeded the qualification deadline')


def stop_interrupted(vm, password, root_script, identifier, workers, *, strict=True):
    unit = 'cybexos-update-' + identifier + '.service'
    script = f"systemctl kill --kill-whom=all --signal=SIGKILL {shlex.quote(unit)}\n"
    if not strict:
        # A terminal/failed launch may already have unloaded its unit. The
        # cgroup, heartbeat and recorded PID checks below remain mandatory.
        script = script.rstrip() + ' || true\n'
    script += "python3 - <<'PY'\nimport pathlib,time\n"
    script += f"group = pathlib.Path('/sys/fs/cgroup/system.slice/{unit}')\n"
    script += f"heartbeat = pathlib.Path('{WORK}/heartbeat')\n"
    script += "for _ in range(300):\n if not group.exists() or 'populated 1' not in (group / 'cgroup.events').read_text().splitlines(): break\n time.sleep(.1)\nelse: raise RuntimeError('Updater workers survived SIGKILL')\n"
    script += "before = heartbeat.read_bytes() if heartbeat.exists() else b''\ntime.sleep(.3)\nassert (heartbeat.read_bytes() if heartbeat.exists() else b'') == before, 'Detached worker kept writing'\n"
    for pid in workers.values():
        if type(pid) is not int or pid <= 1:
            raise ValueError('Invalid qualification worker PID')
        script += f"assert not pathlib.Path('/proc/{pid}').exists() or pathlib.Path('/proc/{pid}/stat').read_text().split()[2] == 'Z', 'Worker survived'\n"
    script += f"applied = pathlib.Path('{WORK}/applied.json')\n"
    script += "if applied.exists():\n import json\n for pid in json.loads(applied.read_text()).values():\n  assert type(pid) is int and pid > 1, 'Invalid worker PID'\n  process = pathlib.Path('/proc') / str(pid) / 'stat'\n  assert not process.exists() or process.read_text().rsplit(')', 1)[1].split()[0] == 'Z', 'Recorded worker survived'\n"
    script += 'PY\n'
    script += 'systemctl stop cybexos-reconcile.service\n/usr/libexec/cybexos-configure-installed --drain\n'
    root_script(vm, script, password)
    verify_no_workers(vm, password, root_script, [identifier])


def cleanup_fixture(vm, password, root_script):
    # A failed admission must not remove a pre-existing command. Byte identity
    # also recognizes our own adapter after root rollback erased /run state.
    script = "python3 - <<'PY'\nfrom pathlib import Path\nimport shutil,subprocess\n"
    script += f"adapter = Path('/usr/local/bin/dnf')\nexpected = {DNF_ADAPTER!r}\n"
    script += "if not adapter.is_symlink() and adapter.is_file() and adapter.read_text() == expected:\n adapter.unlink()\n"
    script += f"observer = Path({OBSERVER!r})\nunit = Path('/etc/systemd/system/{UNIT}')\n"
    script += f"if not observer.is_symlink() and observer.is_file() and observer.read_text() == {OBSERVER_SCRIPT!r}:\n"
    script += f" subprocess.run(['systemctl','disable','--now',{UNIT!r}],check=False,timeout=60)\n observer.unlink()\n unit.unlink(missing_ok=True)\n"
    script += f"work = Path({WORK!r})\nif work.is_dir() and not work.is_symlink(): shutil.rmtree(work)\n"
    script += "subprocess.run(['systemctl','daemon-reload'],check=True,timeout=30)\nPY\n"
    root_script(vm, script, password)


def verify_recovered(vm, password, root_script, identifier, before):
    record = transaction(vm, password, root_script, identifier)
    # bootId identifies the interrupted boot, not the recovery boot.
    if record['state'] != 'rolled-back' or record['bootId'] != before['boot_id']:
        raise RuntimeError('Interrupted journal did not settle as rolled-back')
    script = "python3 - <<'PY'\nimport glob,hashlib,importlib.machinery,importlib.util,json,pathlib,subprocess\n"
    script += f"evidence = json.loads(pathlib.Path({EVIDENCE!r}).read_text())\n"
    script += f"assert evidence['transaction'] == {identifier!r} and evidence['preLogin'] is True\n"
    script += "assert evidence['state'] == 'rolled-back' and 'applying' in evidence['states']\n"
    script += f"assert evidence['bootId'] != {before['boot_id']!r}\n"
    script += "boot = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()\nassert boot != evidence['bootId'], 'Recovery did not complete its automatic restart'\n"
    script += "assert pathlib.Path('/etc/cybexos/qualification-public-root').read_text() == 'before\\n'\n"
    script += f"assert hashlib.sha256(pathlib.Path({VENDOR!r}).read_bytes()).hexdigest() == {before['vendor_sha256']!r}, 'Vendor checkpoint was not restored'\n"
    script += "assert pathlib.Path('/home/qualification/qualification-public-personal').read_text() == 'after-checkpoint\\n', 'Personal post-checkpoint edit was lost'\n"
    script += "packages = subprocess.check_output(['rpm','-q','--qf','%{NEVRA}\\n','cybexos-desktop','cybexos-offline-apps'],text=True)\n"
    script += f"assert packages == {before['packages']!r}, 'Package identity did not roll back'\n"
    script += "helpers = ['/usr/libexec/cybexos-system-snapshot'] + glob.glob('/usr/local/libexec/cybexos-update-bootstrap.d/*/cybexos-system-snapshot')\npath = next(p for p in helpers if pathlib.Path(p).is_file())\nloader = importlib.machinery.SourceFileLoader('qualification_snapshot', path)\nspec = importlib.util.spec_from_loader(loader.name, loader)\nmodule = importlib.util.module_from_spec(spec)\nloader.exec_module(module)\nlayout = module.detect_layout()\nassert layout.running == '/root' and not layout.pending_reboot\n"
    script += f"point = {record['snapshot']!r}\n"
    script += "with module.opened_store(layout, create=False) as store:\n records = [module.read_record(store, p.stem) for p in store.replaced.glob('*.json')]\n restored = [r for r in records if r.get('point') == point and r.get('state') == 'complete']\n assert len(restored) == 1, 'Recovery exchanged the root more than once'\n assert module.subvolume_uuid(store.top / 'root') == restored[0]['newRoot'], 'Running root differs from restored root'\n assert not (store.metadata / (point + '.pin')).exists(), 'Terminal journal still pins recovery point'\n assert not (store.path / 'transactions' / " + repr(identifier) + " / 'vendor').exists(), 'Vendor checkpoint did not settle'\n print(json.dumps({'rootUuid': restored[0]['newRoot'], 'bootId': boot, 'recoveryBootId': evidence['bootId']}))\nPY\n"
    return json.loads(root_script(vm, script, password).stdout)


def verify_no_workers(vm, password, root_script, identifiers):
    script = "python3 - <<'PY'\nfrom pathlib import Path\nimport time\n"
    groups = ['cybexos-update-' + identifier + '.service' for identifier in identifiers]
    groups += ['cybexos-provision-work.service', 'cybexos-reconcile.service']
    script += f'groups = {groups!r}\n'
    script += "for unit in groups:\n path = Path('/sys/fs/cgroup/system.slice') / unit / 'cgroup.events'\n for _ in range(300):\n  if not path.exists() or 'populated 1' not in path.read_text().splitlines(): break\n  time.sleep(.1)\n else: raise RuntimeError('A transaction worker survived')\nPY\n"
    root_script(vm, script, password)


def installed_updater_identity(candidate, candidate_sha256, candidate_size):
    """Check installed bytes against the exact candidate's packaged manifest."""
    import hashlib
    import os
    import re
    import stat
    import subprocess
    import time

    deadline = time.monotonic() + 30
    installed = '/usr/share/cybexos/bin/cybexos-update-run'

    def remaining():
        value = deadline - time.monotonic()
        if value <= 0:
            raise RuntimeError('Installed updater identity exceeded its deadline')
        return value

    def opened(path):
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        stream = os.fdopen(descriptor, 'rb')
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_gid != 0
                or info.st_mode & 0o022):
            stream.close()
            raise RuntimeError('Updater identity requires protected root-owned regular files')
        return stream

    def fingerprint(stream, size):
        before = os.fstat(stream.fileno())
        if before.st_size != size or size <= 0:
            raise RuntimeError('Updater identity file size mismatch')
        checksum = hashlib.sha256()
        unread = size
        while unread:
            remaining()
            data = stream.read(min(unread, 1024 * 1024))
            if not data:
                raise RuntimeError('Updater identity file changed while hashing')
            checksum.update(data)
            unread -= len(data)
        after = os.fstat(stream.fileno())
        if stream.read(1) or (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise RuntimeError('Updater identity file changed while hashing')
        return checksum.hexdigest()

    def query(arguments, *, pass_fds=()):
        result = subprocess.run(['/usr/bin/rpm', *arguments], check=True, capture_output=True,
                                text=True, timeout=min(10, remaining()), pass_fds=pass_fds)
        if len(result.stdout) > 4 * 1024 * 1024:
            raise RuntimeError('Excessive updater RPM header output')
        return result.stdout.splitlines()

    if (not re.fullmatch(r'[0-9a-f]{64}', candidate_sha256)
            or type(candidate_size) is not int or candidate_size <= 0):
        raise ValueError('Invalid updater candidate binding')
    with opened(candidate) as stream:
        if fingerprint(stream, candidate_size) != candidate_sha256:
            raise RuntimeError('Updater candidate RPM checksum mismatch')
        # RPM's documented parallel file arrays preserve the canonical package
        # rendering. Query the pinned, already-hashed inode, never raw source
        # or a second mutable candidate pathname. OpenPGP SHA256 algorithm=8.
        queryformat = ('%{NEVRA}\n%{FILEDIGESTALGO}\n'
                       '[%{FILENAMES}\t%{FILEDIGESTS}\t%{FILEMODES}\t'
                       '%{FILEUSERNAME}\t%{FILEGROUPNAME}\n]')
        header = query(['-qp', '--qf', queryformat, '--', f'/proc/self/fd/{stream.fileno()}'],
                       pass_fds=(stream.fileno(),))
    if (len(header) < 3 or not re.fullmatch(r'cybexos-desktop-[^\s/]{1,240}', header[0])
            or header[1] != '8'):
        raise RuntimeError('Invalid updater RPM identity or non-SHA256 file digests')
    rows = [line.split('\t') for line in header[2:]]
    if any(len(row) != 5 for row in rows):
        raise RuntimeError('Malformed updater RPM file manifest')
    matches = [row for row in rows if row[0] == installed]
    if len(matches) != 1:
        raise RuntimeError('Updater RPM must contain exactly one installed helper entry')
    _path, expected, mode, owner, group = matches[0]
    if (not re.fullmatch(r'[0-9a-f]{64}', expected) or not re.fullmatch(r'[0-9]{1,5}', mode)
            or not stat.S_ISREG(int(mode)) or int(mode) & 0o022 or (owner, group) != ('root', 'root')):
        raise RuntimeError('Invalid updater RPM helper digest, type or ownership')
    if query(['-q', '--qf', '%{NEVRA}\n', 'cybexos-desktop']) != [header[0]]:
        raise RuntimeError('Installed updater package differs from the bound candidate NEVRA')
    with opened(installed) as stream:
        size = os.fstat(stream.fileno()).st_size
        if size > 4 * 1024 * 1024:
            raise RuntimeError('Excessive installed updater size')
        actual = fingerprint(stream, size)
    if actual != expected:
        raise RuntimeError('Installed updater differs from the bound candidate file digest')
    remaining()
    return {'path': installed, 'expected_sha256': expected, 'actual_sha256': actual,
            'candidate_rpm_sha256': candidate_sha256, 'candidate_nevra': header[0]}


def verify_installed_updater(vm, password, root_script, candidate, candidate_sha256, candidate_size):
    script = "python3 - <<'PY'\nimport json\n" + inspect.getsource(installed_updater_identity)
    script += (f'\nprint(json.dumps(installed_updater_identity({candidate!r}, '
               f'{candidate_sha256!r}, {candidate_size!r})))\nPY\n')
    return json.loads(root_script(vm, script, password, timeout=30).stdout)


def boot_recovered(vm, password):
    """Let both pre-login recovery boots settle before restoring test access."""
    vm.start(user='qualification')
    vm.unlock_disk(password)
    from vm_testing import is_disk_prompt
    deadline = time.monotonic() + 60
    while is_disk_prompt(vm.screen_text()):
        if time.monotonic() >= deadline:
            raise RuntimeError('The first recovery boot did not leave its unlock prompt')
        time.sleep(1)
    # This second prompt is reached only after automatic recovery has settled
    # and requested its restart. Never bootstrap SSH on the recovery boot.
    vm.unlock_disk(password, timeout=900)
    try:
        vm.wait_ssh(timeout=12, setup=False, redactions=(password,))
    except RuntimeError:
        # The restored baseline disables sshd and closes SSH in the firewall.
        # Authenticate at the normal console after pam_nologin releases it;
        # start SSH/open the runtime firewall only, as boot_installed does.
        vm.bootstrap_installed_ssh(password)
    from qualification import focus_installed_desktop
    focus_installed_desktop(vm, password, True)


def qualify_public_updater(vm, candidate, offline_candidate, password, root_script,
                           *, candidate_dependencies, boot_installed, poweroff_installed,
                           verify_user_choices, preference, report):
    # Import here to retain the existing upgrade module's public input helpers.
    from upgrade_qualification import (CANDIDATE, OFFLINE_CANDIDATE, copy_candidate,
                                       copy_dependencies, inspect_version)
    if not offline_candidate:
        raise ValueError('Public updater qualification requires both candidate RPMs')
    sha = copy_candidate(vm, candidate)
    offline_sha = copy_candidate(vm, offline_candidate, OFFLINE_CANDIDATE)
    if sha != report['candidate_rpm_sha256'] or offline_sha != report['candidate_offline_rpm_sha256']:
        raise RuntimeError('Public updater candidates differ from the qualified artifacts')
    firstparty = {'candidate': {'source': CANDIDATE, 'sha256': sha, 'size': Path(candidate).stat().st_size},
                  'offline_candidate': {'source': OFFLINE_CANDIDATE, 'sha256': offline_sha,
                                        'size': Path(offline_candidate).stat().st_size}}
    identifiers = []
    # The controller outlives the staging context: its authenticated process
    # handles both root-owned and user-owned cleanup without another login.
    with PublicControl(vm, password) as control:
        with copy_dependencies(vm, candidate_dependencies, password, root_script,
                               firstparty=firstparty, cleanup=control.cleanup_staging) as staged:
            rpms = [(staged['candidate'], sha), (staged['offline_candidate'], offline_sha)]
            if candidate_dependencies:
                rpms += [(path, item['sha256']) for path, item in
                         zip(staged['dependencies'], candidate_dependencies.manifest['rpms'], strict=True)]
            transfer_source(vm, password, control)
            provision_fixture(vm, password, control, rpms, True)
            script = "python3 - <<'PY'\nimport hashlib,json,pathlib,subprocess\n"
            script += f"vendor = pathlib.Path({VENDOR!r})\nassert vendor.is_file()\n"
            script += "print(json.dumps({'boot_id': pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(), 'vendor_sha256': hashlib.sha256(vendor.read_bytes()).hexdigest(), 'packages': subprocess.check_output(['rpm','-q','--qf','%{NEVRA}\\n','cybexos-desktop','cybexos-offline-apps'],text=True)}))\nPY\n"
            before = json.loads(control(vm, script, password).stdout)
            identifier = control.start()
            identifiers.append(identifier)
            control(vm, f"printf '%s\\n' {shlex.quote(identifier)} > /home/qualification/qualification-public-run-id\n", password)
            _status, workers = wait_public(vm, password, control, identifier, interrupted=True)
            versions = inspect_version(vm, candidate=staged['candidate'], root_script=control, password=password)
            if versions['installed'] != versions['candidate']:
                raise RuntimeError('Interruption occurred before the candidate package was applied')
            control.drain_attempted = True
            stop_interrupted(vm, password, control, identifier, workers)
            control.drained = True
        # Shutdown preparation also uses the same process. The observer is
        # retained only after marked shutdown and a clean QEMU exit.
        control.poweroff()
    report['checks'].append('public-updater-interrupted-after-apply')
    # No manual recovery call occurs here: both pre-login recovery and its
    # restart must run through the installed systemd dependency.
    boot_recovered(vm, password)
    restored = verify_recovered(vm, password, root_script, identifier, before)
    verify_user_choices(vm, password, root_script, preference)
    report['checks'] += ['public-updater-pre-login-recovery',
                         'public-updater-root-package-vendor-restored',
                         'public-updater-personal-data-preserved']
    cleanup_fixture(vm, password, root_script)
    poweroff_installed(vm, password)
    boot_installed(vm, password, True)
    again = verify_recovered(vm, password, root_script, identifier, before)
    if again['rootUuid'] != restored['rootUuid']:
        raise RuntimeError('A terminal recovery exchanged the root on another boot')
    report['checks'].append('public-updater-second-boot-settled')
    copy_candidate(vm, candidate)
    copy_candidate(vm, offline_candidate, OFFLINE_CANDIDATE)
    with PublicControl(vm, password) as control:
        with copy_dependencies(vm, candidate_dependencies, password, root_script,
                               firstparty=firstparty, cleanup=control.cleanup_staging) as staged:
            rpms = [(staged['candidate'], sha), (staged['offline_candidate'], offline_sha)]
            if candidate_dependencies:
                rpms += [(path, item['sha256']) for path, item in
                         zip(staged['dependencies'], candidate_dependencies.manifest['rpms'], strict=True)]
            updater_sha = transfer_source(vm, password, control)
            provision_fixture(vm, password, control, rpms, False)
            committed = control.start()
            identifiers.append(committed)
            wait_public(vm, password, control, committed)
            # Observe the product's terminal state before the timeout fixture
            # reuses/drains provisioning, or cleanup can stop leaked workers.
            # A surviving worker must fail qualification even if teardown can
            # subsequently remove it safely.
            verify_no_workers(vm, password, control, identifiers)
            versions = inspect_version(vm, candidate=staged['candidate'], root_script=control, password=password)
            if versions['installed'] != versions['candidate']:
                raise RuntimeError('Committed public update differs from the candidate package')
            control(vm, "test \"$(rpm -q --qf '%{NEVRA}' cybexos-offline-apps)\" = "
                    f"\"$(rpm -qp --qf '%{{NEVRA}}' {shlex.quote(staged['offline_candidate'])})\"\n", password)
            installed_helper = verify_installed_updater(vm, password, control, staged['candidate'], sha,
                                                        firstparty['candidate']['size'])
            build = json.loads(control(vm, 'cat /usr/share/cybexos/build.json\n', password).stdout)
            verify_user_choices(vm, password, control, preference)
            control(vm, PROVISION_TIMEOUT, password, timeout=120)
            control.ensure_drained()
            verify_no_workers(vm, password, control, identifiers)
    # Control success grants no health credit. Close and reap it (including
    # fixture/staging cleanup) before the exact fresh ordinary SSH inspection.
    health = verify_public_health(vm, password, root_script)
    report.update({key: build[key] for key in ('source_revision', 'source_content_sha256')})
    report['public_updater'] = {'post_commit_health': health, 'interrupted': identifier,
                                'committed': committed, 'updater_sha256': updater_sha,
                                'installed_updater': installed_helper, **restored}
    report['checks'] += ['public-updater-committed',
                         'provisioning-cgroup-timeout-drains-detached-workers',
                         'public-updater-no-surviving-workers']
