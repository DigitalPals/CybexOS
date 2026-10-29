"""Background preparation and post-restart confirmation of system updates.

Both run as root from fixed system units the signed-in desktop may start.
They take no input: each reads the machine policy and the updater's own state,
then submits an ordinary supervised request or does nothing. Preparation
downloads and builds; installing a prepared update still needs authorization.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

from .common import Failure, atomic, read

POLICY = 'update-automatic.json'
LAST_RUN = 'update-automatic-run.json'
DEFAULTS = {'prepare': True, 'confirm': True}
# A failed automatic preparation of the same target is retried at most daily.
RETRY_SECONDS = 24 * 3600


def policy(state=Path('/var/lib/cybexos')):
    """Defaults apply when no choice was made; an unreadable choice disables."""
    try:
        value = read(Path(state) / POLICY, {})
    except Failure:
        value = None
    if not isinstance(value, dict) or any(not isinstance(value.get(key, True), bool) for key in DEFAULTS):
        return {key: False for key in DEFAULTS}
    return {key: value.get(key, default) for key, default in DEFAULTS.items()}


def choose(state, name, enabled):
    if name not in DEFAULTS or not isinstance(enabled, bool):
        raise Failure('Invalid automatic update choice')
    value = policy(state) | {name: enabled}
    atomic(Path(state) / POLICY, value, 0o644)
    return value


def metered(run=subprocess.run):
    """NetworkManager's metered guess; unknown or unavailable is not metered."""
    try:
        result = run(['busctl', 'get-property', 'org.freedesktop.NetworkManager',
                      '/org/freedesktop/NetworkManager', 'org.freedesktop.NetworkManager', 'Metered'],
                     capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    match = re.fullmatch(r'u ([0-9]+)\s*', result.stdout or '') if result.returncode == 0 else None
    # NM_METERED_YES and NM_METERED_GUESS_YES.
    return bool(match) and int(match[1]) in (1, 3)


def target(config, discovery):
    sources = {name: discovery[name].get('available') if discovery[name].get('state') == 'available' else None
               for name in ('upstream', 'cybexos')}
    scope = 'both' if all(sources.values()) else 'upstream' if sources['upstream'] else 'cybexos' if sources['cybexos'] else ''
    devices = (discovery.get('firmware') or {}).get('devices', [])
    if not scope and devices:
        scope = 'firmware'
    identity = hashlib.sha256(json.dumps({'config': config, **sources, 'firmware': devices}, sort_keys=True).encode()).hexdigest()
    return scope, identity


def prepare(engine, enqueue, status, config_digest, discover=None, is_metered=metered, now=time.time):
    """Submit one preparation per available target; never repeat a reviewed one."""
    state = engine.state
    if not policy(state)['prepare']:
        return {'skipped': 'disabled'}
    current = status()
    if (current.get('firmware') or {}).get('needsReboot'):
        return {'skipped': 'restart'}
    last = read(state / LAST_RUN, {}) or {}
    own_failure = (current.get('state') in ('failed', 'interrupted') and last.get('requestId')
                   and current.get('requestId') == last.get('requestId'))
    # Anything else in progress, awaiting review/restart or needing attention
    # belongs to the person. Their own failures are dismissed in the app.
    if current.get('state', 'idle') not in ('idle', 'done') and not own_failure:
        return {'skipped': current.get('state')}
    if (current.get('request') or {}).get('state') in ('queued', 'running', 'unknown'):
        return {'skipped': 'request'}
    if is_metered():
        return {'skipped': 'metered'}
    discovery = (discover or engine.check)()
    scope, identity = target(config_digest(engine.working), discovery)
    if not scope:
        return {'skipped': 'current'}
    if last.get('target') == identity and not (own_failure and now() - last.get('at', 0) >= RETRY_SECONDS):
        return {'skipped': 'prepared'}
    accepted = enqueue(state, 'stage', [scope])
    atomic(state / LAST_RUN, {'target': identity, 'scope': scope, 'requestId': accepted['requestId'],
                              'at': now()}, 0o644)
    return accepted | {'scope': scope}


def confirm(engine, enqueue, status):
    """Confirm a trial boot from the signed-in desktop; health still decides."""
    if not policy(engine.state)['confirm']:
        return {'skipped': 'disabled'}
    current = status()
    if current.get('state') != 'awaiting-login':
        return {'skipped': current.get('state')}
    if (current.get('request') or {}).get('state') in ('queued', 'running', 'unknown'):
        return {'skipped': 'request'}
    return enqueue(engine.state, 'confirm', [])
