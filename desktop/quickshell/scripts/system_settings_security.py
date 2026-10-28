"""Settings > Security: fingerprint readers (fprintd) and security keys (pam_u2f).

No secret crosses this API. fprintd keeps prints in its own root-only store,
and a security-key registration is an opaque key handle and a public key.
Enrolment goes through fprintd's own Polkit checks. Authentication policy is
declared in personal NixOS modules and applied through the staged lifecycle.

`python3 system_settings_security.py enroll FINGER` streams one enrolment as
JSON lines from fprintd's EnrollStatus signal; SIGTERM cancels it.
"""
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile

FPRINT = 'net.reactivated.Fprint'
MANAGER_PATH = '/net/reactivated/Fprint/Manager'
MANAGER = FPRINT + '.Manager'
DEVICE = FPRINT + '.Device'
# fprintd's finger names, in the order Settings suggests them for a new print.
FINGERS = ('right-index-finger', 'left-index-finger', 'right-thumb', 'left-thumb',
           'right-middle-finger', 'left-middle-finger', 'right-ring-finger',
           'left-ring-finger', 'right-little-finger', 'left-little-finger')
# Must match nix/modules/security.nix: credentials registered for
# another relying party never verify with the Cybex OS PAM steps.
ORIGIN = 'pam://cybexos'
FINGERPRINT_POLICY = Path('/etc/cybexos/fingerprint-enabled')
PAM_FILES = (Path('/etc/pam.d/sudo'), Path('/etc/pam.d/polkit-1'), Path('/etc/pam.d/cybexos-lock'))
# KeyHandle,UserKey,CoseType,Options as pamu2fcfg writes them; '*' is the key
# handle of a resident credential.
CREDENTIAL = re.compile(r'^(?:\*|[A-Za-z0-9+/=_-]{8,1024}),[A-Za-z0-9+/=_-]{8,1024},[a-z0-9]{2,16},[+a-z]{0,64}$')


class FprintError(Exception):
    """A D-Bus error from fprintd, identified by its error name."""

    def __init__(self, name, message=''):
        super().__init__(message or name)
        self.name = name


class Fprintd:
    """fprintd's system D-Bus API. Tests pass an object with the same methods."""

    def __init__(self):
        import gi
        gi.require_version('Gio', '2.0')
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def call(self, path, interface, method, signature=None, values=(), interactive=False, timeout=5000):
        flags = (self.Gio.DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION if interactive
                 else self.Gio.DBusCallFlags.NONE)
        arguments = self.GLib.Variant(signature, values) if signature else None
        try:
            return self.bus.call_sync(FPRINT, path, interface, method, arguments, None, flags,
                                      timeout, None).unpack()
        except self.GLib.Error as error:
            raise FprintError(self.Gio.DBusError.get_remote_error(error) or 'unknown') from None

    def devices(self):
        return list(self.call(MANAGER_PATH, MANAGER, 'GetDevices')[0])

    def properties(self, path):
        return self.call(path, 'org.freedesktop.DBus.Properties', 'GetAll', '(s)', (DEVICE,))[0]

    def fingers(self, path, user):
        try:
            return list(self.call(path, DEVICE, 'ListEnrolledFingers', '(s)', (user,))[0])
        except FprintError as error:
            if error.name.endswith('.NoEnrolledPrints'):
                return []
            raise

    def claim(self, path):
        self.call(path, DEVICE, 'Claim', '(s)', ('',), interactive=True, timeout=60000)

    def release(self, path):
        self.call(path, DEVICE, 'Release')

    def delete(self, path, finger):
        # fprintd's enrol action is auth_self_keep: the shell's Polkit dialog asks.
        self.call(path, DEVICE, 'DeleteEnrolledFinger', '(s)', (finger,), interactive=True, timeout=60000)

    def enroll_start(self, path, finger):
        self.call(path, DEVICE, 'EnrollStart', '(s)', (finger,), interactive=True, timeout=120000)

    def enroll_stop(self, path):
        self.call(path, DEVICE, 'EnrollStop')

    def subscribe(self, path, callback):
        def deliver(_bus, _sender, _path, _interface, _signal, parameters):
            result, done = parameters.unpack()
            callback(result, done)
        return self.bus.signal_subscribe(FPRINT, DEVICE, 'EnrollStatus', path, None,
                                         self.Gio.DBusSignalFlags.NONE, deliver)


