"""Serialized staged NixOS deployments with durable recovery boundaries."""
import hashlib
import configparser
import os
from pathlib import Path
import re
import shutil
from subprocess import TimeoutExpired
import time
import uuid
from urllib.parse import urlencode

from .common import CommandFailure, Failure, Runner, atomic, link, locked, parse, read, syncdir
from . import inputs
from .trust import Fetcher, NoPublishedRelease, discover, version
from . import review

SCOPES = ('upstream', 'cybexos', 'both', 'local')
BUSY = ('discovering', 'building', 'validating', 'activating', 'recovering')
UPSTREAM_METADATA = ('nix', 'flake', 'metadata', '--refresh', '--json',
                     'github:NixOS/nixpkgs/nixos-26.05')
UPSTREAM_LOOKUP_FAILED = 'Nix metadata lookup failed. Check network access and Nix configuration.'
UPSTREAM_LOOKUP_TIMEOUT = 'Nix metadata lookup timed out. Check network access and retry when connected.'


def upstream_discovery_error(output):
    """Classify private command output into static, public-safe guidance."""
    output = output.lower()
    statuses = {int(code) for code in re.findall(
        r'\b(?:http(?:/\d(?:\.\d)?)?(?:\s+(?:error|status(?:\s+code)?))?|status code)\s*[:=]?\s*([45]\d{2})\b', output)}
    github_api = re.search(r'https://api\.github\.com(?:/|\s|[\'\"]|$)', output)
    if github_api and any(text in output for text in (
            'api rate limit exceeded', 'you have exceeded a secondary rate limit')):
        return 'GitHub API rate limit reached. Retry later; no account or token is required.'
    if 429 in statuses:
        return 'The package-source endpoint rate limited the request (HTTP 429). Retry later.'
    if 403 in statuses:
        return 'The package-source endpoint denied access (HTTP 403). Check network access policy and Nix configuration.'
    if any(500 <= code <= 599 for code in statuses):
        return 'The package-source endpoint reported a server error (HTTP 5xx). Retry later.'
    if any(text in output for text in (
            'could not resolve host', "couldn't resolve host", 'could not resolve proxy',
            "couldn't resolve proxy", 'temporary failure in name resolution', 'name or service not known')):
        return 'Package-source hostname resolution failed. Check DNS and network access.'
    if any(text in output for text in (
            'ssl certificate problem', 'ssl peer certificate', 'certificate verify failed',
            'tls handshake', 'ssl connect error')):
        return 'The package-source TLS connection failed. Check the system clock, certificates and network access.'
    if any(text in output for text in ('timed out', 'timeout was reached', 'connection timeout')):
        return UPSTREAM_LOOKUP_TIMEOUT
    if any(text in output for text in (
            'could not connect', "couldn't connect", 'failed to connect', 'connection refused',
            'network is unreachable', 'no route to host', 'connection reset by peer')):
        return 'The package-source connection failed. Check network access and retry when connected.'
    return UPSTREAM_LOOKUP_FAILED


def configuration_paths(source):
    # Repository bookkeeping is not part of the selected Nix configuration.
    # Copying and review identities must apply precisely the same exclusion.
    source = Path(source)
    return (path for path in source.rglob('*') if '.git' not in path.relative_to(source).parts)


def copy_config(source, target):
    source = Path(source).resolve()
    files = list(configuration_paths(source))
    for path in files:
        if path.is_symlink() or (not path.is_file() and not path.is_dir()):
            raise Failure('Configuration contains a link or special file. Use runtime secret paths and plain local modules.')
        if path.is_file():
            if path.stat().st_size > 8 * 1024 * 1024:
                raise Failure('Configuration contains a large state file. Keep state and secrets outside the flake.')
            if b'PRIVATE KEY-----' in path.read_bytes():
                raise Failure('Private key found in configuration. Move it to /var/lib/cybexos/secrets before staging.')
    shutil.copytree(source, target, ignore=shutil.ignore_patterns('.git'))
    for path in [target, *Path(target).rglob('*')]:
        # NAR identities distinguish executable files. Personal package/service
        # sources must keep that behavior when their staged tree is selected.
        executable = path.is_file() and bool(path.stat().st_mode & 0o111)
        path.chmod(0o755 if path.is_dir() or executable else 0o644)
        if path.is_file():
            with path.open('rb') as stream:
                os.fsync(stream.fileno())
    syncdir(target)


