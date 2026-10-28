"""Source regression fixtures. These are not installation qualification."""
import copy
import contextlib
import hashlib
import http.server
import importlib.util
import importlib.machinery
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lifecycle'))
from cybexos.common import CommandFailure, Failure, Runner, atomic, digest, locked, parse, read, syncdir
from cybexos import inputs, trust
from cybexos.engine import Engine, config_digest, copy_config

REV_OLD, REV_NEW = '1' * 40, '2' * 40
NAR_OLD, NAR_NEW = 'sha256-' + 'A' * 43 + '=', 'sha256-' + 'B' * 43 + '='
OLD_SYSTEM = '/nix/store/' + 'a' * 32 + '-nixos-system-old'
NEW_SYSTEM = '/nix/store/' + 'b' * 32 + '-nixos-system-new'


def lock():
    return {'version': 7, 'root': 'root', 'nodes': {
        'root': {'inputs': {'nixpkgs': 'nixpkgs', 'cybexos': 'cybexos', 'personal': 'personal'}},
        'nixpkgs': {'original': {'type':'github','owner':'NixOS','repo':'nixpkgs','ref':'nixos-26.05'},
                    'locked': {'type':'github','owner':'NixOS','repo':'nixpkgs','rev':REV_OLD,'narHash':NAR_OLD}},
        'cybexos': {'inputs': {'nixpkgs':['nixpkgs'], 'lanzaboote':'lanzaboote'},
                   'original':{'type':'github','owner':'DigitalPals','repo':'CybexOS','rev':REV_OLD},
                   'locked':{'type':'github','owner':'DigitalPals','repo':'CybexOS','rev':REV_OLD,'narHash':NAR_OLD}},
        'lanzaboote': {'inputs':{'nixpkgs':['nixpkgs']},'locked':{'type':'github','repo':'lanzaboote','rev':REV_OLD}},
        'personal': {'inputs':{'nixpkgs':['nixpkgs']},'locked':{'type':'github','repo':'personal','rev':REV_OLD}}
    }}


def release():
    return {'schema':1,'version':'1.1.0','revision':REV_NEW,'narHash':NAR_NEW,
            'architectures':['x86_64-linux'],'nixos':['26.05'],'configurationApi':1,'pluginApi':1,
            'minUpdater':1,'notes':'A qualified release','vendorInputs':['lanzaboote'],
            'assets':[{'name':'source.tar.gz','url':'https://github.com/DigitalPals/CybexOS/releases/download/v1.1.0/source.tar.gz',
                       'sha256':'f'*64,'bytes':1}]}


class TrustTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.key = self.base / 'key'
        subprocess.run(['openssl','genpkey','-algorithm','Ed25519','-out',str(self.key)],check=True,capture_output=True)
        public = subprocess.check_output(['openssl','pkey','-in',str(self.key),'-pubout'],text=True)
        self.trust = {'keys':{'test':{'publicKey':public,'notAfter':'2099-01-01T00:00:00Z','purposes':['release','channel']}}}

    def sign(self, body):
        path=self.base / 'body';path.write_bytes(body)
        raw=subprocess.check_output(['openssl','pkeyutl','-sign','-rawin','-inkey',str(self.key),'-in',str(path)])
        import base64
        return json.dumps({'keyId':'test','signature':base64.b64encode(raw).decode()}).encode()

    def test_actual_ed25519_signature_and_exact_bytes(self):
        body=json.dumps(release()).encode(); sig=self.sign(body)
        self.assertEqual(trust.verify(body,sig,self.trust,'release'),release())
        with self.assertRaises(Failure): trust.verify(body+b' ',sig,self.trust,'release')
        with self.assertRaises(Failure): trust.verify(body,sig,{'keys':{}},'release')

    def test_only_an_unpublished_initial_channel_404_is_neutral(self):
        from urllib.error import HTTPError
        base = trust.CHANNEL_BASE + '/beta.json'
        with patch('urllib.request.urlopen', side_effect=HTTPError(base, 404, 'Not Found', {}, None)):
            fetch = trust.Fetcher(self.base / '404-cache')
            with self.assertRaises(trust.NoPublishedRelease):
                trust.discover(fetch, self.trust, 'beta', '1.0.0-beta.7', 'x86_64-linux', '26.05')
            with self.assertRaisesRegex(Failure, 'previously published'):
                trust.discover(fetch, self.trust, 'beta', '1.0.0-beta.7', 'x86_64-linux', '26.05', 1)
        class MissingSignature:
            def get(inner, url):
                if url == base:
                    return b'{}'
                raise trust.EndpointNotFound('missing signature')
        with self.assertRaises(trust.EndpointNotFound):
            trust.discover(MissingSignature(), self.trust, 'beta', '1.0.0-beta.7', 'x86_64-linux', '26.05')

    def test_interrupted_chunked_metadata_retains_cache_and_independent_upstream_result(self):
        class Interrupted(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def do_GET(self):
                self.send_response(200)
                self.send_header('Transfer-Encoding', 'chunked')
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(b'10\r\nshort')
                self.wfile.flush()
                self.close_connection = True
            def log_message(self, *args):
                pass
        endpoint = 'https://digitalpals.github.io/CybexOS/channels/stable.json'
        requests = []
        real_urlopen = urllib.request.urlopen
        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Interrupted) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            def transport(request, timeout=30):
                self.assertEqual(request.full_url, endpoint)
                requests.append(request.full_url)
                response = real_urlopen('http://127.0.0.1:' + str(server.server_port), timeout=timeout)
                # Adapt only the test transport. The production endpoint
                # checks, response reader and cache publication stay intact.
                response.url = request.full_url
                return response
            try:
                fetcher = trust.Fetcher(self.base / 'cache')
                cached = fetcher.cache / hashlib.sha256(endpoint.encode()).hexdigest()
                atomic(cached, b'previous complete cached metadata')
                with patch('cybexos.trust.urllib.request.urlopen', side_effect=transport):
                    with self.assertRaisesRegex(Failure, 'endpoint unreachable'):
                        fetcher.get(endpoint)
                    self.assertEqual(cached.read_bytes(), b'previous complete cached metadata')
                    working = self.base / 'configuration'; working.mkdir()
                    atomic(working / 'flake.lock', lock())
                    release_file = self.base / 'release.json'
                    atomic(release_file, {'version': '1.0.0', 'architecture': 'x86_64-linux', 'nixos': '26.05'})
                    policy = self.base / 'policy.json'; atomic(policy, {'channel': 'stable'})
                    keys = self.base / 'trust.json'; atomic(keys, {'keys': {}})
                    engine = Engine(self.base / 'state', working, FakeRunner(), release_file, policy, keys)
                    result = engine.check()
                self.assertEqual(result['upstream']['state'], 'available')
                self.assertEqual(result['cybexos']['state'], 'unavailable')
                self.assertIn('endpoint unreachable', result['cybexos']['error'])
                self.assertEqual(len(requests), 2, 'Exercise actual interrupted HTTP reads twice')
            finally:
                server.shutdown()
                thread.join(timeout=5)

    def test_expiry_and_purpose(self):
        body=b'{}';sig=self.sign(body)
        self.trust['keys']['test']['purposes']=['channel']
        with self.assertRaises(Failure): trust.verify(body,sig,self.trust,'release')
        self.trust['keys']['test']['notAfter']='2000-01-01T00:00:00Z'
        with self.assertRaises(Failure): trust.verify(body,sig,self.trust,'channel')

    def test_key_rotation_validity_start_and_malformed_dates(self):
        body=b'{}';sig=self.sign(body)
        key=self.trust['keys']['test']
        key['notBefore']='2000-01-01T00:00:00Z'
        self.assertEqual(trust.verify(body,sig,self.trust,'release'),{})
        for start in ['2098-01-01T00:00:00Z', '2099-01-01T00:00:00Z',
                      '2000-01-01', 'invalid', None]:
            key['notBefore']=start
            with self.subTest(start=start),self.assertRaises(Failure):
                trust.verify(body,sig,self.trust,'release')
        for value in ['2099-01-01', None]:
            with self.subTest(expiry=value),self.assertRaises(Failure):
                trust.expiry(value)

    def test_duplicate_fields_rejected(self):
        body=b'{"schema":1,"schema":2}'
        with self.assertRaises(Failure): trust.verify(body,self.sign(body),self.trust,'release')

    def test_metadata_compatibility_and_downgrades(self):
        for field, value in [('version','0.9.0'),('revision','main'),('narHash','sha256:checksum'),('minUpdater',2),('configurationApi',2),('pluginApi',2),('architectures',['aarch64-linux']),('nixos',['27.05'])]:
            data=release();data[field]=value
            with self.subTest(field=field),self.assertRaises(Failure):
                trust.validate_release(data,'1.0.0','x86_64-linux','26.05','stable')
        data=release();data['version']='1.1.0-beta.1'
        with self.assertRaises(Failure): trust.validate_release(data,'1.0.0','x86_64-linux','26.05','stable')

    def test_channel_manifest_chain_and_replay(self):
        body=json.dumps(release()).encode()
        url='https://github.com/DigitalPals/CybexOS/releases/download/v1.1.0/manifest.json'
        channel={'schema':1,'channel':'stable','sequence':4,'expires':'2099-01-01T00:00:00Z','manifest':url,'sha256':hashlib.sha256(body).hexdigest()}
        channel_body=json.dumps(channel).encode()
        base='https://digitalpals.github.io/CybexOS/channels/stable.json'
        data={base:channel_body,base+'.sig':self.sign(channel_body),url:body,url+'.sig':self.sign(body)}
        class Fetch:
            def get(self,url): return data[url]
        candidate, sequence=trust.discover(Fetch(),self.trust,'stable','1.0.0','x86_64-linux','26.05',4)
        self.assertEqual(sequence,4);self.assertEqual(candidate['revision'],REV_NEW)
        with self.assertRaises(Failure): trust.discover(Fetch(),self.trust,'stable','1.0.0','x86_64-linux','26.05',5)
        data[url]=body+b' '
        with self.assertRaises(Failure): trust.discover(Fetch(),self.trust,'stable','1.0.0','x86_64-linux','26.05',4)

    def test_asset_url_identity(self):
        for value in ['https://example.com/source.tar.gz','https://github.com/DigitalPals/CybexOS/releases/download/main/source.tar.gz']:
            data=release();data['assets'][0]['url']=value
            with self.assertRaises(Failure): trust.validate_release(data,'1.0.0','x86_64-linux','26.05','stable')


