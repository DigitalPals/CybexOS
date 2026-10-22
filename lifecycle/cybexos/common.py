import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import selectors
import time


class Failure(RuntimeError):
    pass


class CommandFailure(Failure):
    def __init__(self, command, returncode, output=''):
        self.returncode = returncode
        # Keep diagnostics private: callers may inspect them, but str(error)
        # and public status files must never include command output/secrets.
        self.output = output
        super().__init__(f'{Path(str(command)).name} failed (exit {returncode}). '
                         'Use cybex update log with the deployment ID for private diagnostics.')


def parse(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Failure('Duplicate metadata field')
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=unique)
    except (ValueError, UnicodeError) as error:
        raise Failure('Invalid JSON document') from error


def read(path, default=None):
    try:
        return parse(Path(path).read_bytes())
    except FileNotFoundError:
        return default


def syncdir(path):
    fd = os.open(path, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic(path, value, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.publish-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(value if isinstance(value, bytes) else (json.dumps(value, sort_keys=True, indent=2) + '\n').encode())
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        syncdir(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def link(target, path):
    path = Path(path)
    temporary = path.with_name(path.name + '.new')
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    os.replace(temporary, path)
    syncdir(path.parent)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


@contextlib.contextmanager
def locked(path, *, skip_busy=False):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            if skip_busy:
                yield False
                return
            raise Failure('Another CybexOS operation is running. Check cybex update status.') from error
        yield True


class Runner:
    def __init__(self, log=None):
        self.log = log

    def __call__(self, *args, cwd=None, capture=True, timeout=7200, input=None, sensitive=False):
        # A fixed system PATH is supplied by the package wrapper; callers never
        # pass shell text or include credentials in argv.
        with subprocess.Popen(list(map(str, args)), cwd=cwd, stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            if input is not None:
                process.stdin.write(input)
                process.stdin.close()
            output = bytearray()
            diagnostics = bytearray()
            started = time.monotonic()
            with contextlib.ExitStack() as stack:
                log = stack.enter_context(Path(self.log).open('ab')) if self.log and not sensitive else None
                selector = stack.enter_context(selectors.DefaultSelector())
                selector.register(process.stdout, selectors.EVENT_READ, True)
                selector.register(process.stderr, selectors.EVENT_READ, False)
                try:
                    while selector.get_map():
                        if time.monotonic() - started > timeout:
                            raise Failure(f'{Path(str(args[0])).name} timed out; inspect the transaction log and retry.')
                        for key, _ in selector.select(timeout=1):
                            data = os.read(key.fd, 65536)
                            if not data:
                                selector.unregister(key.fileobj)
                                continue
                            if key.data:
                                output.extend(data)
                            diagnostics.extend(data)
                            if log:
                                log.write(data)
                                log.flush()
                    code = process.wait(timeout=10)
                except BaseException:
                    process.kill()
                    process.wait()
                    raise
            if code:
                raise CommandFailure(args[0], code, diagnostics.decode(errors='replace'))
            return output.decode()