def config_digest(path):
    h = hashlib.sha256()
    for p in sorted(configuration_paths(path)):
        if p.is_symlink() or (not p.is_file() and not p.is_dir()):
            raise Failure('Configuration contains a link or special file. Use runtime secret paths and plain local modules.')
        relative = str(p.relative_to(path)).encode()
        h.update(len(relative).to_bytes(8, 'big') + relative)
        if p.is_file():
            h.update(b'x' if p.stat().st_mode & 0o111 else b'f')
            data = p.read_bytes()
            h.update(len(data).to_bytes(8, 'big') + data)
        elif p.is_dir():
            h.update(b'd')
    return h.hexdigest()


class Engine:
    def __init__(self, state='/var/lib/cybexos', working='/etc/nixos', run=None,
                 release='/etc/cybexos/release.json', policy='/etc/cybexos/update.json',
                 trust='/etc/cybexos/trust.json', system='/run/current-system',
                 booted='/run/booted-system'):
        self.state, self.working = Path(state), Path(working)
        self.machine_state = self.state
        self.release, self.policy, self.trust = map(Path, (release, policy, trust))
        self.current_system = Path(system)
        self.booted_system = Path(booted)
        self.run = run or Runner()
        self.status_path = self.state / 'status.json'
        self.pending_path = self.state / 'pending.json'
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / 'transactions').mkdir(exist_ok=True, mode=0o700)

    def status(self, **values):
        previous = read(self.status_path, {})
        now = time.time()
        if 'transaction' in values and values['transaction'] != previous.get('transaction'):
            previous = {'schema': 1, 'startedAt': now, 'phase': '', 'error': '', 'notes': '',
                        'changes': '', 'packageChanges': [], 'highlights': None, 'reviewToken': None, 'inputs': {},
                        'recovery': '', 'retry': '', 'restart': '', 'requestId': None,
                        'workerUnit': None, 'software': None}
        if (values.get('state', previous.get('state')) != previous.get('state')
                or values.get('phase', previous.get('phase')) != previous.get('phase')):
            previous['phaseStartedAt'] = now
        context = getattr(self, 'request_context', {})
        record = previous | values | context | {'updatedAt': now}
        atomic(self.status_path, record, 0o644)
        return record

    def boot_id(self):
        return Path('/proc/sys/kernel/random/boot_id').read_text().strip()

    def tx(self, identifier):
        if not re.fullmatch('[0-9a-f]{32}', identifier):
            raise Failure('Invalid deployment identifier')
        return self.state / 'transactions' / identifier

    def channel(self):
        installed, policy = read(self.release), read(self.policy)
        highest = read(getattr(self, 'machine_state', self.state) / 'channel-sequences.json', {}).get(policy['channel'], 0)
        candidate, sequence = discover(Fetcher(self.state / 'cache'), read(self.trust), policy['channel'],
                                       installed['version'], installed['architecture'], installed['nixos'], highest)
        if (candidate['version'] == installed['version'] and re.fullmatch('[0-9a-f]{40}', installed.get('revision', ''))
                and (candidate['revision'] != installed['revision'] or candidate['narHash'] != installed.get('narHash'))):
            raise Failure('Published version was replaced with different source content. Update rejected.')
        return candidate, sequence

    def check(self):
        result = {'upstream': {}, 'cybexos': {}, 'checkedAt': int(time.time())}
        try:
            lock_body = (self.working / 'flake.lock').read_bytes()
            old = parse(lock_body)
            inputs.validate_machine(old)
        except (Failure, KeyError, TypeError, ValueError, OSError):
            message = 'The machine update configuration is invalid or unavailable. Check /etc/nixos/flake.nix and flake.lock; no inputs were changed.'
            return result | {'upstream': {'state': 'unavailable', 'error': message},
                             'cybexos': {'state': 'unavailable'}, 'error': message}
        result['installedIdentity'] = hashlib.sha256(lock_body).hexdigest()
        problem = None
        try:
            # Discovery has no deployment log. Suppress output logging even if
            # this Runner previously belonged to a staged transaction.
            output = self.run(*UPSTREAM_METADATA, timeout=90, sensitive=True)
        except CommandFailure as error:
            problem = upstream_discovery_error(error.output)
        except (TimeoutError, TimeoutExpired):
            problem = UPSTREAM_LOOKUP_TIMEOUT
        except UnicodeError:
            problem = 'Nix returned malformed package-source metadata. Check Nix configuration.'
        except Failure as error:
            # Runner's deadline currently raises this fixed Failure, rather
            # than TimeoutError. Never publish its transaction-log guidance.
            problem = (UPSTREAM_LOOKUP_TIMEOUT if str(error) ==
                       'nix timed out; inspect the transaction log and retry.' else UPSTREAM_LOOKUP_FAILED)
        except OSError:
            problem = 'Nix metadata lookup could not run. Check that Nix is installed and accessible.'
        else:
            try:
                metadata = parse(output)
                revision = metadata['locked']['rev']
                if not isinstance(revision, str) or not re.fullmatch('[0-9a-f]{40}', revision):
                    raise ValueError('Invalid revision')
            except (Failure, KeyError, TypeError, ValueError):
                problem = 'Nix returned malformed package-source metadata. Check Nix configuration.'
            else:
                installed = inputs.identity(old, 'nixpkgs')['rev']
                result['upstream'] = {'state': 'available' if revision != installed else 'current',
                                      'installed': installed, 'available': revision,
                                      'detail': 'Stage upstream to build and review actual package changes.'}
        if problem:
            result['upstream'] = {'state': 'unreachable', 'error':
                'Nixpkgs (nixos-26.05) package-source status is unknown. ' + problem +
                ' Run `' + ' '.join(UPSTREAM_METADATA) + '` locally for read-only diagnostics.'}
        try:
            candidate, sequence = self.channel()
            result['cybexos'] = {'state': 'available' if version(candidate['version']) > version(read(self.release)['version']) else 'current',
                                'installed': read(self.release)['version'], 'available': candidate['version'],
                                'revision': candidate['revision'], 'notes': candidate['notes'], 'sequence': sequence}
        except NoPublishedRelease:
            result['cybexos'] = {'state': 'unpublished', 'installed': read(self.release)['version']}
        except (Failure, KeyError, TypeError, ValueError) as error:
            result['cybexos'] = {'state': 'unavailable', 'installed': read(self.release)['version'], 'error': str(error)}
        return result

    def components(self, system):
        # A system built before the manifest existed simply lists no components.
        try:
            return review.components(self.run('cat', system + '/etc/cybexos/components.json', sensitive=True))
        except Failure:
            return {}

    def root(self, path, name, tx):
        roots = tx / 'roots'
        roots.mkdir(exist_ok=True)
        self.run('nix-store', '--add-root', roots / name, '--indirect', '-r', path)

    def archive(self, config, tx):
        data = parse(self.run('nix', 'flake', 'archive', '--json', '--no-update-lock-file', f'path:{config}'))
        def retain(node, name):
            self.root(node['path'], name, tx)
            for i, value in enumerate(node.get('inputs', {}).values()):
                retain(value, f'{name}-{i}')
        retain(data, 'configuration')
        atomic(tx / 'archive.json', data)

    def stage(self, scope, region=None, software=None, maintenance=None, request_id=None):
        if scope not in SCOPES:
            raise Failure('Select upstream, cybexos, both, or local')
        with locked(self.state / 'operation.lock'):
            if (self.state / 'maintenance-pending.json').exists():
                raise Failure('Storage cleanup awaits recovery. Complete it before staging another deployment.')
            if self.pending_path.exists():
                raise Failure('A deployment awaits recovery or boot/login health. Confirm it or roll it back before staging another.')
            identifier = uuid.uuid4().hex
            tx = self.tx(identifier)
            tx.mkdir(mode=0o700)
            kind = 'software' if software is not None else 'maintenance' if maintenance is not None else 'region' if region is not None else 'update' if scope != 'local' else 'configuration'
            self.status(transaction=identifier, state='discovering', scope=scope, error='', progress=None,
                        phase='Checking selected sources and preparing your configuration',
                        changeKind=kind, requestId=request_id, software=None)
            self.run.log = tx / 'build.log'
            try:
                # Authentication and metadata compatibility precede lock mutation,
                # evaluation, download of selected code, and activation.
                candidate, sequence = self.channel() if scope in ('cybexos', 'both') else (None, None)
                if candidate:
                    # Lock generation evaluates the selected flake to learn its
                    # inputs. Verify its content before allowing that evaluation,
                    # rather than checking the NAR only after generating a lock.
                    source = 'github:DigitalPals/CybexOS/' + candidate['revision']
                    source += '?' + urlencode({'narHash': candidate['narHash']})
                    fetched = parse(self.run('nix', 'flake', 'prefetch', '--json', source))
                    if fetched.get('hash') != candidate['narHash']:
                        raise Failure('Downloaded source does not match its authenticated NAR identity')
                config = tx / 'config'
                baseline = config_digest(self.working)
                copy_config(self.working, config)
                if config_digest(config) != baseline or config_digest(self.working) != baseline:
                    raise Failure('Personal configuration changed while it was being staged. Stage again.')
                if region is not None:
                    if scope != 'local':
                        raise Failure('Regional changes require a separate local preview')
                    from .configuration import region as prepare_region
                    prepare_region(config, region, self.run)
                selections = None
                if software is not None or maintenance is not None:
                    if scope != 'local' or (software is not None and maintenance is not None):
                        raise Failure('Personal software and maintenance changes require separate local previews.')
                    if software is not None:
                        from .software import prepare
                        selections = prepare(config, software)
                    else:
                        from .maintenance import prepare
                        prepare(config, maintenance)
                old = read(config / 'flake.lock')
                inputs.validate_machine(old)
                if scope in ('upstream', 'both'):
                    self.run('nix', 'flake', 'update', 'nixpkgs', '--flake', f'path:{config}')
                if candidate:
                    flake = config / 'flake.nix'
                    expression = r'(cybexos\.url\s*=\s*")github:DigitalPals/CybexOS/[^"]+("\s*;)'
                    text, count = re.subn(expression, lambda m: m[1] + 'github:DigitalPals/CybexOS/' + candidate['revision'] + m[2], flake.read_text())
                    if count != 1:
                        raise Failure('Machine flake must declare one literal cybexos.url. Keep personal modules in local/.')
                    atomic(flake, text.encode())
                    self.run('nix', 'flake', 'update', 'cybexos', '--flake', f'path:{config}')
                new = read(config / 'flake.lock')
                inputs.validate_delta(old, new, scope)
                if candidate:
                    selected = inputs.identity(new, 'cybexos')
                    if selected.get('rev') != candidate['revision'] or selected.get('narHash') != candidate['narHash']:
                        raise Failure('Selected source does not match authenticated revision and NAR identity')
                    dependencies = set(inputs.resolved(new, 'cybexos').get('inputs', {})) - {'nixpkgs'}
                    if dependencies != set(candidate['vendorInputs']):
                        raise Failure('Selected vendor dependencies differ from the authenticated declaration')
                    atomic(tx / 'release.json', candidate)
                    atomic(tx / 'channel.json', {'channel': read(self.policy)['channel'], 'sequence': sequence})
                self.status(state='building', phase='Downloading inputs and building the complete system')
                self.archive(config, tx)
                if region is not None:
                    from .configuration import verify_region
                    verify_region(config, region, self.run)
                out = parse(self.run('nix', 'build', '--no-link', '--json', '--no-update-lock-file',
                                     f'path:{config}#nixosConfigurations.cybexos.config.system.build.toplevel'))
                system = out[0]['outputs']['out']
                if not re.fullmatch(r'/nix/store/[a-z0-9]{32}-[^/]+', system):
                    raise Failure('Invalid system build output')
                retry_authorizations = []
                for failed in (self.state / 'transactions').glob('*/failed.json'):
                    prior = read(failed.parent / 'deployment.json', {})
                    if prior.get('system') == system:
                        authorization = failed.parent / 'retry-authorized.json'
                        if not authorization.exists():
                            raise Failure('This exact system previously failed health checks. Inspect recovery history and explicitly authorize retry with cybex update retry-failed ' + prior['id'])
                        retry_authorizations.append(authorization)
                self.root(system, 'system', tx)
                previous_system = str(self.current_system.resolve())
                self.root(previous_system, 'previous-system', tx)
                # Keep a separate immutable copy of the active personal configuration.
                copy_config(self.state / 'deployed', tx / 'previous-config')
                (tx / 'previous-inputs').mkdir()
                self.archive(tx / 'previous-config', tx / 'previous-inputs')
                self.status(state='validating', phase='Checking desktop and plugin compatibility')
                self.run(system + '/sw/bin/cybexos-desktop-check', '--system', system, timeout=180)
                changes = self.run('nix', 'store', 'diff-closures', previous_system, system)
                package_changes = review.compare(
                    self.run('cat', previous_system + '/etc/cybexos/software.json', sensitive=True),
                    self.run('cat', system + '/etc/cybexos/software.json', sensitive=True))
                highlights = review.highlights(package_changes, self.components(previous_system),
                                               self.components(system), changes)
                atomic(tx / 'changes.txt', changes.encode())
                record = {'id': identifier, 'scope': scope, 'system': system, 'previousSystem': previous_system,
                          'baseline': baseline, 'configDigest': config_digest(config), 'createdAt': int(time.time()),
                          'inputs': {name: inputs.identity(new, name) for name in ('nixpkgs', 'cybexos')},
                          'changeKind': kind, 'requestId': request_id, 'software': selections,
                          'packageChanges': package_changes, 'highlights': highlights}
                record['reviewToken'] = hashlib.sha256((record['configDigest'] + changes + review.identity(package_changes)
                                                        + review.identity(highlights)).encode()).hexdigest()
                atomic(tx / 'deployment.json', record)
                self.status(state='ready', phase='Built and checked; review changes before applying',
                            changes=changes, packageChanges=package_changes, highlights=highlights,
                            reviewToken=record['reviewToken'], inputs=record['inputs'],
                            installedVersion=read(self.release)['version'], availableVersion=candidate['version'] if candidate else read(self.release)['version'],
                            notes=candidate['notes'] if candidate else '', software=selections,
                            restart='Reboot may be required; no reboot is automatic.')
                # A failed preview must not spend explicit retry permission.
                for authorization in retry_authorizations:
                    authorization.unlink(missing_ok=True)
                return record
            except BaseException as error:
                self.status(state='failed', phase='Staging failed; working system retained', error=str(error),
                            retry='Stage upstream explicitly to retain the installed Cybex OS version.' if scope == 'both' else 'Correct the failure and stage again.')
                raise
            finally:
                self.run.log = None

    def git_metadata_record(self, root):
        key = hashlib.sha256(str(Path(root).resolve()).encode()).hexdigest()
        return self.state / 'configuration-git' / (key + '.json')

    def git_metadata(self, source):
        """Reference persistent Git data without archiving it or invoking Git."""
        root = Path(source).resolve()
        declaration = read(self.git_metadata_record(root), {})
        managed = declaration.get('references', {}) if declaration.get('root') == str(root) else {}
        references = {}
        for metadata in root.rglob('.git'):
            relative = str(metadata.relative_to(root))
            if '.git' in metadata.relative_to(root).parts[:-1]:
                continue
            target = metadata
            if metadata.is_symlink():
                expected = managed.get(relative)
                if not expected or str(metadata.readlink()) != expected:
                    raise Failure('Unmanaged .git symlink cannot be preserved safely. Keep a regular Git metadata directory or use a separate personal repository; no configuration was selected.')
                target = Path(expected)
            if target.is_symlink() or not target.is_dir() or (target / 'commondir').exists():
                raise Failure('Linked-worktree or pointer-file .git layout cannot be preserved safely. Keep a regular Git metadata directory or use a separate personal repository; no configuration was selected.')
            # An explicit Git worktree override would keep directing Git at the
            # old physical tree after selection. Do not rewrite user metadata.
            try:
                settings = configparser.RawConfigParser(strict=False)
                settings.read(target / 'config')
            except configparser.Error as error:
                raise Failure('Git metadata configuration cannot be safely preserved. Use a regular Git repository without worktree overrides; no configuration was selected.') from error
            if any(settings.has_option(section, 'worktree') for section in settings.sections() if section.lower() == 'core'):
                raise Failure('Git core.worktree overrides cannot be preserved safely. Use a regular Git repository without worktree overrides; no configuration was selected.')
            if any(section.lower() == 'include' or section.lower().startswith('includeif ') for section in settings.sections()):
                raise Failure('Git included configuration may override the worktree and cannot be preserved safely. Use a regular Git repository without configuration includes or a separate personal repository; no configuration was selected.')
            references[relative] = str(target.resolve())
        return references

    def select_config(self, source, identifier, fresh=False):
        references = self.git_metadata(self.working)
        working = self.state / 'working' / identifier
        working.parent.mkdir(exist_ok=True, mode=0o755)
        if working.exists() and fresh:
            # Repeated rollback must select the exact retained configuration,
            # while keeping edits made in an earlier working selection intact.
            working = working.with_name(identifier + '-' + uuid.uuid4().hex)
        if working.exists() and config_digest(working) != config_digest(source):
            raise Failure('An existing working selection was edited. Stage a new deployment; its files were preserved.')
        if not working.exists():
            copy_config(source, working)
        if not self.working.is_symlink():
            raise Failure('/etc/nixos must be the installer-owned working-configuration symlink')
        existing = self.git_metadata(working)
        if existing and existing != references:
            raise Failure('An existing working selection contains different Git metadata. Stage a new deployment; its repository was preserved.')
        # The declaration authenticates only the updater's internal references;
        # ordinary personal links elsewhere in configuration remain prohibited.
        atomic(self.git_metadata_record(working), {'root': str(working), 'references': references})
        for relative, target in references.items():
            metadata = working / relative
            if metadata.parent.is_dir() and not metadata.exists() and not metadata.is_symlink():
                link(target, metadata)
        link(working, self.working)

    def switch(self, system, action):
        try:
            self.run(system + '/bin/switch-to-configuration', action)
        except CommandFailure as error:
            # NixOS reports any failed systemd unit, including pre-existing
            # failures. Its exit 4 can also mask an activation-script exit 2.
            # Never accept that masked error, even when declared health passes.
            if (error.returncode != 4 or 'Failed to run activate script' in error.output
                    or re.search(r"Activation script snippet '[^'\n]+' failed", error.output)):
                raise
            if self.run.log:
                with Path(self.run.log).open('a') as log:
                    log.write('NixOS reported service warnings (exit 4); checking activation diagnostics and system-service health.\n')

    def failed_units(self):
        units = parse(self.run('systemctl', 'list-units', '--state=failed,auto-restart', '--all', '--output=json', '--no-pager'))
        if not isinstance(units, list) or any(not isinstance(unit, dict) or not isinstance(unit.get('unit'), str)
                                               or not isinstance(unit.get('sub'), str) for unit in units):
            raise Failure('Cannot determine failed system services; activation was not accepted.')
        failed = set()
        for unit in units:
            if unit['sub'] == 'auto-restart':
                status = self.run('systemctl', 'show', '--property=ExecMainStatus', '--value', unit['unit']).strip()
                if not re.fullmatch(r'[0-9]+', status):
                    raise Failure('Cannot determine restarting service exit status; activation was not accepted.')
                # Restart=always with a successful exit can be intentional.
                if int(status) == 0:
                    continue
            failed.add(unit['unit'])
        return failed

    def reject_new_failures(self, before):
        newly_failed = self.failed_units() - before
        if newly_failed:
            raise Failure('Activation introduced failed system units: ' + ', '.join(sorted(newly_failed))
                          + '. Inspect their journals and correct the configuration before retrying.')

    def profile(self, system):
        self.run('nix-env', '--profile', '/nix/var/nix/profiles/system', '--set', system)
        self.switch(system, 'boot')

    def apply(self, identifier, token):
        with locked(self.state / 'operation.lock'):
            tx = self.tx(identifier)
            self.run.log = tx / 'build.log'
            record = read(tx / 'deployment.json')
            if not record or read(self.status_path).get('state') != 'ready' or read(self.status_path).get('transaction') != identifier:
                raise Failure('This deployment is not ready for application')
            if token != record['reviewToken']:
                raise Failure('Staged configuration changed after review; stage and review again')
            reason = ''
            try:
                unchanged = (config_digest(tx / 'config') == record['configDigest']
                             and config_digest(self.working) == record['baseline']
                             and str(self.current_system.resolve()) == record['previousSystem'])
            except Failure as error:
                reason = str(error) + ' '
                unchanged = False
            except OSError:
                unchanged = False
            if not unchanged:
                message = reason + 'The system or personal configuration changed after preparation. Prepare again to preserve those changes.'
                self.status(state='stale', phase=message, error=message, reviewToken=None)
                raise Failure(message)
            self.git_metadata(self.working)
            atomic(self.pending_path, record | {'phase': 'activation', 'bootId': self.boot_id()})
            self.status(state='activating', phase='Activating under supervision')
            try:
                # Pin the safe persistent boot default before the boot installer
                # can write a candidate menu. Power loss during profile() must
                # not leave an unvalidated candidate as the default boot.
                self.run('cybexos-boot-trial', '--restore', record['previousSystem'])
                previously_failed = self.failed_units()
                self.switch(record['system'], 'test')
                self.reject_new_failures(previously_failed)
                self.run(record['system'] + '/sw/bin/cybexos-health', 'system', timeout=120)
                self.run(record['system'] + '/sw/bin/cybexos-health', 'desktop', timeout=120)
                if config_digest(self.working) != record['baseline']:
                    raise Failure('Personal configuration changed during activation. Working edits retained; stage again.')
                self.select_config(tx / 'config', identifier)
                self.profile(record['system'])
                self.reject_new_failures(previously_failed)
                # Keep the previous boot as default and try the candidate once.
                # A failed boot therefore does not strand the next boot on it.
                self.run('cybexos-boot-trial', record['system'], record['previousSystem'])
                atomic(self.pending_path, record | {'phase': 'boot', 'bootId': self.boot_id()})
                self.status(state='awaiting-boot', phase='Activation passed. Reboot when ready, then sign in to confirm health.',
                            recovery='Previous generation remains the default until the trial boot and desktop pass.', restart='Reboot required')
            except BaseException as error:
                # Keep the original failure even if restoration also fails or
                # is interrupted. Command output stays in the private log.
                atomic(tx / 'activation-error.json', {'error': str(error), 'at': int(time.time())})
                selected = self.state / 'working' / identifier
                self.restore(record, 'Activation failed',
                             preserve_working=self.working.resolve() != selected.resolve())
                raise

    def restore(self, record, reason, preserve_working=False):
        tx = self.tx(record['id'])
        self.run.log = tx / 'build.log'
        activation_error = read(tx / 'activation-error.json', {}).get('error', '')
        # Explicit rollback can start without a pending deployment. Journal it
        # first, and distinguish recovery from a healthy boot trial so a second
        # interruption always resumes restoration, including on the same boot.
        atomic(self.pending_path, record | {'phase': 'recovery', 'preserveWorking': preserve_working})
        self.status(state='recovering', phase='Restoring previous generation: ' + reason, error=activation_error)
        try:
            # Disarming the one-shot requires no retained boot entry and must
            # precede even personal backup validation. profile() recreates a
            # pruned entry before --restore selects the known-good default.
            self.run('cybexos-boot-trial', '--disarm')
            if not (tx / 'personal-before-rollback').exists():
                copy_config(self.working, tx / 'personal-before-rollback')
            self.profile(record['previousSystem'])
            self.run('cybexos-boot-trial', '--restore', record['previousSystem'])
            self.switch(record['previousSystem'], 'test')
            self.run(record['previousSystem'] + '/sw/bin/cybexos-health', 'system', timeout=120)
            if not preserve_working:
                self.select_config(tx / 'previous-config', record['id'] + '-rollback', fresh=True)
            atomic(tx / 'failed.json', {'reason': reason, 'at': int(time.time())})
            link(tx / 'previous-config', self.state / 'deployed')
            self.status(state='rolled-back', phase=reason + '; previous generation restored', error=activation_error,
                        recovery='Configuration and generation restored; persistent application data was not rolled back.')
            self.pending_path.unlink(missing_ok=True)
            syncdir(self.state)
        except BaseException as error:
            # The pending record is the resumable recovery boundary. Never
            # report success or an endless running state when a worker exits.
            if self.pending_path.exists():
                atomic(tx / 'recovery-error.json', {'error': str(error), 'at': int(time.time())})
                failures = ([('Activation failed: ' + activation_error)] if activation_error else [])
                failures.append('Restoration failed: ' + str(error))
                self.status(state='recovery-failed', phase='Restoration failed; recovery remains pending',
                            error='\n'.join(failures),
                            recovery='Inspect cybex update log ' + record['id'] + '. Correct the reported failure, then retry cybex update rollback ' + record['id']
                                     + '. A reboot into the retained known-good boot entry also resumes recovery. Personal configuration and state remain retained.',
                            restart='Recovery is incomplete; no reboot is automatic.')
            raise

    def recover(self):
        # Activation may restart a previously failed recovery unit while a
        # supervised worker owns the lock. That worker owns durable recovery.
        with locked(self.state / 'operation.lock', skip_busy=True) as acquired:
            if not acquired:
                return
            if (self.state / 'maintenance-pending.json').exists():
                from .maintenance import Maintenance
                Maintenance(self, worker_unit='cybexos-recover.service').resume()
            pending = read(self.pending_path)
            if not pending:
                status = read(self.status_path, {})
                if status.get('state') in BUSY:
                    self.status(state='interrupted', phase='Interrupted before activation; working system retained. Stage again.')
                return
            self.run.log = self.tx(pending['id']) / 'build.log'
            current = str(self.current_system.resolve())
            boot_id = self.boot_id()
            if pending['phase'] != 'boot':
                selected = self.state / 'working' / pending['id']
                preserve = pending.get('preserveWorking', pending['phase'] == 'activation'
                                       and self.working.resolve() != selected.resolve())
                self.restore(pending, 'Interrupted application', preserve_working=preserve)
                return
            if boot_id == pending['bootId']:
                return
            if current != pending['system'] or str(self.booted_system.resolve()) != pending['system']:
                self.restore(pending, 'Failed trial boot')
                return
            if (self.tx(pending['id']) / 'good.json').is_file():
                # Confirmation already passed health, committed the boot default
                # and retained channel replay protection. Complete its durable
                # bookkeeping instead of asking for another trial confirmation.
                self.finish_confirmation(pending)
                return
            try:
                self.run('cybexos-health', 'system', timeout=120)
            except Failure:
                self.restore(pending, 'Trial boot failed system health')
                return
            self.status(state='awaiting-login', phase='Trial boot passed system health. Sign in to validate the desktop.')

    def confirm(self):
        with locked(self.state / 'operation.lock'):
            record = read(self.pending_path)
            if (not record or record.get('phase') != 'boot'
                    or str(self.current_system.resolve()) != record['system']
                    or str(self.booted_system.resolve()) != record['system']):
                raise Failure('No running trial generation to confirm')
            if self.boot_id() == record['bootId']:
                raise Failure('Confirmation requires a fresh boot of the selected generation')
            self.run.log = self.tx(record['id']) / 'build.log'
            self.run('cybexos-health', 'system', timeout=120)
            self.run('cybexos-health', 'desktop-required', timeout=120)
            self.run('cybexos-boot-trial', '--commit', record['system'])
            tx = self.tx(record['id'])
            channel = read(tx / 'channel.json')
            if channel:
                high = read(self.state / 'channel-sequences.json', {})
                high[channel['channel']] = max(high.get(channel['channel'], 0), channel['sequence'])
                atomic(self.state / 'channel-sequences.json', high, 0o644)
            atomic(tx / 'good.json', {'at': int(time.time())})
            self.finish_confirmation(record)

    def finish_confirmation(self, record):
        """Idempotent finalization after the durable successful-health marker."""
        link(self.tx(record['id']) / 'config', self.state / 'deployed')
        # Publish the completed state before removing the recovery record. A
        # crash after unlink must never leave an unconfirmable awaiting-login UI.
        self.status(state='done', phase='Boot, login, system services, Hyprland and Quickshell passed health checks.',
                    recovery='Known-good generation and all input identities retained against garbage collection.', restart='None')
        self.pending_path.unlink(missing_ok=True)
        syncdir(self.state)

    def rollback(self, identifier=None):
        with locked(self.state / 'operation.lock'):
            if (self.state / 'maintenance-pending.json').exists():
                raise Failure('Storage cleanup awaits recovery. Complete it before rollback.')
            if identifier and (self.tx(identifier) / 'retired.json').exists():
                raise Failure('This recovery point was retired by reviewed storage cleanup. Choose a retained deployment.')
            record = read(self.pending_path) if identifier is None else read(self.tx(identifier) / 'deployment.json')
            if not record:
                raise Failure('Select a retained deployment from cybex update history')
            self.restore(record, 'Explicit rollback requested')

    def discard(self, identifier):
        with locked(self.state / 'operation.lock'):
            status = read(self.status_path, {})
            self.tx(identifier)
            # A finished failure can be dismissed too; its files and logs stay.
            if (self.pending_path.exists() or status.get('transaction') != identifier
                    or status.get('state') not in ('ready', 'stale', 'failed', 'interrupted', 'rolled-back')):
                raise Failure('Only the current unapplied preview or a finished failure can be dismissed. Refresh its status.')
            self.status(transaction=None, state='idle', changeKind=None, scope=None,
                        phase='Preview discarded. No update was applied.' if status['state'] in ('ready', 'stale')
                        else 'Dismissed. The running system was not changed.')