def fprint_message(error):
    name = error.name.rsplit('.', 1)[-1]
    if name in ('PermissionDenied', 'AuthFailed', 'NotAuthorized'):
        return 'Authorization was cancelled or denied. Retry and approve the system prompt.'
    if name in ('AlreadyInUse', 'ClaimDevice'):
        return 'The fingerprint reader is busy. Try again in a moment.'
    if name == 'FingerAlreadyEnrolled':
        return 'That finger is already enrolled.'
    if name in ('NoSuchDevice', 'ServiceUnknown', 'NameHasNoOwner'):
        return 'The fingerprint reader is no longer available.'
    return 'The fingerprint service did not finish. Refresh and try again.'


def run(argv, timeout):
    """Run a fixed command with no input: nothing can wait on a prompt."""
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False,
                                stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return 124, '', 'timeout'
    except OSError as error:
        return 127, '', str(error)
    return result.returncode, result.stdout, result.stderr


def credential_id(credential):
    return hashlib.sha256(credential.encode()).hexdigest()[:12]


def parse_mapping(text, user):
    """The account's credentials, and every other line kept verbatim."""
    credentials, others = [], []
    for line in text.splitlines():
        if line.startswith(user + ':'):
            credentials.extend(part for part in line[len(user) + 1:].split(':') if part)
        elif line.strip():
            others.append(line)
    return credentials, others


def render_mapping(user, credentials, others):
    lines = list(others) + ([user + ':' + ':'.join(credentials)] if credentials else [])
    return ''.join(line + '\n' for line in lines)


