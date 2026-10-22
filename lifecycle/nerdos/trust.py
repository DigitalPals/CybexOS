"""Authenticated metadata; no Nix evaluation or privilege escalation here."""
import base64
import datetime as dt
import hashlib
import http.client
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

from .common import Failure, atomic, parse, read

API = 1
REPO = 'DigitalPals/NerdOS'
CHANNEL_BASE = f'https://digitalpals.github.io/{REPO.split("/")[1]}/channels'
SEMVER = re.compile(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(beta|rc)\.([1-9][0-9]*))?$')


def version(value):
    match = SEMVER.fullmatch(value) if isinstance(value, str) else None
    if not match:
        raise Failure('Invalid semantic release version')
    a, b, c, pre, number = match.groups()
    return int(a), int(b), int(c), {'beta': 0, 'rc': 1, None: 2}[pre], int(number or 0)


def https(url, hosts):
    p = urllib.parse.urlsplit(url)
    if p.scheme != 'https' or p.hostname not in hosts or p.username or p.password or p.fragment:
        raise Failure('Release URL is outside the trusted GitHub endpoints')
    return url


class Fetcher:
    def __init__(self, cache):
        self.cache = Path(cache)
        self.cache.mkdir(parents=True, exist_ok=True)

    def get(self, url, limit=2 * 1024 * 1024):
        https(url, {'digitalpals.github.io', 'github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com'})
        name = hashlib.sha256(url.encode()).hexdigest()
        body, meta = self.cache / name, self.cache / (name + '.json')
        old = read(meta, {})
        headers = {'User-Agent': 'NerdOS-updater/1', 'Accept': 'application/octet-stream'}
        if old.get('etag') and body.exists():
            headers['If-None-Match'] = old['etag']
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
                https(response.url, {'digitalpals.github.io', 'github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com'})
                data = response.read(limit + 1)
                if len(data) > limit:
                    raise Failure('Release response exceeds its size limit')
                atomic(body, data)
                atomic(meta, {'etag': response.headers.get('ETag', '')})
                return data
        except urllib.error.HTTPError as error:
            if error.code == 304 and body.exists():
                return body.read_bytes()
            if error.code in (403, 429):
                raise Failure('GitHub rate limit reached. Retry later; no account or token is required.') from error
            raise Failure(f'Release endpoint unavailable (HTTP {error.code}); its status is unknown.') from error
        except (urllib.error.URLError, http.client.HTTPException, TimeoutError, OSError) as error:
            raise Failure('Release endpoint unreachable; its status is unknown. Retry when connected.') from error


def verify(document, signature, trust, purpose):
    if len(document) > 2 * 1024 * 1024:
        raise Failure('Metadata exceeds its size limit')
    envelope = parse(signature)
    if not isinstance(envelope, dict) or set(envelope) != {'keyId', 'signature'}:
        raise Failure('Invalid signature envelope')
    if not isinstance(envelope['keyId'], str) or not isinstance(envelope['signature'], str):
        raise Failure('Invalid signature envelope types')
    key = trust.get('keys', {}).get(envelope['keyId'])
    if not key or purpose not in key.get('purposes', []):
        raise Failure('Publisher signing key is not trusted for this metadata')
    now = dt.datetime.now(dt.timezone.utc)
    try:
        end = timestamp(key['notAfter'])
        start = timestamp(key['notBefore']) if 'notBefore' in key else None
        if start is not None and start >= end:
            raise Failure('Publisher signing key has an invalid validity interval')
        if start is not None and now < start:
            raise Failure('Publisher signing key is not valid yet')
        if now >= end:
            raise Failure('Publisher signing key has expired')
        raw = base64.b64decode(envelope['signature'], validate=True)
        if len(raw) != 64:
            raise ValueError('signature length')
    except (KeyError, ValueError, TypeError) as error:
        raise Failure('Malformed signing key or signature') from error
    with tempfile.TemporaryDirectory(prefix='nerdos-signature-') as directory:
        directory = Path(directory)
        (directory / 'key').write_text(key['publicKey'])
        (directory / 'body').write_bytes(document)
        (directory / 'sig').write_bytes(raw)
        result = subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', str(directory / 'key'),
                                 '-rawin', '-in', str(directory / 'body'), '-sigfile', str(directory / 'sig')],
                                capture_output=True, timeout=10)
        if result.returncode:
            raise Failure('Invalid publisher signature; update rejected')
    return parse(document)


def timestamp(value):
    try:
        value = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if value.utcoffset() is None:
            raise ValueError('missing timezone')
        return value
    except (ValueError, TypeError, AttributeError) as error:
        raise Failure('Invalid metadata validity timestamp; a timezone is required') from error