class InputTests(unittest.TestCase):
    def test_canonical_release_repository_and_locked_identity(self):
        inputs.validate_machine(lock())
        for part in ('original', 'locked'):
            for field, value in (('owner', 'another-publisher'), ('repo', 'Cybex OS')):
                data = lock()
                data['nodes']['cybexos'][part][field] = value
                with self.subTest(part=part, field=field), self.assertRaises(Failure):
                    inputs.validate_machine(data)

    def test_independent_scopes_and_vendor_dependencies(self):
        for scope in ('upstream','cybexos','both','local'):
            old=lock();new=copy.deepcopy(old)
            if scope in ('upstream','both'):new['nodes']['nixpkgs']['locked']['rev']=REV_NEW
            if scope in ('cybexos','both'):
                new['nodes']['cybexos']['locked']['rev']=REV_NEW
                new['nodes']['cybexos']['original']['rev']=REV_NEW
                new['nodes']['lanzaboote']['locked']['rev']=REV_NEW
            inputs.validate_delta(old,new,scope)
            new['nodes']['personal']['locked']['rev']=REV_NEW
            with self.subTest(scope=scope),self.assertRaises(Failure): inputs.validate_delta(old,new,scope)

    def test_duplicate_stale_upstream_and_major_upgrade(self):
        data=lock();data['nodes']['extra']=copy.deepcopy(data['nodes']['nixpkgs'])
        with self.assertRaises(Failure):inputs.validate_machine(data)
        data=lock();data['nodes']['nixpkgs']['original']['ref']='nixos-unstable'
        with self.assertRaises(Failure):inputs.validate_machine(data)
        data=lock();data['nodes']['cybexos']['inputs']['nixpkgs']='nixpkgs'
        with self.assertRaises(Failure):inputs.validate_machine(data)

    def test_upstream_does_not_move_vendor_or_personal_graphs(self):
        data=lock();new=copy.deepcopy(data);new['nodes']['cybexos']['locked']['rev']=REV_NEW
        with self.assertRaises(Failure):inputs.validate_delta(data,new,'upstream')

    def test_vendor_moving_ref_and_changed_revision_refused(self):
        for mutate in ('branch', 'mismatch'):
            data = lock()
            if mutate == 'branch':
                data['nodes']['cybexos']['original'].pop('rev')
                data['nodes']['cybexos']['original']['ref'] = 'main'
            else:
                data['nodes']['cybexos']['locked']['rev'] = REV_NEW
            with self.subTest(mutate=mutate), self.assertRaises(Failure):
                inputs.validate_machine(data)