class SecuritySettings:
    def __init__(self, fprintd=None, account=None, runner=run, nixos_policy=FINGERPRINT_POLICY,
                 pam_files=PAM_FILES, which=shutil.which):
        self._fprintd = fprintd
        account = account or pwd.getpwuid(os.getuid())
        self.user, self.home = account.pw_name, Path(account.pw_dir)
        self.run = runner
        self.nixos_policy = Path(nixos_policy)
        self.pam_files = tuple(Path(path) for path in pam_files)
        self.which = which

    @property
    def fprintd(self):
        if self._fprintd is None:
            self._fprintd = Fprintd()
        return self._fprintd

    @property
    def mapping(self):
        return self.home / '.config/Yubico/u2f_keys'

    # ── fingerprints ────────────────────────────────────────────────────
    def reader(self):
        """The first fprintd device, or why there is none."""
        try:
            devices = self.fprintd.devices()
        except Exception:  # fprintd absent, no system bus, or no PyGObject.
            return {'state': 'unavailable'}, None
        if not devices:
            return {'state': 'none'}, None
        path = devices[0]
        try:
            props = self.fprintd.properties(path)
        except FprintError:
            return {'state': 'unavailable'}, None
        return {'state': 'ready', 'name': str(props.get('name', '')),
                'scanType': 'swipe' if props.get('scan-type') == 'swipe' else 'press',
                'stages': int(props.get('num-enroll-stages', 0) or 0)}, path

    def features(self):
        try:
            enabled = self.nixos_policy.read_text().strip() == 'enabled'
        except FileNotFoundError:
            enabled = False
        return ['with-fingerprint'] if enabled else []

    def fingerprint_snapshot(self):
        reader, path = self.reader()
        fingers = []
        if path:
            try:
                fingers = [finger for finger in self.fprintd.fingers(path, self.user) if finger in FINGERS]
            except FprintError:
                reader = {'state': 'unavailable'}
        free = [finger for finger in FINGERS if finger not in fingers]
        features = self.features()
        return {'reader': reader, 'fingers': fingers, 'freeFingers': free,
                'fingerprintAuth': bool(features) and 'with-fingerprint' in features,
                'fingerprintManaged': features is not None}

    def ready_reader(self):
        reader, path = self.reader()
        if not path:
            raise ValueError('No fingerprint reader is available.')
        return path

    def delete_finger(self, request):
        finger = request.get('finger')
        if finger not in FINGERS:
            raise ValueError('Choose an enrolled fingerprint')
        if request.get('confirmed') is not True:
            raise ValueError('Confirm removal of this fingerprint')
        path = self.ready_reader()
        try:
            if finger not in self.fprintd.fingers(path, self.user):
                raise ValueError('That fingerprint is no longer enrolled. Refresh the page.')
            self.fprintd.claim(path)
            try:
                self.fprintd.delete(path, finger)
            finally:
                try:
                    self.fprintd.release(path)
                except FprintError:
                    pass
        except FprintError as error:
            raise ValueError(fprint_message(error)) from None
        return {'message': 'Fingerprint removed'}

    def set_fingerprint_auth(self, request):
        enabled = request.get('enabled')
        if not isinstance(enabled, bool):
            raise ValueError('Invalid fingerprint setting')
        raise ValueError('Set cybexos.authentication.fingerprint in /etc/nixos/local, then preview and apply with cybex update stage local. Enrolment remains available here.')

    # ── security keys ───────────────────────────────────────────────────
    def key_state(self, features):
        if not self.which('pamu2fcfg'):
            return 'missing'
        for path in self.pam_files:
            try:
                if 'origin=' + ORIGIN in path.read_text():
                    return 'ready'
            except OSError:
                continue
        return 'inactive'

    def credentials(self):
        try:
            if self.mapping.is_symlink():
                return [], []
            text = self.mapping.read_text()
        except FileNotFoundError:
            return [], []
        except (OSError, UnicodeDecodeError):
            raise ValueError('Your security key list could not be read. Check ~/.config/Yubico/u2f_keys.') from None
        return parse_mapping(text, self.user)

    def key_snapshot(self):
        state = self.key_state(self.features())
        try:
            credentials, _ = self.credentials()
            error = ''
        except ValueError as problem:
            credentials, error = [], str(problem)
        return {'keys': {'state': state, 'error': error, 'entries': [
            {'id': credential_id(credential), 'label': f'Security key {index}'}
            for index, credential in enumerate(credentials, 1)]}}

    def save(self, credentials, others):
        directory = self.mapping.parent
        for path in (directory, self.mapping):
            if path.is_symlink():
                raise ValueError('~/.config/Yubico is a link. Replace it with a folder, then try again.')
        if not directory.is_dir():
            directory.mkdir(parents=True, mode=0o700)
            os.chmod(directory, 0o700)
        text = render_mapping(self.user, credentials, others)
        if not text:
            self.mapping.unlink(missing_ok=True)
            return
        descriptor, temporary = tempfile.mkstemp(prefix='.u2f_keys-', dir=directory)
        try:
            with os.fdopen(descriptor, 'w') as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(text)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.mapping)
        finally:
            Path(temporary).unlink(missing_ok=True)

    def add_key(self):
        state = self.key_state(self.features())
        if state != 'ready':
            raise ValueError('Security keys are not available on this computer.')
        executable = self.which('pamu2fcfg')
        code, output, error = self.run([executable, '-n', '-o', ORIGIN, '-i', ORIGIN], 50)
        if code != 0:
            text = error.lower()
            if code == 124:
                raise ValueError('The key was not touched in time. Try again.')
            if 'pin' in text:
                raise ValueError('This key asks for its PIN. Register it in a terminal instead; see the security guide.')
            if 'no fido authenticator' in text or 'unable to discover' in text:
                raise ValueError('Insert a security key, then try again.')
            raise ValueError('The key was not registered. Touch it when it flashes, then try again.')
        credential = output.strip()
        credential = credential[1:] if credential.startswith(':') else credential.split(':', 1)[-1]
        if not CREDENTIAL.match(credential):
            raise ValueError('The key returned a registration Cybex OS does not recognise.')
        credentials, others = self.credentials()
        if credential not in credentials:
            credentials.append(credential)
        self.save(credentials, others)
        return {'message': 'Security key added'}

    def remove_key(self, request):
        if request.get('confirmed') is not True:
            raise ValueError('Confirm removal of this security key')
        credentials, others = self.credentials()
        remaining = [credential for credential in credentials if credential_id(credential) != request.get('id')]
        if len(remaining) == len(credentials):
            raise ValueError('That security key is no longer registered. Refresh the page.')
        self.save(remaining, others)
        return {'message': 'Security key removed'}

    def dispatch(self, request):
        action = request.get('action', 'snapshot')
        if action == 'snapshot':
            return {**self.fingerprint_snapshot(), **self.key_snapshot()}
        if action == 'delete-finger':
            return self.delete_finger(request)
        if action == 'fingerprint-auth':
            return self.set_fingerprint_auth(request)
        if action == 'add-key':
            return self.add_key()
        if action == 'remove-key':
            return self.remove_key(request)
        raise ValueError('Unknown security operation')