def expiry(value):
    if dt.datetime.now(dt.timezone.utc) >= timestamp(value):
        raise Failure('Channel metadata expired; update status is unknown')


def validate_release(release, installed, architecture, nixos, channel):
    required = {'schema', 'version', 'revision', 'narHash', 'architectures', 'nixos', 'configurationApi',
                'pluginApi', 'minUpdater', 'notes', 'assets', 'vendorInputs'}
    if not isinstance(release, dict) or set(release) != required:
        raise Failure('Unsupported or incomplete release metadata')
    for name in ('schema', 'configurationApi', 'pluginApi', 'minUpdater'):
        if type(release[name]) is not int or release[name] < 1:
            raise Failure('Invalid release API metadata type')
    for name in ('architectures', 'nixos'):
        if not isinstance(release[name], list) or not release[name] or any(not isinstance(x, str) for x in release[name]):
            raise Failure('Invalid supported platform metadata')
    if release['schema'] != 1 or release['configurationApi'] != 1 or release['pluginApi'] != 1 or release['minUpdater'] > API:
        raise Failure('Release requires a newer updater or incompatible configuration/plugin API')
    if architecture not in release['architectures'] or nixos not in release['nixos']:
        raise Failure('Release does not support this architecture or NixOS release')
    selected_version = version(release['version'])
    if channel == 'stable' and '-' in release['version']:
        raise Failure('Stable channel contains a prerelease')
    if selected_version < version(installed):
        raise Failure('Channel downgrade rejected. Use explicit generation rollback instead.')
    if not isinstance(release['revision'], str) or not re.fullmatch(r'[0-9a-f]{40}', release['revision']):
        raise Failure('Release revision must be an exact Git commit')
    if not isinstance(release['narHash'], str) or not re.fullmatch(r'sha256-[A-Za-z0-9+/]{43}=', release['narHash']):
        raise Failure('Release source content identity is invalid')
    if not isinstance(release['notes'], str) or len(release['notes']) > 100000:
        raise Failure('Release notes are invalid')
    if not isinstance(release['vendorInputs'], list) or any(not isinstance(x, str) or not re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_-]*', x) for x in release['vendorInputs']):
        raise Failure('Invalid vendor dependency declaration')
    if not isinstance(release['assets'], list) or not release['assets']:
        raise Failure('Release assets are missing')
    names = set()
    for asset in release['assets']:
        if not isinstance(asset, dict) or set(asset) != {'name', 'url', 'sha256', 'bytes'}:
            raise Failure('Invalid release asset')
        if any(not isinstance(asset[x], str) for x in ('name', 'url', 'sha256')) or asset['name'] in names:
            raise Failure('Invalid or duplicate release asset')
        names.add(asset['name'])
        prefix = f'https://github.com/{REPO}/releases/download/v{release["version"]}/'
        if not asset['url'].startswith(prefix) or not re.fullmatch(r'[A-Za-z0-9._-]+', asset['name']) or asset['url'] != prefix + asset['name']:
            raise Failure('Asset does not belong to the selected immutable release')
        if not re.fullmatch('[0-9a-f]{64}', asset['sha256']) or type(asset['bytes']) is not int or asset['bytes'] < 1:
            raise Failure('Invalid asset identity')
    return release


def discover(fetch, trust, channel, installed, architecture, nixos, highest=0):
    if channel not in ('stable', 'beta'):
        raise Failure('Unknown release channel')
    base = f'{CHANNEL_BASE}/{channel}.json'
    channel_doc = verify(fetch.get(base), fetch.get(base + '.sig'), trust, 'channel')
    if not isinstance(channel_doc, dict) or set(channel_doc) != {'schema', 'channel', 'sequence', 'expires', 'manifest', 'sha256'} or type(channel_doc['schema']) is not int or channel_doc['schema'] != 1 or channel_doc['channel'] != channel:
        raise Failure('Invalid channel metadata')
    expiry(channel_doc['expires'])
    if type(channel_doc['sequence']) is not int or channel_doc['sequence'] < max(1, highest):
        raise Failure('Channel replay rejected')
    url = channel_doc['manifest']
    if not isinstance(url, str) or not re.fullmatch(rf'https://github.com/{re.escape(REPO)}/releases/download/v[0-9A-Za-z.-]+/manifest.json', url):
        raise Failure('Channel manifest URL is invalid')
    body = fetch.get(url)
    if hashlib.sha256(body).hexdigest() != channel_doc['sha256']:
        raise Failure('Release manifest content identity mismatch')
    release = verify(body, fetch.get(url + '.sig'), trust, 'release')
    validate_release(release, installed, architecture, nixos, channel)
    if url != f'https://github.com/{REPO}/releases/download/v{release["version"]}/manifest.json':
        raise Failure('Channel and release version disagree')
    return release, channel_doc['sequence']