class FakeRunner:
    """Command-boundary fixture; deliberately not called end-to-end evidence."""
    log=None
    def __init__(self):self.calls=[];self.fail=None
    def __call__(self,*args,**kwargs):
        args=tuple(map(str,args));self.calls.append(args)
        if self.fail and self.fail(args):raise Failure('injected command failure')
        if args[:3]==('nix','flake','update'):
            scope=args[3];config=Path(args[args.index('--flake')+1].removeprefix('path:'))
            data=read(config/'flake.lock')
            data['nodes'][scope]['locked'].update({'rev':REV_NEW,'narHash':NAR_NEW})
            if scope == 'cybexos':
                data['nodes'][scope]['original']['rev'] = REV_NEW
            atomic(config/'flake.lock',data)
        if args[:3]==('nix','flake','archive'):
            return json.dumps({'path':'/nix/store/'+'c'*32+'-config','inputs':{'nixpkgs':{'path':'/nix/store/'+'d'*32+'-source','inputs':{}}}})
        if args[:3]==('nix','flake','prefetch'):
            return json.dumps({'hash': NAR_NEW, 'storePath': '/nix/store/' + 'e'*32 + '-source'})
        if args[:2]==('nix','build'):return json.dumps([{'outputs':{'out':NEW_SYSTEM}}])
        if args[:3]==('nix','store','diff-closures'):return 'hello: 1 → 2\n'
        if args[0] == 'cat' and args[1].endswith('/etc/cybexos/software.json'):
            newer = args[1].startswith(NEW_SYSTEM)
            return json.dumps({'schema': 1, 'packages': [
                {'name': 'hello', 'version': '2' if newer else '1',
                 'path': '/nix/store/' + ('f' if newer else 'e') * 32 + '-hello',
                 'description': 'A friendly application'}]})
        if args[0] == 'cat' and args[1].endswith('/etc/cybexos/components.json'):
            newer = args[1].startswith(NEW_SYSTEM)
            return json.dumps({'schema': 1, 'components': {'kernel': '6.12.58' if newer else '6.12.55',
                                                           'nixos': '26.05.20261024.abcdef1'}})
        if args[:3]==('nix','flake','metadata'):return json.dumps({'locked':{'rev':REV_NEW}})
        if args[:2]==('systemctl','list-units'):
            if args != ('systemctl','list-units','--state=failed,auto-restart','--all','--output=json','--no-pager'):
                raise AssertionError('Unexpected systemctl list command: ' + repr(args))
            return '[]'
        return ''


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        base=Path(self.temp.name);self.base=base
        self.config=base/'config';self.config.mkdir()
        atomic(self.config/'flake.lock',lock())
        (self.config/'flake.nix').write_text('cybexos.url = "github:DigitalPals/CybexOS/'+REV_OLD+'";')
        (self.config/'local').mkdir();(self.config/'local/personal.nix').write_text('# packages, VPN, services sentinel\n{}')
        self.working=base/'nixos';self.working.symlink_to(self.config)
        self.system=base/'current-system';self.system.symlink_to(OLD_SYSTEM)
        self.booted=base/'booted-system';self.booted.symlink_to(OLD_SYSTEM)
        self.release=base/'release.json';atomic(self.release,{'version':'1.0.0','architecture':'x86_64-linux','nixos':'26.05'})
        self.policy=base/'update.json';atomic(self.policy,{'channel':'stable'})
        self.runner=FakeRunner()
        self.engine=Engine(base/'state',self.working,self.runner,self.release,self.policy,base/'trust.json',self.system,self.booted)
        copy_config(self.config,base/'deployed');(self.engine.state/'deployed').symlink_to(base/'deployed')
        self.engine.channel=lambda:(release(),4)
        self.sentinel=config_digest(self.config)
        self.personal=base/'personal-data';self.personal.write_text('VPN key, widgets, preferences, plugin data and service database sentinel')

    def test_upstream_vendor_combined_and_local_staging(self):
        for scope in ('upstream','cybexos','both','local'):
            record=self.engine.stage(scope)
            self.assertEqual(config_digest(self.config),self.sentinel)
            new=read(self.engine.tx(record['id'])/'config/flake.lock')
            self.assertEqual(inputs.identity(new,'nixpkgs')['rev'],REV_NEW if scope in ('upstream','both') else REV_OLD)
            self.assertEqual(inputs.identity(new,'cybexos')['rev'],REV_NEW if scope in ('cybexos','both') else REV_OLD)
            self.assertEqual(inputs.identity(new,'personal')['rev'],REV_OLD)
            self.assertEqual(read(self.engine.status_path)['state'],'ready')

    def test_region_preview_preserves_working_and_other_preferences(self):
        atomic(self.config / 'desktop-settings.json', {'locale': 'en_US.UTF-8'})
        baseline = config_digest(self.working)
        original = self.engine.run
        def run(*args, **kwargs):
            if args == ('timedatectl', 'list-timezones', '--no-pager'):
                return 'UTC\nEurope/Amsterdam\n'
            if args == ('timedatectl', 'show', '--property=Timezone', '--value'):
                return 'UTC\n'
            if args[:3] == ('nix', 'eval', '--json'):
                return '"Europe/Amsterdam"'
            return original(*args, **kwargs)
        self.engine.run = run
        record = self.engine.stage('local', region={'field': 'timezone', 'value': 'Europe/Amsterdam', 'previous': 'UTC'})
        staged = read(self.engine.tx(record['id']) / 'config/desktop-settings.json')
        self.assertEqual(staged, {'locale': 'en_US.UTF-8', 'timezone': 'Europe/Amsterdam'})
        self.assertEqual(config_digest(self.working), baseline)
        with self.assertRaises(Failure):
            self.engine.stage('local', region={'field': 'timezone', 'value': 'Europe/Amsterdam', 'previous': 'wrong'})
        def overridden(*args, **kwargs):
            if args[:3] == ('nix', 'eval', '--json'):
                return '"UTC"'
            return run(*args, **kwargs)
        self.engine.run = overridden
        with self.assertRaisesRegex(Failure, 'stronger NixOS declaration'):
            self.engine.stage('local', region={'field': 'timezone', 'value': 'Europe/Amsterdam', 'previous': 'UTC'})
        self.assertEqual(read(self.engine.status_path)['state'], 'failed')
        self.assertEqual(config_digest(self.working), baseline)

    def test_locale_preview_reads_archive_and_keeps_regional_categories(self):
        atomic(self.config / 'desktop-settings.json', {'timezone': 'UTC'})
        baseline = config_digest(self.working)
        previous = ['LANG=en_US.UTF-8', 'LC_TIME=nl_NL.UTF-8']
        original = self.engine.run
        def run(*args, **kwargs):
            if args == ('locale', '-a'):
                return 'C\nC.utf8\nen_US.utf8\nnl_NL.utf8\nPOSIX\n'
            if args == ('busctl', '--system', '--json=short', 'get-property',
                        'org.freedesktop.locale1', '/org/freedesktop/locale1',
                        'org.freedesktop.locale1', 'Locale'):
                return json.dumps({'type': 'as', 'data': previous})
            if args[:3] == ('nix', 'eval', '--json'):
                self.assertTrue(str(args[-1]).endswith('.i18n.defaultLocale'))
                return '"nl_NL.UTF-8"'
            return original(*args, **kwargs)
        self.engine.run = run
        record = self.engine.stage('local', region={'field':'locale','value':'nl_NL.UTF-8','previous':previous})
        self.assertEqual(read(self.engine.tx(record['id']) / 'config/desktop-settings.json'),
                         {'timezone':'UTC','locale':'nl_NL.UTF-8'})
        self.assertEqual(config_digest(self.working), baseline)

    def test_locale_preview_matches_localed_normalization_and_rejects_stale_snapshot(self):
        from cybexos.configuration import region
        atomic(self.config / 'desktop-settings.json', {})
        previous = ['LANG=nl_NL.UTF-8']
        def run(*args):
            if args == ('locale', '-a'):
                return 'nl_NL.utf8\nen_GB.utf8\n'
            self.assertEqual(args, ('busctl', '--system', '--json=short', 'get-property',
                                   'org.freedesktop.locale1', '/org/freedesktop/locale1',
                                   'org.freedesktop.locale1', 'Locale'))
            return json.dumps({'type': 'as', 'data': previous})
        real_open = open
        def open_locale(path, *args, **kwargs):
            if str(path) == '/etc/locale.conf':
                return io.StringIO('LANG=nl_NL.UTF-8\nLC_TIME=nl_NL.UTF-8\n')
            return real_open(path, *args, **kwargs)
        request = {'field': 'locale', 'value': 'en_GB.UTF-8', 'previous': previous.copy()}
        with patch('builtins.open', side_effect=open_locale):
            region(self.config, request, run)
        self.assertEqual(read(self.config / 'desktop-settings.json'), {'locale': 'en_GB.UTF-8'})
        previous.append('LC_TIME=en_US.UTF-8')
        with self.assertRaisesRegex(Failure, 'current regional setting changed'):
            region(self.config, request, run)

    def test_nixos_service_warning_does_not_wedge_apply_or_rollback(self):
        original = self.engine.run
        def run(*args, **kwargs):
            if args[0].endswith('/bin/switch-to-configuration'):
                original.calls.append(tuple(args))
                raise CommandFailure(args[0], 4)
            return original(*args, **kwargs)
        run.log = None
        self.engine.run = run
        record = self.engine.stage('upstream')
        self.engine.apply(record['id'], record['reviewToken'])
        self.assertEqual(read(self.engine.status_path)['state'], 'awaiting-boot')
        self.assertIn((NEW_SYSTEM + '/sw/bin/cybexos-health', 'system'), original.calls)
        original.calls.clear()
        self.engine.rollback(record['id'])
        self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
        self.assertFalse(self.engine.pending_path.exists())
        self.assertIn((OLD_SYSTEM + '/sw/bin/cybexos-health', 'system'), original.calls)
        disarm = original.calls.index(('cybexos-boot-trial', '--disarm'))
        install = original.calls.index((OLD_SYSTEM + '/bin/switch-to-configuration', 'boot'))
        self.assertLess(disarm, install)
        self.assertLess(install, original.calls.index(('cybexos-boot-trial', '--restore', OLD_SYSTEM)))

    def test_preexisting_failed_unit_is_tolerated_but_new_failures_are_rejected(self):
        for code in (0, 4):
            with self.subTest(code=code):
                original = self.runner
                switched = False
                def run(*args, **kwargs):
                    nonlocal switched
                    if args[:2] == ('systemctl', 'list-units'):
                        units = ['preexisting.service'] + (['personal-vpn.service'] if switched else [])
                        return json.dumps([{'unit': unit, 'sub': 'failed'} for unit in units])
                    if args == (NEW_SYSTEM + '/bin/switch-to-configuration', 'test'):
                        switched = True
                        if code:
                            raise CommandFailure(args[0], code, 'warning: the following units failed: personal-vpn.service')
                    return original(*args, **kwargs)
                run.log = None
                self.engine.run = run
                record = self.engine.stage('upstream')
                with self.assertRaisesRegex(Failure, 'personal-vpn.service'):
                    self.engine.apply(record['id'], record['reviewToken'])
                self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
                self.assertFalse(self.engine.pending_path.exists())
                atomic(self.engine.tx(record['id']) / 'retry-authorized.json', {})

    def test_preexisting_failed_unit_does_not_block_a_healthy_candidate(self):
        original = self.runner
        def run(*args, **kwargs):
            if args[:2] == ('systemctl', 'list-units'):
                return '[{"unit":"preexisting.service","sub":"failed"}]'
            if args[0].endswith('/bin/switch-to-configuration'):
                raise CommandFailure(args[0], 4, 'warning: the following units failed: preexisting.service')
            return original(*args, **kwargs)
        run.log = None
        self.engine.run = run
        record = self.engine.stage('upstream')
        self.engine.apply(record['id'], record['reviewToken'])
        self.assertEqual(read(self.engine.status_path)['state'], 'awaiting-boot')

    def test_real_systemctl_accepts_snapshot_options(self):
        # Exercise the packaged option parser without accessing the host bus.
        # --help still rejects unknown options (such as systemctl --json).
        actual = Runner()
        def option_probe(*args):
            actual(*args, '--help')
            return '[]'
        self.engine.run = option_probe
        self.assertEqual(self.engine.failed_units(), set())

    def test_new_crash_loop_is_rejected_but_successful_restart_always_is_allowed(self):
        original = self.runner
        exit_status = '0'
        switched = False
        def run(*args, **kwargs):
            nonlocal switched
            if args[:2] == ('systemctl', 'list-units'):
                return json.dumps([{'unit': 'periodic.service', 'sub': 'auto-restart'}]
                                  if switched else [])
            if args[:2] == ('systemctl', 'show'):
                self.assertEqual(args, ('systemctl', 'show', '--property=ExecMainStatus', '--value', 'periodic.service'))
                return exit_status + '\n'
            if args == (NEW_SYSTEM + '/bin/switch-to-configuration', 'test'):
                switched = True
                raise CommandFailure(args[0], 4, 'warning: periodic.service is restarting')
            return original(*args, **kwargs)
        run.log = None
        self.engine.run = run
        record = self.engine.stage('upstream')
        self.engine.apply(record['id'], record['reviewToken'])
        self.assertEqual(read(self.engine.status_path)['state'], 'awaiting-boot')
        self.engine.rollback(record['id'])
        atomic(self.engine.tx(record['id']) / 'retry-authorized.json', {})
        switched = False
        exit_status = '1'
        record = self.engine.stage('upstream')
        with self.assertRaisesRegex(Failure, 'periodic.service'):
            self.engine.apply(record['id'], record['reviewToken'])
        self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
        self.assertFalse(self.engine.pending_path.exists())

    def test_rollback_recreates_a_pruned_boot_entry_before_selecting_it(self):
        record = self.engine.stage('upstream')
        original = self.runner
        entry_exists = False
        def run(*args, **kwargs):
            nonlocal entry_exists
            if args == (OLD_SYSTEM + '/bin/switch-to-configuration', 'boot'):
                entry_exists = True
            if args == ('cybexos-boot-trial', '--restore', OLD_SYSTEM) and not entry_exists:
                raise Failure('No bootable GRUB entry')
            return original(*args, **kwargs)
        run.log = None
        self.engine.run = run
        self.engine.rollback(record['id'])
        self.assertTrue(entry_exists)
        self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
        self.assertFalse(self.engine.pending_path.exists())
        self.assertLess(original.calls.index(('cybexos-boot-trial', '--disarm')),
                        original.calls.index((OLD_SYSTEM + '/bin/switch-to-configuration', 'boot')))

    def test_rollback_disarms_before_personal_backup_can_fail(self):
        record = self.engine.stage('upstream')
        (self.config / 'result').symlink_to(NEW_SYSTEM)
        with self.assertRaisesRegex(Failure, 'link or special file'):
            self.engine.rollback(record['id'])
        self.assertIn(('cybexos-boot-trial', '--disarm'), self.runner.calls)
        self.assertNotIn((OLD_SYSTEM + '/bin/switch-to-configuration', 'boot'), self.runner.calls)
        self.assertEqual(read(self.engine.status_path)['state'], 'recovery-failed')
        (self.config / 'result').unlink()
        self.engine.rollback(record['id'])
        self.assertFalse(self.engine.pending_path.exists())

    def test_activation_warning_still_rejects_failed_required_health(self):
        original = self.engine.run
        def run(*args, **kwargs):
            if args[0].endswith('/bin/switch-to-configuration'):
                raise CommandFailure(args[0], 4)
            if args == (NEW_SYSTEM + '/sw/bin/cybexos-health', 'system'):
                raise Failure('required personal.service failed')
            return original(*args, **kwargs)
        run.log = None
        self.engine.run = run
        record = self.engine.stage('upstream')
        with self.assertRaisesRegex(Failure, 'required personal.service'):
            self.engine.apply(record['id'], record['reviewToken'])
        self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
        self.assertFalse(self.engine.pending_path.exists())

    def test_real_runner_exposes_exit_codes_and_only_switch_warning_is_accepted(self):
        system = self.base / 'system'; (system / 'bin').mkdir(parents=True)
        command = system / 'bin/switch-to-configuration'
        command.write_text('#!' + sys.executable + '\nimport sys; sys.exit(int(sys.argv[1]))\n')
        command.chmod(0o700)
        self.engine.run = Runner()
        self.engine.switch(str(system), '4')
        for code in (1, 2, 3, 5):
            with self.subTest(code=code), self.assertRaises(CommandFailure) as raised:
                self.engine.switch(str(system), str(code))
            self.assertEqual(raised.exception.returncode, code)
        with self.assertRaises(CommandFailure):
            self.engine.run(str(command), '4')

    def test_real_runner_rejects_activation_script_errors_masked_by_exit_four(self):
        system = self.base / 'system'; (system / 'bin').mkdir(parents=True)
        command = system / 'bin/switch-to-configuration'
        command.write_text('#!' + sys.executable + '\nimport sys; print(sys.argv[1],file=sys.stderr); sys.exit(4)\n')
        command.chmod(0o700)
        self.engine.run = Runner()
        for message in ('Failed to run activate script', "Activation script snippet 'etc' failed (1)"):
            with self.subTest(message=message), self.assertRaises(CommandFailure) as raised:
                self.engine.switch(str(system), message)
            self.assertIn(message, raised.exception.output)
            self.assertNotIn(message, str(raised.exception), 'Public errors must not expose private command diagnostics')

    def test_masked_activation_error_restores_even_if_declared_health_would_pass(self):
        original = self.runner
        def run(*args, **kwargs):
            if args[:2] == ('systemctl', 'list-units'):
                return '[{"unit":"preexisting.service","sub":"failed"}]'
            if args == (NEW_SYSTEM + '/bin/switch-to-configuration', 'test'):
                raise CommandFailure(args[0], 4, 'warning: Failed to run activate script\nwarning: the following units failed: preexisting.service')
            return original(*args, **kwargs)
        run.log = None
        self.engine.run = run
        record = self.engine.stage('upstream')
        with self.assertRaises(CommandFailure):
            self.engine.apply(record['id'], record['reviewToken'])
        self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
        self.assertFalse(self.engine.pending_path.exists())
        self.assertNotIn((NEW_SYSTEM + '/sw/bin/cybexos-health', 'system'), original.calls)

    def test_busy_boot_recovery_defers_to_the_lock_owner_without_failure(self):
        self.engine.status(state='building')
        with locked(self.engine.state / 'operation.lock'):
            self.engine.recover()
            self.assertEqual(read(self.engine.status_path)['state'], 'building')
            with self.assertRaises(Failure):
                self.engine.stage('upstream')
        self.engine.recover()
        self.assertEqual(read(self.engine.status_path)['state'], 'interrupted')

    def test_retry_request_authorizes_the_same_system_across_failed_transactions(self):
        import contextlib
        import io
        from cybexos import cli
        ids = ['1' * 32, '2' * 32, '3' * 32]
        for identifier, system in zip(ids, [NEW_SYSTEM, NEW_SYSTEM, OLD_SYSTEM]):
            tx = self.engine.tx(identifier)
            atomic(tx / 'deployment.json', {'id': identifier, 'system': system})
            atomic(tx / 'failed.json', {'reason': 'failed health'})
        output = io.StringIO()
        with patch.object(cli, 'Path', return_value=self.engine.state), patch.object(cli.os, 'geteuid', return_value=0), patch.object(sys, 'argv', ['request', 'retry-failed', ids[0]]), contextlib.redirect_stdout(output):
            cli.request()
        self.assertEqual(set(json.loads(output.getvalue())['sameSystemDeployments']), set(ids[:2]))
        for identifier in ids[:2]:
            self.assertTrue((self.engine.tx(identifier) / 'retry-authorized.json').is_file())
        self.assertFalse((self.engine.tx(ids[2]) / 'retry-authorized.json').exists())

    def test_failed_preview_does_not_consume_explicit_retry_authorization(self):
        record = self.engine.stage('upstream')
        self.runner.fail = lambda args: args == (NEW_SYSTEM + '/sw/bin/cybexos-health', 'system')
        with self.assertRaises(Failure):
            self.engine.apply(record['id'], record['reviewToken'])
        authorization = self.engine.tx(record['id']) / 'retry-authorized.json'
        atomic(authorization, {'authorizedAt': 1})
        self.runner.fail = lambda args: 'cybexos-desktop-check' in args[0]
        with self.assertRaises(Failure):
            self.engine.stage('upstream')
        self.assertTrue(authorization.exists())
        self.runner.fail = None
        self.engine.stage('upstream')
        self.assertFalse(authorization.exists())

    def test_channel_unavailable_does_not_block_upstream(self):
        def fail():raise Failure('channel unreachable')
        self.engine.channel=fail
        self.engine.stage('upstream')
        self.assertEqual(read(self.engine.status_path)['state'],'ready')
        with self.assertRaises(Failure):self.engine.stage('both')
        result=self.engine.check()
        self.assertEqual(result['upstream']['state'],'available')
        self.assertEqual(result['cybexos']['state'],'unavailable')

    def test_unpublished_channel_has_no_error_and_never_blocks_upstream(self):
        self.engine.channel = lambda: (_ for _ in ()).throw(trust.NoPublishedRelease('No release yet'))
        result = self.engine.check()
        self.assertEqual(result['cybexos'], {'state': 'unpublished', 'installed': '1.0.0'})
        self.assertEqual(result['upstream']['state'], 'available')
        record = self.engine.stage('upstream')
        self.assertEqual(read(self.engine.status_path)['state'], 'ready')
        selected = read(self.engine.tx(record['id']) / 'config/flake.lock')
        self.assertEqual(inputs.identity(selected, 'cybexos')['rev'], REV_OLD)
        self.assertEqual(inputs.identity(selected, 'personal')['rev'], REV_OLD)
        with self.assertRaises(trust.NoPublishedRelease):
            self.engine.stage('both')

    def assert_unknown_upstream(self, result, reason):
        self.assertEqual(result['upstream']['state'], 'unreachable')
        error = result['upstream']['error']
        self.assertIn('Nixpkgs (nixos-26.05) package-source status is unknown.', error)
        self.assertIn(reason, error)
        self.assertIn('`nix flake metadata --refresh --json github:NixOS/nixpkgs/nixos-26.05`', error)
        self.assertNotIn('transaction log', error)
        self.assertNotIn('cybex update log', error)
        self.assertNotIn('available', result['upstream'])
        self.assertEqual(result['cybexos']['state'], 'available')
        self.assertEqual(result['cybexos']['available'], '1.1.0')
        self.assertFalse(self.engine.status_path.exists())
        self.assertEqual(list((self.engine.state / 'transactions').iterdir()), [])
        self.assertEqual(config_digest(self.config), self.sentinel)

    def test_check_classifies_actual_runner_output_without_exposing_or_logging_secrets(self):
        secret = 'CANARY_DISCOVERY_TOKEN_27_x9F'
        private = 'Authorization: Bearer ' + secret + '\nNIX_CONFIG=access-tokens = github.com=' + secret
        endpoint = "error: unable to download 'https://api.github.com/repos/NixOS/nixpkgs/commits/nixos-26.05': "
        cases = (
            (endpoint + 'HTTP error 403\nresponse body: {"message":"API rate limit exceeded for 192.0.2.1"}',
             'GitHub API rate limit reached.'),
            (endpoint + 'HTTP error 403\nYou have exceeded a secondary rate limit.',
             'GitHub API rate limit reached.'),
            (endpoint + 'HTTP error 429', 'rate limited the request (HTTP 429)'),
            (endpoint + 'HTTP error 403\nForbidden', 'denied access (HTTP 403)'),
            ("error: unable to download 'https://cache.nixos.org/': HTTP error 403\nAPI rate limit exceeded",
             'denied access (HTTP 403)'),
            (endpoint + 'HTTP error 503\nService Unavailable', 'server error (HTTP 5xx)'),
            (endpoint + 'HTTP/2 502', 'server error (HTTP 5xx)'),
            (endpoint + 'Could not resolve host: api.github.com', 'hostname resolution failed'),
            (endpoint + 'SSL certificate problem: certificate verify failed', 'TLS connection failed'),
            (endpoint + 'Failed to connect to api.github.com port 443: Connection refused', 'connection failed'),
            (endpoint + 'Timeout was reached', 'metadata lookup timed out'),
            ('error: metadata evaluation failed (unrelated numbers 403, 429)', 'metadata lookup failed'),
        )
        log = self.base / 'discovery.log'
        log.write_text('previous transaction diagnostics\n')
        program = 'import sys; print(sys.argv[1]); print(sys.argv[2], file=sys.stderr); sys.exit(1)'
        for output, reason in cases:
            for log_path in (None, log):
                runner = Runner(log_path)
                def run(*args, **kwargs):
                    self.assertEqual(args, ('nix', 'flake', 'metadata', '--refresh', '--json',
                                            'github:NixOS/nixpkgs/nixos-26.05'))
                    self.assertEqual(kwargs, {'timeout': 90, 'sensitive': True})
                    try:
                        return runner(sys.executable, '-B', '-c', program, private, output + '\n' + private, **kwargs)
                    except CommandFailure as error:
                        self.assertIn(secret, error.output, 'Exercise actual captured private diagnostics')
                        self.assertNotIn(secret, str(error))
                        raise
                self.engine.run = run
                stdout, stderr = io.StringIO(), io.StringIO()
                with self.subTest(output=output, log=log_path), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    with patch.object(self.engine, 'channel', return_value=(release(), 4)) as channel:
                        result = self.engine.check()
                    channel.assert_called_once_with()
                    self.assert_unknown_upstream(result, reason)
                    public = json.dumps(result) + stdout.getvalue() + stderr.getvalue()
                    for private_text in (secret, 'Authorization:', 'NIX_CONFIG', output):
                        self.assertNotIn(private_text, public)
                    if 'denied access' in reason:
                        self.assertNotIn('rate limit', result['upstream']['error'])
                    self.assertEqual(log.read_text(), 'previous transaction diagnostics\n')
                    for path in self.engine.state.rglob('*'):
                        if path.is_file():
                            self.assertNotIn(secret.encode(), path.read_bytes())

    def test_check_timeout_and_general_failures_use_safe_static_guidance(self):
        secret = 'CANARY_DISCOVERY_FAILURE_27_x9F'
        cases = (
            (TimeoutError(secret), 'metadata lookup timed out'),
            (subprocess.TimeoutExpired(['nix', secret], 90, output=secret, stderr=secret), 'metadata lookup timed out'),
            (Failure('nix timed out; inspect the transaction log and retry.'), 'metadata lookup timed out'),
            (Failure(secret), 'metadata lookup failed'),
            (FileNotFoundError(secret), 'metadata lookup could not run'),
        )
        for error, reason in cases:
            with self.subTest(error=type(error).__name__), patch.object(self.engine, 'run', side_effect=error) as run:
                result = self.engine.check()
                self.assert_unknown_upstream(result, reason)
                self.assertNotIn(secret, json.dumps(result))
                run.assert_called_once_with('nix', 'flake', 'metadata', '--refresh', '--json',
                                            'github:NixOS/nixpkgs/nixos-26.05', timeout=90, sensitive=True)

    def test_check_actual_runner_deadline_does_not_recommend_a_deployment_log(self):
        runner = Runner()
        # Exercise Runner's executable-specific timeout wording using Python,
        # without invoking Nix or waiting for the real discovery deadline.
        command = self.base / 'nix'
        command.symlink_to(sys.executable)
        def run(*args, **kwargs):
            with patch('cybexos.common.time.monotonic', side_effect=(0, 91)):
                return runner(command, '-B', '-c', 'pass', **kwargs)
        self.engine.run = run
        self.assert_unknown_upstream(self.engine.check(), 'metadata lookup timed out')

    def test_check_actual_runner_invalid_utf8_still_checks_the_vendor_without_leaks(self):
        secret = 'CANARY_DISCOVERY_ENCODING_x9F'
        log = self.base / 'discovery.log'
        log.write_text('previous transaction diagnostics\n')
        runner = Runner(log)
        program = 'import sys; sys.stdout.buffer.write(b"\\xff" + sys.argv[1].encode()); sys.stderr.write(sys.argv[1])'
        def run(*args, **kwargs):
            self.assertEqual(kwargs, {'timeout': 90, 'sensitive': True})
            return runner(sys.executable, '-B', '-c', program, secret, **kwargs)
        self.engine.run = run
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with patch.object(self.engine, 'channel', return_value=(release(), 4)) as channel:
                result = self.engine.check()
        channel.assert_called_once_with()
        self.assert_unknown_upstream(result, 'malformed package-source metadata')
        self.assertNotIn(secret, json.dumps(result) + stdout.getvalue() + stderr.getvalue())
        self.assertEqual(log.read_text(), 'previous transaction diagnostics\n')

    def test_check_malformed_metadata_remains_unknown_and_private(self):
        secret = 'CANARY_DISCOVERY_METADATA_27_x9F'
        documents = [json.dumps(value) for value in (
            None, False, 0, [], {}, {'locked': None}, {'locked': []}, {'locked': {}},
            {'locked': {'rev': None}}, {'locked': {'rev': 123}}, {'locked': {'rev': []}},
            {'locked': {'rev': secret}}, {'locked': {'rev': ''}}, {'locked': {'rev': 'a' * 39}},
        )]
        documents += [secret, '{"locked":{"rev":"' + REV_OLD + '"},"locked":{"rev":"' + secret + '"}}']
        for document in documents:
            with self.subTest(document=document), patch.object(self.engine, 'run', return_value=document):
                result = self.engine.check()
                self.assert_unknown_upstream(result, 'malformed package-source metadata')
                self.assertNotIn(secret, json.dumps(result))

    def test_check_valid_revisions_preserve_public_fields(self):
        for revision, state in ((REV_OLD, 'current'), (REV_NEW, 'available')):
            with self.subTest(state=state), patch.object(self.engine, 'run', return_value=json.dumps({'locked': {'rev': revision}})):
                result = self.engine.check()
                self.assertEqual(result['upstream'], {
                    'state': state, 'installed': REV_OLD, 'available': revision,
                    'detail': 'Stage upstream to build and review actual package changes.',
                })
                self.assertEqual(result['cybexos']['state'], 'available')

    def test_check_reports_both_source_failures_independently(self):
        with patch.object(self.engine, 'run', side_effect=Failure('lookup failed')):
            with patch.object(self.engine, 'channel', side_effect=Failure('Release endpoint unreachable; its status is unknown.')) as channel:
                result = self.engine.check()
        channel.assert_called_once_with()
        self.assertEqual(result['upstream']['state'], 'unreachable')
        self.assertIn('Nixpkgs (nixos-26.05)', result['upstream']['error'])
        self.assertEqual(result['cybexos']['state'], 'unavailable')
        self.assertIn('Release endpoint unreachable', result['cybexos']['error'])

    def test_evaluation_build_and_runtime_check_failure_preserve_working(self):
        for needle in ('build','cybexos-desktop-check','archive'):
            self.runner.fail=lambda args:needle in ' '.join(args)
            with self.subTest(boundary=needle),self.assertRaises(Failure):self.engine.stage('upstream')
            self.assertEqual(config_digest(self.config),self.sentinel)
            self.assertEqual(self.system.readlink(),Path(OLD_SYSTEM))
            self.assertFalse(self.engine.pending_path.exists())
            self.assertEqual(read(self.engine.status_path)['state'],'failed')

    def test_identity_mismatch_rejected_before_build(self):
        self.engine.channel=lambda:(release()|{'narHash':NAR_OLD},4)
        with self.assertRaises(Failure):self.engine.stage('cybexos')
        self.assertFalse(any(args[:2]==('nix','build') for args in self.runner.calls))

    def test_stale_review_and_personal_edits(self):
        record=self.engine.stage('upstream')
        with self.assertRaises(Failure):self.engine.apply(record['id'],'0'*64)
        (self.config/'local/new.nix').write_text('{}')
        with self.assertRaises(Failure):self.engine.apply(record['id'],record['reviewToken'])
        self.assertTrue((self.config/'local/new.nix').exists())

    def test_personal_executable_survives_staging_and_selection(self):
        script = self.config / 'local/personal-service'
        script.write_text('#!' + sys.executable + '\nprint("personal-service-preserved", end="")\n')
        script.chmod(0o751)
        baseline = config_digest(self.working)
        record = self.engine.stage('local')
        staged = self.engine.tx(record['id']) / 'config/local/personal-service'
        self.assertEqual(staged.stat().st_mode & 0o777, 0o755)
        self.assertEqual(config_digest(self.engine.tx(record['id']) / 'config'), baseline)
        self.engine.apply(record['id'], record['reviewToken'])
        selected = self.working / 'local/personal-service'
        self.assertEqual(subprocess.check_output([str(selected)], text=True), 'personal-service-preserved')
        self.assertEqual((self.working / 'local/personal.nix').stat().st_mode & 0o777, 0o644)

    def test_executable_bit_change_invalidates_review(self):
        script = self.config / 'local/personal-service'
        script.write_text('#!/bin/sh\nexit 0\n')
        script.chmod(0o644)
        record = self.engine.stage('local')
        script.chmod(0o755)
        with self.assertRaisesRegex(Failure, 'configuration changed after preparation'):
            self.engine.apply(record['id'], record['reviewToken'])
        self.assertFalse(self.engine.pending_path.exists())
        self.assertEqual(script.stat().st_mode & 0o777, 0o755)

    def test_post_preview_symlink_with_identical_bytes_is_rejected(self):
        original = (self.config / 'local/personal.nix').read_bytes()
        external = self.base / 'external-personal.nix'
        external.write_bytes(original)
        for reviewed_tree in ('working', 'staged'):
            record = self.engine.stage('local')
            root = self.working if reviewed_tree == 'working' else self.engine.tx(record['id']) / 'config'
            source = root / 'local/personal.nix'
            source.unlink()
            source.symlink_to(external)
            with self.subTest(tree=reviewed_tree), self.assertRaisesRegex(Failure, 'link or special file'):
                self.engine.apply(record['id'], record['reviewToken'])
            self.assertFalse(self.engine.pending_path.exists())
            self.assertTrue(source.is_symlink())
            self.assertEqual(external.read_bytes(), original)
            source.unlink()
            source.write_bytes(original)

    def git(self, directory, *arguments):
        return subprocess.check_output(['git', '--no-optional-locks', '-c', 'core.hooksPath=/dev/null',
                                        '-c', 'core.fsmonitor=false', '-C', str(directory), *arguments],
                                       env=os.environ | {'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_SYSTEM': '/dev/null'},
                                       text=True, stderr=subprocess.STDOUT).strip()

    def test_git_metadata_survives_selection_and_rollback_outside_archives(self):
        self.git(self.config, 'init', '--quiet')
        self.git(self.config, 'config', 'user.name', 'Cybex OS isolated regression')
        self.git(self.config, 'config', 'user.email', 'regression@invalid.example')
        self.git(self.config, 'add', '.')
        self.git(self.config, 'commit', '--quiet', '-m', 'Personal configuration')
        metadata = self.config / '.git'
        head = self.git(self.config, 'rev-parse', 'HEAD')
        hook_sentinel = self.base / 'hook-executed'
        hook = metadata / 'hooks/post-checkout'
        hook.write_text('#!/bin/sh\ntouch ' + str(hook_sentinel) + '\n')
        hook.chmod(0o755)
        self.assertEqual(config_digest(self.working), self.sentinel)
        record = self.engine.stage('upstream')
        self.assertFalse((self.engine.tx(record['id']) / 'config/.git').exists())
        self.assertFalse((self.engine.tx(record['id']) / 'previous-config/.git').exists())
        self.git(self.config, 'config', 'cybexos.note', 'Bookkeeping changed after preview')
        identity = {str(path.relative_to(metadata)): (path.read_bytes(), path.stat().st_mode)
                    for path in metadata.rglob('*') if path.is_file()}
        self.engine.apply(record['id'], record['reviewToken'])
        self.assertTrue((self.working / '.git').is_symlink())
        self.assertEqual((self.working / '.git').resolve(), metadata)
        self.assertEqual(self.git(self.working, 'rev-parse', 'HEAD'), head)
        self.assertIn('flake.lock', self.git(self.working, 'status', '--porcelain'))
        self.engine.rollback()
        self.assertEqual(self.git(self.working, 'rev-parse', 'HEAD'), head)
        self.assertEqual(self.git(self.working, 'status', '--porcelain'), '')
        self.assertFalse((self.engine.tx(record['id']) / 'personal-before-rollback/.git').exists())
        self.assertEqual({str(path.relative_to(metadata)): (path.read_bytes(), path.stat().st_mode)
                          for path in metadata.rglob('*') if path.is_file()}, identity)
        self.assertFalse(hook_sentinel.exists())

    def test_pointer_and_unmanaged_git_layouts_fail_before_activation(self):
        record = self.engine.stage('local')
        metadata = self.config / '.git'
        metadata.write_text('gitdir: /elsewhere/worktree')
        for layout in ('pointer', 'link'):
            if layout == 'link':
                metadata.unlink()
                metadata.symlink_to(self.base / 'unknown-metadata')
            with self.subTest(layout=layout), self.assertRaisesRegex(Failure, r'Git metadata directory|\.git symlink'):
                self.engine.apply(record['id'], record['reviewToken'])
            self.assertFalse(self.engine.pending_path.exists())
        metadata.unlink()
        metadata.mkdir()
        (metadata / 'config').write_text('[core]\nworktree = /elsewhere\n')
        with self.assertRaisesRegex(Failure, 'core.worktree'):
            self.engine.apply(record['id'], record['reviewToken'])
        (metadata / 'config').write_text('[include]\npath = /elsewhere/config\n')
        with self.assertRaisesRegex(Failure, 'included configuration'):
            self.engine.apply(record['id'], record['reviewToken'])
        (metadata / 'config').write_text('[core]\nbare = false\n')
        (metadata / 'commondir').write_text('../common')
        with self.assertRaisesRegex(Failure, 'Linked-worktree'):
            self.engine.apply(record['id'], record['reviewToken'])
        self.assertFalse(self.engine.pending_path.exists())
        self.assertFalse(any(args[-1:] == ('test',) for args in self.runner.calls))

    def test_repeated_rollback_does_not_select_edited_previous_working_tree(self):
        record = self.engine.stage('upstream')
        self.engine.apply(record['id'], record['reviewToken'])
        self.engine.rollback()
        prior = self.working.resolve()
        (prior / 'local/personal.nix').write_text('# edited after first rollback')
        (prior / 'local/unapplied.nix').write_text('{}')
        self.engine.rollback(record['id'])
        self.assertNotEqual(self.working.resolve(), prior)
        self.assertEqual(config_digest(self.working), self.sentinel)
        self.assertEqual((prior / 'local/personal.nix').read_text(), '# edited after first rollback')
        self.assertTrue((prior / 'local/unapplied.nix').exists())

    def test_failed_activation_and_interruption_restore_config_and_system(self):
        record=self.engine.stage('upstream')
        self.runner.fail=lambda args:args==(NEW_SYSTEM+'/bin/switch-to-configuration','test')
        with self.assertRaises(Failure):self.engine.apply(record['id'],record['reviewToken'])
        self.assertEqual(read(self.engine.status_path)['state'],'rolled-back')
        self.assertFalse(self.engine.pending_path.exists())
        self.assertTrue((self.engine.tx(record['id'])/'personal-before-rollback/local/personal.nix').exists())
        self.assertEqual(config_digest(self.working),self.sentinel)
        self.assertIn('plugin data',self.personal.read_text())
        self.runner.fail=None
        atomic(self.engine.pending_path,record|{'phase':'activation','bootId':'old'})
        self.engine.recover()
        self.assertEqual(read(self.engine.status_path)['state'],'rolled-back')

    def test_failed_activation_and_failed_restoration_report_resumable_recovery(self):
        record = self.engine.stage('upstream')
        self.runner.fail = lambda args: args[-1:] == ('test',) and args[0].endswith('/bin/switch-to-configuration')
        with self.assertRaises(Failure):
            self.engine.apply(record['id'], record['reviewToken'])
        tx = self.engine.tx(record['id'])
        status = read(self.engine.status_path)
        self.assertEqual(status['state'], 'recovery-failed')
        self.assertEqual(read(self.engine.pending_path)['phase'], 'recovery')
        self.assertIn('Activation failed:', status['error'])
        self.assertIn('Restoration failed:', status['error'])
        self.assertIn('cybex update rollback ' + record['id'], status['recovery'])
        self.assertNotIn('previous generation restored', status['phase'])
        self.assertEqual(read(tx / 'activation-error.json')['error'], 'injected command failure')
        self.assertEqual(read(tx / 'recovery-error.json')['error'], 'injected command failure')
        self.assertEqual(config_digest(self.working), self.sentinel)
        with self.assertRaisesRegex(Failure, 'awaits recovery'):
            self.engine.stage('upstream')
        self.runner.fail = None
        self.engine.recover()
        self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
        self.assertEqual(read(self.engine.status_path)['error'], 'injected command failure')
        self.assertFalse(self.engine.pending_path.exists())

    def test_new_worker_logs_activation_and_restoration_to_the_private_transaction(self):
        record = self.engine.stage('upstream')
        tx = self.engine.tx(record['id'])
        logged = []
        original = self.runner
        def run(*args, **kwargs):
            logged.append((tuple(args), getattr(run, 'log', None)))
            return original(*args, **kwargs)
        # Like the real systemd apply worker, use a new Runner without the
        # preceding stage worker's log state.
        self.engine.run = run
        self.engine.apply(record['id'], record['reviewToken'])
        self.engine.rollback()
        self.assertTrue(logged)
        self.assertTrue(all(log == tx / 'build.log' for _, log in logged))
        self.assertEqual(tx.stat().st_mode & 0o777, 0o700)

    def test_boot_trial_and_failed_boot_recovery(self):
        record=self.engine.stage('upstream')
        self.engine.apply(record['id'],record['reviewToken'])
        self.assertEqual(read(self.engine.status_path)['state'],'awaiting-boot')
        self.assertIn(('cybexos-boot-trial',NEW_SYSTEM,OLD_SYSTEM),self.runner.calls)
        self.engine.recover() # restarting the worker before reboot does not consume the trial
        self.assertEqual(read(self.engine.status_path)['state'],'awaiting-boot')
        self.engine.boot_id=lambda: 'different-boot'
        self.engine.recover() # old system on a new boot means the trial did not boot
        self.assertEqual(read(self.engine.status_path)['state'],'rolled-back')
        with self.assertRaises(Failure):self.engine.stage('upstream') # exact failed system quarantined

    def test_safe_efi_default_is_set_before_installing_candidate_boot(self):
        record=self.engine.stage('upstream')
        self.engine.apply(record['id'],record['reviewToken'])
        guard=self.runner.calls.index(('cybexos-boot-trial','--restore',OLD_SYSTEM))
        install=self.runner.calls.index((NEW_SYSTEM+'/bin/switch-to-configuration','boot'))
        self.assertLess(guard,install)

    def test_confirmation_requires_candidate_boot_and_runtime(self):
        record=self.engine.stage('upstream')
        self.engine.apply(record['id'],record['reviewToken'])
        self.engine.boot_id=lambda: 'different-boot'
        self.system.unlink();self.system.symlink_to(NEW_SYSTEM)
        with self.assertRaises(Failure):self.engine.confirm() # switched userspace with previous boot
        self.booted.unlink();self.booted.symlink_to(NEW_SYSTEM)
        self.engine.confirm()
        self.assertEqual(read(self.engine.status_path)['state'],'done')
        self.assertFalse(self.engine.pending_path.exists())
        self.assertIn(('cybexos-boot-trial','--commit',NEW_SYSTEM),self.runner.calls)

    def prepare_confirmation(self):
        record = self.engine.stage('cybexos')
        self.engine.apply(record['id'], record['reviewToken'])
        self.engine.boot_id = lambda: 'different-boot'
        self.system.unlink(); self.system.symlink_to(NEW_SYSTEM)
        self.booted.unlink(); self.booted.symlink_to(NEW_SYSTEM)
        self.engine.recover()
        self.assertEqual(read(self.engine.status_path)['state'], 'awaiting-login')
        return record

    def assert_confirmation_completed(self, record):
        self.assertEqual(read(self.engine.status_path)['state'], 'done')
        self.assertFalse(self.engine.pending_path.exists())
        self.assertEqual((self.engine.state / 'deployed').resolve(), self.engine.tx(record['id']) / 'config')
        self.assertTrue((self.engine.tx(record['id']) / 'good.json').is_file())
        self.assertEqual(read(self.engine.state / 'channel-sequences.json'), {'stable': 4})
        self.assertEqual(self.runner.calls.count(('cybexos-boot-trial', '--commit', NEW_SYSTEM)), 1)

    def test_interrupted_confirmation_completes_after_success_marker(self):
        record = self.prepare_confirmation()
        with patch.object(self.engine, 'finish_confirmation', side_effect=InterruptedError('power loss')):
            with self.assertRaises(InterruptedError):
                self.engine.confirm()
        self.assertTrue(self.engine.pending_path.exists())
        self.assertNotEqual((self.engine.state / 'deployed').resolve(), self.engine.tx(record['id']) / 'config')
        self.engine.recover()
        self.assert_confirmation_completed(record)
        self.assertEqual(self.runner.calls.count(('cybexos-health', 'desktop-required')), 1)

    def test_confirmation_status_interruption_keeps_recoverable_pending_record(self):
        record = self.prepare_confirmation()
        original = self.engine.status
        def status(**values):
            if values.get('state') == 'done':
                raise InterruptedError('power loss before status publication')
            return original(**values)
        with patch.object(self.engine, 'status', side_effect=status):
            with self.assertRaises(InterruptedError):
                self.engine.confirm()
        self.assertTrue(self.engine.pending_path.exists(), 'Completion status must be durable before pending removal')
        self.assertEqual(read(self.engine.status_path)['state'], 'awaiting-login')
        self.engine.recover()
        self.assert_confirmation_completed(record)

    def test_confirmation_interruption_after_pending_removal_keeps_completed_status(self):
        record = self.prepare_confirmation()
        with patch('cybexos.engine.syncdir', side_effect=InterruptedError('power loss after pending removal')):
            with self.assertRaises(InterruptedError):
                self.engine.confirm()
        self.assertFalse(self.engine.pending_path.exists())
        self.assertEqual(read(self.engine.status_path)['state'], 'done')
        self.engine.recover()
        self.assert_confirmation_completed(record)

    def test_interrupted_explicit_rollback_of_good_deployment_is_not_reconfirmed(self):
        record = self.prepare_confirmation()
        self.engine.confirm()
        self.runner.fail = lambda args: args == ('cybexos-boot-trial', '--restore', OLD_SYSTEM)
        with self.assertRaises(Failure):
            self.engine.rollback(record['id'])
        self.assertEqual(read(self.engine.pending_path)['phase'], 'recovery')
        self.runner.fail = None
        self.engine.recover()
        self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
        self.assertEqual(config_digest(self.working), self.sentinel)
        self.assertFalse(self.engine.pending_path.exists())

    def test_interrupted_rollback_remains_journaled_and_resumes(self):
        record=self.engine.stage('upstream')
        self.engine.apply(record['id'],record['reviewToken'])
        self.runner.fail=lambda args:args==('cybexos-boot-trial','--restore',OLD_SYSTEM)
        with self.assertRaises(Failure):self.engine.rollback()
        self.assertEqual(read(self.engine.pending_path)['phase'],'recovery')
        self.assertEqual(read(self.engine.status_path)['state'], 'recovery-failed')
        self.assertIn('Restoration failed:', read(self.engine.status_path)['error'])
        self.runner.fail=None
        self.engine.recover()
        self.assertEqual(read(self.engine.status_path)['state'],'rolled-back')
        self.assertFalse(self.engine.pending_path.exists())

    def test_rollback_status_interruption_keeps_pending_until_recovery_completes(self):
        record = self.engine.stage('upstream')
        self.engine.apply(record['id'], record['reviewToken'])
        original = self.engine.status
        def status(**values):
            if values.get('state') == 'rolled-back':
                raise InterruptedError('power loss before rollback status publication')
            return original(**values)
        with patch.object(self.engine, 'status', side_effect=status):
            with self.assertRaises(InterruptedError):
                self.engine.rollback()
        self.assertEqual(read(self.engine.pending_path)['phase'], 'recovery')
        self.engine.recover()
        self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
        self.assertEqual(config_digest(self.working), self.sentinel)
        self.assertFalse(self.engine.pending_path.exists())

    def test_rollback_interruption_after_pending_removal_keeps_completed_status(self):
        record = self.engine.stage('upstream')
        self.engine.apply(record['id'], record['reviewToken'])
        def interrupt_syncdir(path):
            if Path(path) == self.engine.state:
                raise InterruptedError('power loss after rollback pending removal')
            return syncdir(path)
        with patch('cybexos.engine.syncdir', side_effect=interrupt_syncdir):
            with self.assertRaises(InterruptedError):
                self.engine.rollback()
        self.assertFalse(self.engine.pending_path.exists())
        self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
        self.engine.recover()
        self.assertEqual(read(self.engine.status_path)['state'], 'rolled-back')
        self.assertEqual(config_digest(self.working), self.sentinel)

    def test_activation_failure_retains_working_unapplied_personal_changes(self):
        (self.config/'local/new-service.nix').write_text('{ services.example.enable = true; }')
        baseline=config_digest(self.working)
        record=self.engine.stage('local')
        self.runner.fail=lambda args:args==(NEW_SYSTEM+'/bin/switch-to-configuration','test')
        with self.assertRaises(Failure):self.engine.apply(record['id'],record['reviewToken'])
        self.assertEqual(config_digest(self.working),baseline)
        self.assertTrue((self.working/'local/new-service.nix').exists())

    def test_personal_edits_during_activation_remain_working(self):
        record=self.engine.stage('upstream')
        original=self.engine.run
        def run(*args,**kwargs):
            if args==(NEW_SYSTEM+'/sw/bin/cybexos-health','desktop'):
                (self.config/'local/during-activation.nix').write_text('{}')
            return original(*args,**kwargs)
        self.engine.run=run
        with self.assertRaises(Failure):self.engine.apply(record['id'],record['reviewToken'])
        self.assertTrue((self.working/'local/during-activation.nix').exists())

    def test_authentication_and_nar_verification_precede_input_evaluation(self):
        self.engine.stage('cybexos')
        prefetch=next(i for i,args in enumerate(self.runner.calls) if args[:3]==('nix','flake','prefetch'))
        update=next(i for i,args in enumerate(self.runner.calls) if args[:3]==('nix','flake','update'))
        self.assertLess(prefetch,update)
        self.assertIn('narHash=',self.runner.calls[prefetch][-1])
        self.runner.calls.clear()
        self.engine.channel=lambda:(_ for _ in ()).throw(Failure('invalid signature'))
        with self.assertRaises(Failure):self.engine.stage('cybexos')
        self.assertFalse(self.runner.calls)

    def test_stage_interruption_is_reported_without_activation(self):
        self.engine.status(state='building')
        self.engine.recover()
        self.assertEqual(read(self.engine.status_path)['state'],'interrupted')
        self.assertEqual(config_digest(self.working),self.sentinel)

    def test_serialization_and_secret_source_guard(self):
        with locked(self.engine.state/'operation.lock'):
            with self.assertRaises(Failure):self.engine.stage('upstream')
        (self.config/'secret').write_text('-----BEGIN PRIVATE KEY-----\nsensitive')
        with self.assertRaises(Failure):self.engine.stage('upstream')
        (self.config/'secret').unlink()
        (self.config/'key').symlink_to('/run/secret')
        with self.assertRaises(Failure):self.engine.stage('upstream')


