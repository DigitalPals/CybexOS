"""Reviewed retention of Cybex OS recovery closures, serialized with deployments.

Personal configuration, logs and saved edits are never deleted. A durable job
retires only named GC roots and owned system-profile generations before Nix GC.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

from .common import Failure, atomic, locked, parse, read, syncdir

DEFAULT_POLICY = {'automatic': True, 'keepConfirmed': 5, 'keepDays': 30}
STORE = re.compile(r'/nix/store/[a-z0-9]{32}-[^/\s]+')
ID = re.compile(r'[a-f0-9]{32}')


def policy(value):
    if (not isinstance(value, dict) or set(value) != set(DEFAULT_POLICY)
            or type(value['automatic']) is not bool
            or type(value['keepConfirmed']) is not int or not 5 <= value['keepConfirmed'] <= 100
            or type(value['keepDays']) is not int or not 30 <= value['keepDays'] <= 3650):
        raise Failure('Keep at least five confirmed deployments and 30 days of recovery history.')
    return value


def configuration(config):
    path = Path(config) / 'local/maintenance.json'
    current = read(path)
    if path.is_symlink() or not isinstance(current, dict) or set(current) != {'schema', 'policy'} or current['schema'] != 1:
        raise Failure('The machine-owned local/maintenance.json declaration is missing or unsupported.')
    return policy(current['policy'])


def prepare(config, request):
    if not isinstance(request, dict) or set(request) != {'previous', 'policy'}:
        raise Failure('Invalid cleanup policy request')
    if configuration(config) != policy(request['previous']):
        raise Failure('Cleanup preferences changed. Refresh before previewing again.')
    atomic(Path(config) / 'local/maintenance.json', {'schema': 1, 'policy': policy(request['policy'])}, 0o644)


def space(path='/nix/store'):
    stat = os.statvfs(path)
    return {'total': stat.f_blocks * stat.f_frsize, 'available': stat.f_bavail * stat.f_frsize,
            'low': stat.f_bavail * stat.f_frsize < max(10 * 1024**3, stat.f_blocks * stat.f_frsize // 10)}


def public_status(state='/var/lib/cybexos', policy_path='/etc/cybexos/maintenance.json', store='/nix/store', config='/etc/nixos'):
    effective = policy(read(policy_path, DEFAULT_POLICY))
    problem = ''
    try:
        desired = configuration(config)
    except (Failure, OSError):
        desired = effective
        problem = 'The personal cleanup declaration is unavailable or unsupported. Preserve and inspect local/maintenance.json before staging preferences.'
    result = {'schema': 1, 'state': 'idle',
            **read(Path(state) / 'maintenance-status.json', {}),
            'policy': effective, 'desiredPolicy': desired, 'configurationError':problem,
            'configurationChanged': desired != effective, 'space': space(store),
            'recoveryPending': (Path(state) / 'maintenance-pending.json').exists()}
    if result['state'] in ('checking', 'cleaning'):
        identifier = result.get('requestId')
        unit = (f'cybexos-maintenance@{identifier}.service'
                if isinstance(identifier, str) and ID.fullmatch(identifier)
                else 'cybexos-maintenance-auto.service')
        if result.get('workerUnit') == 'cybexos-recover.service':
            unit = 'cybexos-recover.service'
        try:
            worker = subprocess.run(['systemctl', 'show', unit, '-p', 'ActiveState', '-p', 'SubState'],
                                    text=True, capture_output=True, timeout=10)
            properties = dict(line.split('=', 1) for line in worker.stdout.splitlines() if '=' in line)
            if worker.returncode == 0 and (properties.get('ActiveState') in ('inactive', 'failed') or properties.get('SubState') == 'exited'):
                result.update(state='failed', reviewToken=None,
                              error='The cleanup worker stopped. Resume pending cleanup or review storage cleanup again.')
        except (OSError, subprocess.TimeoutExpired):
            pass
    return result


class Maintenance:
    def __init__(self, engine, policy_path='/etc/cybexos/maintenance.json',
                 profiles='/nix/var/nix/profiles', store='/nix/store', now=None, request_id=None, worker_unit=None):
        self.engine, self.state = engine, engine.state
        self.policy_path, self.profiles, self.store = Path(policy_path), Path(profiles), Path(store)
        self.now = int(time.time()) if now is None else now
        self.pending = self.state / 'maintenance-pending.json'
        self.request_id = request_id
        self.worker_unit = worker_unit

    def publish(self, **values):
        previous = read(self.state / 'maintenance-status.json', {})
        atomic(self.state / 'maintenance-status.json', previous | values | {'updatedAt': self.now, 'requestId': self.request_id, 'workerUnit':self.worker_unit}, 0o644)

    def guard(self):
        status = read(self.engine.status_path, {})
        if self.engine.pending_path.exists() or status.get('state') in (
                'discovering', 'building', 'validating', 'ready', 'activating', 'recovering', 'firmware',
                'awaiting-boot', 'awaiting-login', 'recovery-failed'):
            raise Failure('Finish or recover the current deployment before storage cleanup.')
        if self.pending.exists():
            raise Failure('An interrupted storage cleanup awaits recovery.')

    def roots(self, tx):
        result = {}
        for folder in (tx / 'roots', tx / 'previous-inputs/roots'):
            if folder.is_symlink():
                raise Failure('A deployment root directory is linked; cleanup refused.')
            if not folder.exists():
                continue
            for path in folder.iterdir():
                if not path.is_symlink() or not STORE.fullmatch(str(path.resolve())):
                    raise Failure('A deployment contains an unknown GC reference; cleanup refused.')
                result[str(path)] = str(path.resolve())
        return result

    def snapshot(self, require_confirmation=False):
        self.guard()
        chosen = policy(read(self.policy_path, DEFAULT_POLICY))
        pins = read(self.state / 'maintenance-pins.json', [])
        if not isinstance(pins, list) or any(not isinstance(p, str) or not ID.fullmatch(p) for p in pins):
            raise Failure('Recovery pins are unreadable. Cleanup refused.')
        current, booted = str(self.engine.current_system.resolve()), str(self.engine.booted_system.resolve())
        if not STORE.fullmatch(current) or current != booted:
            raise Failure('Cleanup requires a confirmed system boot. Reboot and confirm the deployment first.')
        records = []
        for tx in sorted((self.state / 'transactions').iterdir()):
            if not ID.fullmatch(tx.name) or tx.is_symlink() or not tx.is_dir():
                raise Failure('Unknown deployment directory. Inspect it before storage cleanup.')
            record = read(tx / 'deployment.json')
            if not record:
                # An incomplete stage is unresolved and keeps all its roots.
                records.append({'id': tx.name, 'createdAt': 0, 'good': False, 'incomplete': True,
                                'roots': self.roots(tx), 'retired': False})
                continue
            # Device-only updates own no Nix generation or configuration roots.
            if record.get('scope') == 'firmware' and record.get('id') == tx.name:
                continue
            if (record.get('id') != tx.name or not STORE.fullmatch(record.get('system', ''))
                    or not STORE.fullmatch(record.get('previousSystem', ''))
                    or type(record.get('createdAt')) is not int):
                raise Failure('A deployment record is unreadable. Cleanup refused.')
            records.append(record | {'good': (tx / 'good.json').exists(),
                                     'failed': (tx / 'failed.json').exists(),
                                     'retired': (tx / 'retired.json').exists(),
                                     'roots': self.roots(tx)})
        confirmed = sorted((r for r in records if r.get('good') and not r['retired']),
                           key=lambda r: (r['createdAt'], r['id']), reverse=True)
        active = next((r for r in confirmed if r['system'] == current), None)
        if active is None and require_confirmation:
            raise Failure('Automatic cleanup requires a retained confirmed deployment for this boot.')
        self.engine.run('cybexos-health', 'system', timeout=120)
        keep = {r['id'] for r in confirmed[:chosen['keepConfirmed']]} | set(pins) | ({active['id']} if active else {r['id'] for r in records})
        selected_paths = [self.engine.working.resolve(), (self.state / 'deployed').resolve()]
        cutoff = self.now - chosen['keepDays'] * 86400
        deployments, retired_roots, all_roots, protected_systems = [], {}, {}, {current, booted, active['previousSystem'] if active else current}
        for record in records:
            tx = self.state / 'transactions' / record['id']
            reasons = []
            if active is None: reasons.append('No confirmed recovery point matches this boot; references retained')
            if record['id'] in keep: reasons.append('Confirmed, pinned or retained by count')
            if record['createdAt'] >= cutoff: reasons.append('Within retention period')
            if not record.get('good') or record.get('failed'): reasons.append('Unresolved or failed deployment')
            if any(path.is_relative_to(tx) for path in selected_paths): reasons.append('Selected personal configuration')
            if record.get('system') in (current, booted) or record.get('previousSystem') == current:
                reasons.append('References the running system')
            eligible = not reasons and not record['retired']
            all_roots.update(record['roots'])
            if eligible:
                retired_roots.update(record['roots'])
            elif not record['retired']:
                protected_systems.update(record['roots'].values())
            deployments.append({'id': record['id'], 'createdAt': record['createdAt'],
                                'confirmed': record.get('good', False), 'pinned': record['id'] in pins,
                                'retired': record['retired'], 'eligible': eligible, 'reasons': reasons})
        # A kept transaction can reference an older system as its fallback.
        candidates = {r['id'] for r in deployments if r['eligible']}
        disposable_systems = {value for r in records if r['id'] in candidates
                              for value in (r.get('system'), r.get('previousSystem')) if value} - protected_systems
        generations = {}
        for path in self.profiles.glob('system-*-link'):
            match = re.fullmatch(r'system-([0-9]+)-link', path.name)
            if match and path.is_symlink() and str(path.resolve()) in disposable_systems:
                generations[match[1]] = str(path.resolve())
        # Profile roots kept by Nix remain authoritative, including personal ones.
        public_roots = self.engine.run('nix-store', '--gc', '--print-roots', timeout=120, sensitive=True)
        ignored = set(retired_roots) | {str(self.profiles / f'system-{g}-link') for g in generations}
        remaining = set()
        for line in public_roots.splitlines():
            root, separator, target = line.rpartition(' -> ')
            if separator and root.startswith('"'):
                root = parse(root)
            if separator and STORE.fullmatch(target) and root not in ignored:
                remaining.add(target)
        # Transient builder/process roots can change between preview and apply.
        # Nix GC preserves them independently; they affect only our size estimate.
        material = {'policy': chosen, 'pins': pins, 'records': records, 'generations': generations,
                    'candidates': sorted(candidates), 'current': current, 'booted': booted,
                    'selected': list(map(str, selected_paths))}
        identity = hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()
        return {'identity': identity, 'policy': chosen, 'deployments': deployments,
                'candidates': sorted(candidates), 'roots': retired_roots, 'generations': generations,
                'current': current, 'remaining': sorted(remaining | protected_systems)}

    def estimate(self, plan):
        targets = sorted(set(plan['roots'].values()) | set(plan['generations'].values()))
        def closure(paths):
            result = set()
            for offset in range(0, len(paths), 100):
                result.update(self.engine.run('nix-store', '--query', '--requisites', *paths[offset:offset + 100], timeout=180).splitlines())
            return result
        dead = set(self.engine.run('nix-store', '--gc', '--print-dead', timeout=180).splitlines())
        possible = sorted((closure(targets) - closure(plan['remaining'])) | dead)
        if not possible:
            return 0
        total = 0
        for offset in range(0, len(possible), 100):
            size = parse(self.engine.run('nix', 'path-info', '--json', *possible[offset:offset + 100], timeout=180))
            values = size.values() if isinstance(size, dict) else size
            total += sum(p.get('narSize', 0) for p in values)
        return total

    def preview(self):
        with locked(self.state / 'operation.lock'):
            self.publish(state='checking', error='', reviewToken=None)
            try:
                plan = self.snapshot()
                plan.update(id=uuid.uuid4().hex, estimatedBytes=self.estimate(plan))
                plan['token'] = hashlib.sha256(json.dumps(plan, sort_keys=True).encode()).hexdigest()
                atomic(self.state / 'maintenance-preview.json', plan)
                self.publish(state='ready', reviewId=plan['id'], reviewToken=plan['token'],
                             policy=plan['policy'], deployments=plan['deployments'],
                             candidates=plan['candidates'], estimatedBytes=plan['estimatedBytes'])
                return plan
            except BaseException as error:
                self.publish(state='failed', error=str(error) if isinstance(error, Failure) else 'Storage cleanup failed. Inspect the private maintenance log.', reviewToken=None)
                raise

    def clean(self, identifier=None, token=None, automatic=False):
        with locked(self.state / 'operation.lock', skip_busy=automatic) as acquired:
            if not acquired:
                return
            if automatic and not policy(read(self.policy_path, DEFAULT_POLICY))['automatic']:
                return
            try:
                current = self.snapshot(require_confirmation=automatic)
                if automatic:
                    plan = current | {'id': uuid.uuid4().hex}
                else:
                    plan = read(self.state / 'maintenance-preview.json', {})
                    if plan.get('id') != identifier or plan.get('token') != token or plan.get('identity') != current['identity']:
                        raise Failure('The cleanup review is stale. Review storage cleanup again.')
                # The restartable journal precedes every destructive operation.
                atomic(self.pending, plan | {'phase': 'profiles' if plan['candidates'] else 'gc'})
                self.resume()
            except BaseException as error:
                self.publish(state='skipped' if automatic and not self.pending.exists() else 'failed', error=str(error) if isinstance(error, Failure) else 'Storage cleanup failed. Inspect the private maintenance log.', reviewToken=None)
                if not automatic:
                    raise

    def resume(self):
        """Caller owns operation.lock, including boot recovery."""
        job = read(self.pending)
        if not job:
            return
        if str(self.engine.current_system.resolve()) != job['current'] or str(self.engine.booted_system.resolve()) != job['current']:
            raise Failure('Resume cleanup from the confirmed system that started it. Other boot selections are preserved.')
        self.publish(state='cleaning', error='', reviewToken=None)
        old_log = self.engine.run.log
        self.engine.run.log = self.state / 'maintenance.log'
        try:
            self.engine.run('cybexos-health', 'system', timeout=120)
            if job['phase'] == 'profiles':
                for generation, target in job['generations'].items():
                    path = self.profiles / f'system-{generation}-link'
                    if path.is_symlink() and str(path.resolve()) != target:
                        raise Failure('A system generation changed during cleanup; inspect the cleanup log.')
                    if path.is_symlink():
                        self.engine.run('nix-env', '--profile', self.profiles / 'system', '--delete-generations', generation)
                # Reinstall boot entries from the retained system before GC can
                # remove any old kernel. Never change Secure Boot or boot the host.
                self.engine.switch(job['current'], 'boot')
                self.engine.run('cybexos-boot-trial', '--restore', job['current'])
                atomic(self.pending, job | {'phase': 'roots'})
                job['phase'] = 'roots'
            if job['phase'] == 'roots':
                for name, target in job['roots'].items():
                    path = Path(name)
                    if not path.is_relative_to(self.state / 'transactions'):
                        raise Failure('Cleanup journal contains an invalid root.')
                    if path.is_symlink():
                        if str(path.resolve()) != target:
                            raise Failure('A GC root changed during cleanup; inspect the cleanup log.')
                        path.unlink()
                        syncdir(path.parent)
                    elif path.exists():
                        raise Failure('An expected GC root is no longer a link.')
                for identifier in job['candidates']:
                    atomic(self.engine.tx(identifier) / 'retired.json', {'at': self.now, 'cleanup': job['id']})
                atomic(self.pending, job | {'phase': 'gc'})
                job['phase'] = 'gc'
            if job['phase'] == 'gc':
                # Nix enforces all other roots and concurrent builder references.
                # Measure NAR bytes actually removed; filesystem compression and
                # other concurrent I/O can make the free-space change differ.
                dead = self.engine.run('nix-store', '--gc', '--print-dead', timeout=180).splitlines()
                sizes = {}
                for offset in range(0, len(dead), 100):
                    batch = parse(self.engine.run('nix', 'path-info', '--json', *dead[offset:offset + 100], timeout=180))
                    sizes.update({p['path']: p for p in batch} if isinstance(batch, list) else batch)
                self.engine.run('nix-store', '--gc', timeout=7200)
                reclaimed = sum(info.get('narSize', 0) for path, info in sizes.items() if not Path(path).exists())
                self.publish(state='done', error='', reclaimedBytes=reclaimed, lastCleanup=self.now,
                             candidates=[], recoveryPending=False, deployments=[d | {'retired': True, 'eligible': False}
                                if d['id'] in job['candidates'] else d for d in job['deployments']])
                self.pending.unlink()
                syncdir(self.state)
        except BaseException as error:
            self.publish(state='failed', error=str(error) if isinstance(error, Failure) else 'Storage cleanup failed. Inspect the private maintenance log.', recoveryPending=True)
            raise
        finally:
            self.engine.run.log = old_log

    def pin(self, identifier, enabled):
        with locked(self.state / 'operation.lock'):
            self.guard()
            tx = self.engine.tx(identifier)
            if not (tx / 'good.json').exists() or (tx / 'retired.json').exists():
                raise Failure('Only retained confirmed recovery points can be pinned.')
            pins = set(read(self.state / 'maintenance-pins.json', []))
            pins.add(identifier) if enabled else pins.discard(identifier)
            atomic(self.state / 'maintenance-pins.json', sorted(pins))
            plan = self.snapshot()
            self.publish(state='idle', reviewToken=None, deployments=plan['deployments'], candidates=[])