class Enrolment:
    """One fprintd enrolment, reported as events through `emit`.

    Owns the claim from start until finish, whatever ends it: completion, a
    failure, cancellation, or the idle limit.
    """

    def __init__(self, fprintd, path, finger, emit, stop_loop=lambda: None, activity=lambda: None):
        self.fprintd, self.path, self.finger = fprintd, path, finger
        self.emit, self.stop_loop, self.activity = emit, stop_loop, activity
        self.claimed = self.enrolling = self.finished = False
        self.stage = 0
        self.stages = 0
        self.code = 1

    def start(self):
        props = self.fprintd.properties(self.path)
        self.stages = int(props.get('num-enroll-stages', 0) or 0)
        self.fprintd.subscribe(self.path, self.status)
        self.fprintd.claim(self.path)
        self.claimed = True
        self.fprintd.enroll_start(self.path, self.finger)
        self.enrolling = True
        self.emit({'event': 'started', 'finger': self.finger, 'stages': self.stages,
                   'scanType': 'swipe' if props.get('scan-type') == 'swipe' else 'press'})

    def status(self, result, done):
        if self.finished:
            return
        self.activity()
        if result == 'enroll-stage-passed':
            self.stage += 1
        if done:
            # fprintd still expects EnrollStop after a finished enrolment.
            completed = result == 'enroll-completed'
            self.finish({'event': 'completed', 'finger': self.finger} if completed
                        else {'event': 'failed', 'result': result}, 0 if completed else 1)
        else:
            self.emit({'event': 'progress', 'result': result, 'stage': self.stage, 'stages': self.stages})

    def finish(self, event, code):
        if self.finished:
            return
        self.finished = True
        self.code = code
        for step, needed in ((self.fprintd.enroll_stop, self.enrolling), (self.fprintd.release, self.claimed)):
            if needed:
                try:
                    step(self.path)
                except FprintError:
                    pass
        self.enrolling = self.claimed = False
        self.emit(event)
        self.stop_loop()

    def cancel(self):
        self.finish({'event': 'cancelled'}, 130)

    def expire(self):
        self.finish({'event': 'failed', 'result': 'enroll-timeout'}, 1)


def emit_json(event):
    print(json.dumps(event), flush=True)


def enroll_main(argv, fprintd_factory=Fprintd, emit=emit_json):
    if len(argv) != 2 or argv[0] != 'enroll' or argv[1] not in FINGERS:
        emit({'event': 'failed', 'result': 'invalid-request'})
        return 2
    try:
        fprintd = fprintd_factory()
        devices = fprintd.devices()
    except Exception:
        emit({'event': 'failed', 'result': 'unavailable', 'message': 'The fingerprint service is not available.'})
        return 1
    if not devices:
        emit({'event': 'failed', 'result': 'unavailable', 'message': 'No fingerprint reader is available.'})
        return 1
    import gi
    from gi.repository import GLib
    try:
        # GLib 2.80 moved Unix signal sources to GLibUnix.
        gi.require_version('GLibUnix', '2.0')
        from gi.repository import GLibUnix
        signal_add = GLibUnix.signal_add_full
    except (ImportError, ValueError):
        signal_add = GLib.unix_signal_add
    loop = GLib.MainLoop()
    idle = []

    def touch():
        # A reader nobody touches would otherwise stay claimed indefinitely.
        if idle:
            GLib.source_remove(idle.pop())
        idle.append(GLib.timeout_add_seconds(90, lambda: (enrolment.expire(), False)[1]))

    enrolment = Enrolment(fprintd, devices[0], argv[1], emit, loop.quit, touch)
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal_add(GLib.PRIORITY_HIGH, number, lambda: (enrolment.cancel(), False)[1])
    try:
        enrolment.start()
    except FprintError as error:
        enrolment.finish({'event': 'failed', 'result': 'error', 'message': fprint_message(error)}, 1)
        return enrolment.code
    touch()
    if not enrolment.finished:
        loop.run()
    return enrolment.code


if __name__ == '__main__':
    sys.exit(enroll_main(sys.argv[1:]))