class SourceTests(unittest.TestCase):
    def test_iso_and_entrypoints_use_shared_contract(self):
        for command in ('install','bootstrap'):
            self.assertIn('exec cybex install', (ROOT/command).read_text())
        flake=(ROOT/'flake.nix').read_text()
        self.assertIn('modules = [ module ./nix/modules/installer.nix',flake)
        self.assertIn('cybexos.nixosModules.default',(ROOT/'templates/machine/flake.nix').read_text())

    def test_release_gate_rejects_fixture_reports_and_wrong_revision(self):
        spec=importlib.util.spec_from_file_location('release_manage',ROOT/'release/manage.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        checks={name:{'result':'passed','evidence':'actual-evidence'} for name in module.REQUIRED}
        report={'revision':REV_NEW,'narHash':NAR_NEW,'checks':checks,'kind':'installation-update-and-physical-qualification'}
        module.gate(report,REV_NEW,NAR_NEW)
        with self.assertRaises(Failure):module.gate(report,REV_OLD,NAR_NEW)
        with self.assertRaises(Failure):module.gate(report|{'kind':'fixtures'},REV_NEW,NAR_NEW)
        checks['encrypted-install']['result']='skipped'
        with self.assertRaises(Failure):module.gate(report,REV_NEW,NAR_NEW)


class LiveLifecycleTests(unittest.TestCase):
    def test_desktop_authorization_uses_the_privileged_nixos_wrapper_with_a_hostile_path(self):
        from cybexos import cli
        commands = [
            ['update', 'stage', 'local'], ['update', 'history'],
            ['software', 'stage', '{}'], ['maintenance', 'preview'],
            ['config', 'region', 'timezone', 'UTC', '"UTC"'],
        ]
        with tempfile.TemporaryDirectory() as temporary:
            for arguments in commands:
                with self.subTest(arguments=arguments), \
                     patch.object(cli, 'LIVE_MARKER', Path(temporary) / 'absent'), \
                     patch.dict(os.environ, {'PATH': '/nix/store/unprivileged/bin'}), \
                     patch.object(sys, 'argv', ['cybex', *arguments]), \
                     patch.object(cli.os, 'execv', side_effect=SystemExit(0)) as execute, \
                     self.assertRaises(SystemExit) as result:
                    cli.main()
                self.assertEqual(result.exception.code, 0)
                self.assertEqual(execute.call_args.args[0], '/run/wrappers/bin/pkexec')
                self.assertEqual(execute.call_args.args[1][0], '/run/wrappers/bin/pkexec')
                self.assertEqual(execute.call_args.args[1][1], '/run/current-system/sw/bin/cybexos-request')

    def test_live_check_and_status_are_read_only_and_explain_installation(self):
        from cybexos import cli
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / 'installer'
            marker.touch()
            for action in ('check', 'status'):
                output = io.StringIO()
                with self.subTest(action=action), patch.object(cli, 'LIVE_MARKER', marker), \
                     patch.object(sys, 'argv', ['cybex', 'update', action]), \
                     patch.object(cli.Engine, 'check') as check, patch.object(cli.os, 'execv') as execute, \
                     contextlib.redirect_stdout(output):
                    cli.main()
                    state = json.loads(output.getvalue())
                    self.assertFalse(state['available'])
                    self.assertIn('after installation', state.get('reason', state.get('phase', '')))
                    check.assert_not_called()
                    execute.assert_not_called()

    def test_live_mutations_are_refused_at_cli_request_and_worker_boundaries(self):
        from cybexos import cli
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / 'installer'
            marker.touch()
            for function, arguments in ((cli.main, ['cybex', 'update', 'stage', 'both']),
                                        (cli.request, ['request', 'stage', 'both']),
                                        (cli.admin, ['admin', 'stage', 'both'])):
                with self.subTest(function=function.__name__), patch.object(cli, 'LIVE_MARKER', marker), \
                     patch.object(cli.os, 'geteuid', return_value=0), patch.object(sys, 'argv', arguments), \
                     patch.object(cli.os, 'execv') as execute, patch.object(cli.subprocess, 'run') as run, \
                     self.assertRaisesRegex(Failure, 'after installation'):
                    function()
                execute.assert_not_called()
                run.assert_not_called()


if __name__=='__main__':unittest.main()
