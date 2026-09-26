"""Start one verified, ephemeral PXE runner for one already queued release job.

The operator's gh credentials remain outside the runner environment. This is
not a sandbox: only reviewed workflow code may execute as the PXE operator.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import shutil
import subprocess
import tarfile
import tempfile
import sys
from urllib.parse import urlsplit
from urllib.request import urlopen
import uuid

REPOSITORY = 'DigitalPals/CybexOS'
ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = {'.github/workflows/release.yml', '.github/workflows/desktop-release.yml'}
ARCHIVE_LIMIT = 1024 ** 3


def api(endpoint, *, method='GET', body=None, paginate=False):
    command = ['gh', 'api', '--hostname', 'github.com', '--method', method, '-H', 'Accept: application/vnd.github+json',
               '-H', 'X-GitHub-Api-Version: 2022-11-28', endpoint]
    if paginate:
        command += ['--paginate', '--slurp']
    if body is not None:
        command += ['--input', '-']
    result = subprocess.run(command, input=json.dumps(body) if body is not None else None,
                            capture_output=True, text=True, timeout=60, check=False)
    if result.returncode:
        if method == 'DELETE' and '(HTTP 404)' in result.stderr:
            return None  # Ephemeral registration already removed itself.
        # API payloads can contain registration credentials; never echo them.
        raise RuntimeError(f'GitHub API {method} {endpoint} failed; check gh authentication and repository administration access')
    return json.loads(result.stdout) if result.stdout.strip() else None


def pages(endpoint, field):
    return [item for page in api(endpoint, paginate=True) for item in page[field]]


def validate_run(run, head):
    if (run.get('repository', {}).get('full_name') != REPOSITORY
            or run.get('head_repository', {}).get('full_name') != REPOSITORY
            or run.get('event') not in ('push', 'workflow_dispatch')
            or run.get('path') not in WORKFLOWS
            or run.get('head_sha') != head
            or run.get('pull_requests')
            or run.get('status') not in ('queued', 'in_progress', 'waiting', 'requested')):
        raise ValueError('Run must be an unfinished, non-PR release workflow from this exact reviewed checkout')
    branch = run.get('head_branch', '')
    if branch != 'main' and not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', branch):
        raise ValueError('Release runners accept only main or a versioned release tag')
    return run


def validate_job(jobs, run_id, head):
    label = f'cybexos-iso-{run_id}'
    matching = [job for job in jobs if label in job.get('labels', [])
                and job.get('status') in ('queued', 'in_progress', 'waiting', 'pending')]
    if len(matching) != 1:
        raise ValueError('Exactly one queued qualification job with this run-specific label is required')
    job = matching[0]
    if (job.get('status') != 'queued' or job.get('run_id') != run_id
            or job.get('head_sha') != head or job.get('labels') != [label]):
        raise ValueError('The qualification job must be queued and request only its exact run-specific label')
    return job


def checkout_head(checkout=ROOT):
    def git(*args):
        return subprocess.run(['git', '-C', str(checkout), *args], check=True,
                              capture_output=True, text=True, timeout=15).stdout.strip()
    if git('status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Use a clean, reviewed checkout matching the queued workflow head')
    remote = git('remote', 'get-url', 'origin')
    if remote not in (f'https://github.com/{REPOSITORY}', f'https://github.com/{REPOSITORY}.git',
                      f'git@github.com:{REPOSITORY}.git', f'ssh://git@github.com/{REPOSITORY}.git'):
        raise ValueError('Checkout origin must be the official CybexOS repository')
    head = git('rev-parse', 'HEAD')
    if not re.fullmatch(r'[0-9a-f]{40,64}', head):
        raise ValueError('Checkout commit identity is invalid')
    return head


def reviewed_job(run_id, head, own_runner=None):
    run = validate_run(api(f'repos/{REPOSITORY}/actions/runs/{run_id}'), head)
    job = validate_job(pages(f'repos/{REPOSITORY}/actions/runs/{run_id}/jobs?filter=latest&per_page=100', 'jobs'), run_id, head)
    label = f'cybexos-iso-{run_id}'
    # A unique-only label avoids the generic self-hosted pool. Refuse a second
    # runner for this run, or another pending job explicitly targeting it.
    runners = pages(f'repos/{REPOSITORY}/actions/runners?per_page=100', 'runners')
    if any(runner.get('id') != own_runner and label in [item.get('name') for item in runner.get('labels', [])]
           for runner in runners):
        raise ValueError('A runner already exists for this workflow run')
    for state in ('queued', 'in_progress', 'waiting', 'pending', 'requested'):
        for other in pages(f'repos/{REPOSITORY}/actions/runs?status={state}&per_page=100', 'workflow_runs'):
            if other['id'] == run_id:
                continue
            others = pages(f'repos/{REPOSITORY}/actions/runs/{other["id"]}/jobs?filter=latest&per_page=100', 'jobs')
            if any(label in item.get('labels', []) and item.get('status') != 'completed' for item in others):
                raise ValueError('Another unfinished workflow requests the same release-runner label')
    return run, job


def runner_package(releases):
    found = [item for item in releases if item.get('os') == 'linux' and item.get('architecture') == 'x64']
    if len(found) != 1:
        raise ValueError('GitHub must provide exactly one current Linux x64 runner package')
    package = found[0]
    checksum = package.get('sha256_checksum', '')
    url = urlsplit(package.get('download_url', ''))
    if (not re.fullmatch(r'[0-9a-fA-F]{64}', checksum) or url.scheme != 'https'
            or url.netloc != 'github.com' or url.query or url.fragment
            or not re.fullmatch(r'/actions/runner/releases/download/v[0-9.]+/actions-runner-linux-x64-[0-9.]+\.tar\.gz', url.path)):
        raise ValueError('Runner download must have the GitHub API SHA-256 pin and official release URL')
    return package['download_url'], checksum.lower()


def download(url, checksum, destination):
    digest, size = hashlib.sha256(), 0
    with urlopen(url, timeout=60) as response, destination.open('xb') as stream:
        if urlsplit(response.url).scheme != 'https':
            raise ValueError('Runner download redirected to an insecure URL')
        while block := response.read(8 * 1024 * 1024):
            size += len(block)
            if size > ARCHIVE_LIMIT:
                raise ValueError('Runner archive exceeds the size limit')
            digest.update(block)
            stream.write(block)
    if digest.hexdigest() != checksum:
        raise ValueError('Runner download SHA-256 does not match the GitHub API pin')


def extract(archive, destination):
    # Python 3.12+ data filtering rejects escaping paths, device files and
    # escaping symlinks. Only checksum-verified official runner bytes reach it.
    with tarfile.open(archive, 'r:gz') as bundle:
        bundle.extractall(destination, filter='data')
    for name in ('config.sh', 'run.sh'):
        path = destination / name
        if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError('Official runner archive is missing its executable entry points')


def child_environment(work):
    home, temporary = work / 'home', work / 'tmp'
    home.mkdir(mode=0o700)
    temporary.mkdir(mode=0o700)
    return {'PATH': os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin'),
            'HOME': str(home), 'TMPDIR': str(temporary), 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8',
            'PYTHONDONTWRITEBYTECODE': '1'}


def stop(process):
    if process.poll() is not None:
        return
    for signum, deadline in ((signal.SIGINT, 30), (signal.SIGTERM, 15), (signal.SIGKILL, 10)):
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            break
        try:
            process.wait(timeout=deadline)
            return
        except subprocess.TimeoutExpired:
            continue
    process.wait(timeout=10)


def run_child(command, work, environment, timeout, *, capture=False):
    with subprocess.Popen(command, cwd=work, env=environment, start_new_session=True,
                          stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None) as process:
        try:
            process.communicate(timeout=timeout)
        except BaseException:
            stop(process)
            raise
        if process.returncode:
            raise RuntimeError('Ephemeral runner command failed; local credentials and logs will be removed')


class ActiveRunnerError(RuntimeError):
    """A transient unit could not be proven stopped; retain its task files."""


def manager_environment():
    runtime = f'/run/user/{os.getuid()}'
    return {'PATH': os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin'),
            'XDG_RUNTIME_DIR': runtime, 'DBUS_SESSION_BUS_ADDRESS': 'unix:path=' + runtime + '/bus',
            'LANG': 'C.UTF-8'}


def check_user_manager():
    result = subprocess.run(['systemctl', '--user', 'show', '--property=Version', '--value'],
                            env=manager_environment(), capture_output=True, timeout=15, check=False)
    if result.returncode:
        raise ValueError('A reachable operator systemd user manager is required for bounded runner/VM cleanup')


def run_scoped_runner(work, environment, timeout, name):
    """A transient cgroup contains build VMs even when helpers call setsid()."""
    unit = name + '.service'
    manager = manager_environment()
    command = ['systemd-run', '--user', '--quiet', '--wait', '--pipe', '--collect',
               '--service-type=exec', '--unit=' + unit, '--working-directory=' + str(work),
               '--property=RuntimeMaxSec=' + str(timeout) + 's', '--property=KillSignal=SIGINT',
               '--property=TimeoutStopSec=120s', '--property=KillMode=mixed',
               '--property=SendSIGKILL=yes', '/usr/bin/env', '-i',
               *(key + '=' + value for key, value in sorted(environment.items())), str(work / 'run.sh')]
    try:
        # Give systemd time to complete graceful cancellation at RuntimeMaxSec.
        run_child(command, work, manager, timeout + 135)
    finally:
        try:
            subprocess.run(['systemctl', '--user', 'stop', unit], env=manager,
                           capture_output=True, timeout=135, check=False)
            result = subprocess.run(['systemctl', '--user', 'show', unit, '--property=ActiveState', '--value'],
                                    env=manager, capture_output=True, text=True, timeout=15, check=False)
            if not ((result.returncode == 0 and result.stdout.strip() in ('inactive', 'failed'))
                    or (result.returncode == 4 and not result.stdout.strip())):
                raise ActiveRunnerError(f'Could not confirm {unit} stopped; inspect that exact user unit before removing {work}')
        except (OSError, subprocess.SubprocessError) as error:
            raise ActiveRunnerError(f'Could not stop {unit}; inspect that exact user unit before removing {work}') from error


def owned_runner(name):
    found = [runner for runner in pages(f'repos/{REPOSITORY}/actions/runners?per_page=100', 'runners')
             if runner.get('name') == name]
    if len(found) > 1:
        raise RuntimeError('Ambiguous ephemeral runner registration; refuse to delete another runner')
    return found[0]['id'] if found else None


def cleanup_registration(name):
    # Ephemeral runners normally deregister themselves. Exact unique names also
    # recover a partially completed config.sh registration without deleting peers.
    identifier = owned_runner(name)
    if identifier is not None:
        api(f'repos/{REPOSITORY}/actions/runners/{identifier}', method='DELETE')


def execute(run_id, head, work_root, timeout):
    check_user_manager()
    reviewed_job(run_id, head)
    url, checksum = runner_package(api(f'repos/{REPOSITORY}/actions/runners/downloads'))
    name = f'cybexos-iso-{run_id}-{uuid.uuid4().hex[:12]}'
    attempted = False
    work = Path(tempfile.mkdtemp(prefix=f'cybexos-runner-{run_id}-', dir=work_root))
    retain = False
    try:
        download(url, checksum, work / 'runner.tar.gz')
        extract(work / 'runner.tar.gz', work)
        work.chmod(0o700)
        (work / 'runner.tar.gz').unlink()
        environment = child_environment(work)
        # Recheck after a potentially slow download, immediately before enrolling.
        reviewed_job(run_id, head)
        registration = api(f'repos/{REPOSITORY}/actions/runners/registration-token', method='POST')
        token = registration.get('token') if isinstance(registration, dict) else None
        if not isinstance(token, str) or not token:
            raise ValueError('GitHub did not return a registration token')
        try:
            attempted = True
            # Runner CommandSettings accepts ACTIONS_RUNNER_INPUT_* and removes
            # it from the environment after reading. Never put tokens in argv.
            run_child([str(work / 'config.sh'), '--unattended', '--url', f'https://github.com/{REPOSITORY}',
                       '--name', name, '--ephemeral', '--disableupdate', '--no-default-labels',
                       '--labels', f'cybexos-iso-{run_id}', '--work', '_work'],
                      work, {**environment, 'ACTIONS_RUNNER_INPUT_TOKEN': token}, 120, capture=True)
            token = None
            registration = None
            identifier = owned_runner(name)
            if identifier is None:
                raise RuntimeError('Runner registration was not visible in the repository')
            _run, expected_job = reviewed_job(run_id, head, own_runner=identifier)
            print(f'Starting ephemeral runner {name} for reviewed run {run_id}; automatic stop after {timeout} seconds.', flush=True)
            try:
                run_scoped_runner(work, environment, timeout, name)
            except ActiveRunnerError:
                retain = True
                raise
            completed = api(f'repos/{REPOSITORY}/actions/jobs/{expected_job["id"]}')
            if (completed.get('run_id') != run_id or completed.get('runner_id') != identifier
                    or completed.get('head_sha') != head or completed.get('status') != 'completed'):
                raise RuntimeError('Runner did not complete the reviewed job; inspect the workflow before retrying')
            if completed.get('conclusion') != 'success':
                raise RuntimeError('The reviewed qualification job failed; inspect its retained qualification reports')
            print('Ephemeral runner stopped; removing its registration and task directory.', flush=True)
        finally:
            if attempted:
                try:
                    cleanup_registration(name)
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                    raise RuntimeError(f'Registration cleanup failed for {name}; inspect repository Actions runners and the reported transient unit before removing that exact registration') from error

    finally:
        if retain:
            print(f'Retained task staging {work}: runner unit stop could not be confirmed.', file=sys.stderr)
        else:
            shutil.rmtree(work)


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', type=int, required=True, help='Already queued reviewed release workflow run')
    parser.add_argument('--execute', action='store_true', help='Register and run one ephemeral runner; otherwise validate only')
    parser.add_argument('--work-root', type=Path, default=Path('/data/cybexos-runners'))
    parser.add_argument('--timeout', type=int, default=7 * 60 * 60, help='Maximum runner lifetime in seconds (default: 7 hours)')
    args = parser.parse_args()
    if args.run_id <= 0 or not 60 <= args.timeout <= 8 * 60 * 60:
        parser.error('Use a positive run ID and a timeout between 60 seconds and 8 hours')
    try:
        head = checkout_head()
        run, job = reviewed_job(args.run_id, head)
        print(f'Reviewed {run["path"]} at {head}; queued job {job["id"]}; label cybexos-iso-{args.run_id}.')
        if not args.execute:
            print('Validation only. --execute registers an ephemeral runner and starts the reviewed job.')
            return 0
        if platform.system() != 'Linux' or platform.machine() != 'x86_64' or os.geteuid() == 0:
            raise ValueError('Run as the unprivileged PXE operator on Linux x86_64')
        if not Path('/data/pxe/README.md').is_file():
            raise ValueError('Execute on the documented PXE host with /data/pxe/README.md')
        work_root = args.work_root.resolve()
        if work_root == ROOT or work_root.is_relative_to(ROOT) or work_root.is_relative_to(Path('/data/pxe/iso')):
            raise ValueError('Runner staging must be outside the checkout and served ISO tree')
        work_root.mkdir(parents=True, exist_ok=True)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, interrupted)
        execute(args.run_id, head, work_root, args.timeout)
        return 0
    except KeyboardInterrupt:
        print('Ephemeral runner interrupted; cleanup completed or was reported above.', file=sys.stderr)
        return 130
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, tarfile.TarError) as error:
        parser.exit(1, f'release-runner: {error}\n')


if __name__ == '__main__':
    raise SystemExit(main())
