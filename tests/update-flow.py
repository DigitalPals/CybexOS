#!/usr/bin/env python3
"""Real shell update review with a scripted cybex boundary and private Sway.

The production QML, finite subprocesses, panel routing and controls run unchanged.
The fake helper never authenticates, contacts update sources or changes the host.
Backend worker/build/activation coverage belongs to NixOS qualification.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'tests' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


welcome = load('welcome-guide')
pointer = load('assistant-overlay')

FAKE = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
root = Path(os.environ['XDG_RUNTIME_DIR'])
args = sys.argv[1:]
if args[:1] != ['update']:
    sys.exit(1)
fixture = json.loads((root / 'fixture.json').read_text())
if args[1:] == ['check']:
    print(json.dumps(fixture['sources']))
elif args[1:] == ['status']:
    print((root / 'status.json').read_text())
else:
    with (root / 'calls.jsonl').open('a') as stream:
        stream.write(json.dumps(args[1:]) + '\n')
    if fixture.get('cancel'):
        sys.exit(126)
    state = json.loads((root / 'status.json').read_text())
    request = {'id':'c'*32, 'state':'done', 'createdAt':time.time()}
    if fixture.get('reject'):
        request.update(state='failed',error='The worker rejected this request before starting.')
    elif args[1] == 'stage':
        state = {'state':'ready','transaction':'a'*32,'reviewToken':'b'*64,
            'scope':args[2], 'changeKind':'update', 'changes':'hello: 1 → 2',
            'packageChanges':[{'name':'hello','kind':'updated','before':'1','after':'2'}]}
    elif args[1] == 'apply':
        assert args[2:] == ['a'*32, 'b'*64]
        state.update(state='awaiting-boot',reviewToken=None)
    elif args[1] == 'discard':
        state = {'state':'idle'}
    elif args[1] == 'confirm':
        state.update(state='done')
    elif args[1] == 'rollback':
        state.update(state='rolled-back')
    state.update(request=request,installedIdentity='installed-lock')
    (root / 'status.json').write_text(json.dumps(state))
    print(json.dumps({'accepted':True,'requestId':request['id']}))
'''

IPC = '''
    property var updateTestBar: null
    property var updateTestPopout: null
    function updateFind(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = shell.updateFind(child, name);
            if (found) return found;
        }
        return null;
    }
    function updateItem(name) {
        return shell.updateFind(updateTestBar ? updateTestBar.contentItem : null, name)
            || shell.updateFind(updateTestPopout ? updateTestPopout.contentItem : null, name);
    }
    IpcHandler {
        target: "update-test"
        function refresh(): void { Updates.refreshStatus(); Updates.check(); }
        function trigger(name: string): void {
            const item = shell.updateItem(name);
            if (item && item.visible && item.enabled) item.triggered();
        }
        function state(): string {
            const primary = shell.updateItem("updatePrimary");
            const error = shell.updateItem("updateError");
            const packages = shell.updateItem("updatePackageChange");
            const chip = shell.updateItem("updateTestIndicator");
            const rect = chip ? chip.mapToItem(null, 0, 0) : null;
            return JSON.stringify({loaded: Updates.statusLoaded && Updates.sourcesLoaded,
                indicator: Updates.showIndicator, hasUpdates: Updates.hasUpdates,
                state: Updates.deployment.state, error: Updates.error, summary: Updates.summary,
                active: Updates.runActive, actions: Updates.actions, scope: Updates.selectedScope,
                open: Popouts.open, panel: Popouts.currentName,
                primary: primary ? {label: primary.label, enabled: primary.enabled, visible: primary.visible} : null,
                errorCard: error ? error.text : null, package: packages !== null,
                chip: rect ? {x:rect.x+chip.width/2,y:rect.y+chip.height/2} : null});
        }
    }
'''


class Session(welcome.Session):
    def copy_source(self):
        self.source.mkdir()
        for name in ('desktop', 'assets'):
            shutil.copytree(ROOT / name, self.source / name, ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copyfile(ROOT / 'VERSION', self.source / 'VERSION')
        subprocess.run(['git', 'init', '-q', str(self.source)], check=True)
        shell = self.source / 'desktop/quickshell'
        entry = shell / 'shell.qml'
        text = entry.read_text().replace('    id: shell', '    id: shell\n' + IPC, 1)
        text = text.replace('Component.onCompleted: outputName = output ? output.name : ""',
            'Component.onCompleted: { outputName = output ? output.name : ""; shell.updateTestBar = bar; shell.updateTestPopout = updatePopup; }', 1)
        text = text.replace('            BarPopoutWindow {\n                bar: bar',
            '            BarPopoutWindow {\n                id: updatePopup\n                bar: bar', 1)
        entry.write_text(text)
        chip = shell / 'Bar/Modules/Updates.qml'
        chip.write_text(chip.read_text().replace('        id: chip', '        id: chip\n        objectName: "updateTestIndicator"', 1))

    def state(self):
        return self.json_call('update-test', 'state')

    def probe(self):
        return self.state()

    def fixture(self, **values):
        path = self.runtime / 'fixture.json'
        value = json.loads(path.read_text()) if path.exists() else {}
        path.write_text(json.dumps(value | values))

    def status(self, **values):
        (self.runtime / 'status.json').write_text(json.dumps({'installedIdentity':'installed-lock', **values}))
        self.call('update-test', 'refresh')

    def trigger(self, name):
        self.call('update-test', 'trigger', name)

    def calls(self):
        path = self.runtime / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def process_guard(runtime=None):
    main = subprocess.run(['systemctl','--user','show','quickshell.service','-p','MainPID','--value'], capture_output=True, text=True).stdout.strip()
    pids = set()
    for name in ('qs', '.quickshell-wra'):
        pids.update(subprocess.run(['pgrep','-u',str(os.getuid()),'-x',name],capture_output=True,text=True).stdout.split())
    for pid in pids:
        path = Path('/proc') / pid
        try:
            print('Quickshell', pid, 'MainPID', main, (path/'cmdline').read_bytes(), (path/'cgroup').read_text())
            env = (path/'environ').read_bytes().split(b'\0')
            assert runtime is None or ('XDG_RUNTIME_DIR='+str(runtime)).encode() not in env
        except FileNotFoundError:
            pass
    assert main in ('', '0'), 'Run private shell tests on a host without an active managed desktop'
    if runtime is None:
        assert not pids, 'Another Quickshell is active; preserve it and run this test separately'


def main():
    process_guard()
    with tempfile.TemporaryDirectory(prefix='cxu-') as temporary:
        base = Path(temporary)
        native = base/'native'
        subprocess.run(['cmake','-S',str(ROOT/'desktop/notification-images'),'-B',str(native),'-DBUILD_TESTING=OFF'],check=True,capture_output=True)
        subprocess.run(['cmake','--build',str(native),'--parallel','2'],check=True,capture_output=True)
        session = Session(base, native/'qml')
        session.env.update(CYBEXOS_WELCOME='0', CYBEXOS_ASSISTANT='0')
        session.patch_settings(drawerOverview={'updates':True,'processes':False,'media':False})
        fake = base/'bin/cybex'
        fake.write_text(FAKE)
        fake.chmod(0o700)
        sources = {'installedIdentity':'installed-lock', 'upstream':{'state':'available','available':'new-revision'},
                   'cybexos':{'state':'unavailable','error':'Cybex OS channel unavailable'}}
        session.fixture(sources=sources)
        session.status(state='idle')
        mouse = None
        try:
            conf = base/'sway.conf'
            conf.write_text('output HEADLESS-1 mode 1440x900\nseat seat0 fallback true\n')
            sway = base/'sway'
            shutil.copyfile(os.environ.get('CYBEXOS_SWAY_BINARY') or shutil.which('sway'), sway)
            sway.chmod(0o700)
            session.start([str(sway),'-c',str(conf)],'sway.log')
            sockets = session.wait(lambda:[p for p in session.runtime.glob('wayland-*') if p.is_socket()],'compositor')
            session.env['WAYLAND_DISPLAY']=sockets[0].name
            session.env['SWAYSOCK']=str(session.wait(lambda:next(session.runtime.glob('sway-ipc.*.sock'),None),'compositor IPC'))
            session.start_shell('qs-first.log')
            session.wait(lambda:session.state().get('loaded') and session.state().get('chip'),'available update indicator')
            assert session.state()['scope']=='upstream', session.state()
            mouse = pointer.VirtualPointer(session.env,1440,900)
            chip=session.state()['chip']
            mouse.move(chip['x'],chip['y'])
            mouse.button(True); mouse.button(False)
            session.wait(lambda:session.state().get('open') and session.state().get('panel')=='updates' and session.state().get('primary'),'menubar review')
            assert not session.calls(), session.calls()
            mouse.move(100, 700)
            session.call('popouts','open','control')
            session.wait(lambda:session.state().get('panel')=='control','control center')
            session.trigger('overviewUpdateReview')
            session.wait(lambda:session.state().get('panel')=='updates','shared review from control center')
            assert not session.calls(), session.calls()
            session.fixture(cancel=True)
            session.trigger('updatePrimary')
            session.wait(lambda:'cancelled' in session.state().get('error',''),'authorization cancellation')
            time.sleep(2.2)
            assert 'cancelled' in session.state()['errorCard']
            session.call('popouts','close')
            session.call('popouts','open','updates')
            assert 'cancelled' in session.state()['error']
            session.fixture(cancel=False,reject=True)
            session.trigger('updatePrimary')
            session.wait(lambda:'worker rejected' in session.state().get('error',''),'worker failure')
            session.start_shell('qs-reloaded.log')
            session.wait(lambda:'worker rejected' in session.state().get('error',''),'durable failure after shell restart')
            session.call('popouts','open','updates')
            session.wait(lambda:session.state().get('primary'),'review reload')
            session.fixture(reject=False)
            session.trigger('updatePrimary')
            session.wait(lambda:session.state().get('state')=='ready' and session.state().get('package'),'exact package changes')
            assert session.state()['primary']['label']=='Update', session.state()
            assert session.calls()[-1]==['stage','upstream'], session.calls()
            session.trigger('updatePrimary')
            session.trigger('updatePrimary')
            session.wait(lambda:session.state().get('state')=='awaiting-boot','reviewed application')
            assert sum(call[0]=='apply' for call in session.calls())==1, session.calls()
            assert session.calls()[-1]==['apply','a'*32,'b'*64], session.calls()
            assert session.state()['primary']['label']=='Restart to finish', session.state()
            assert not session.state()['indicator']
            session.status(state='awaiting-login',transaction='a'*32)
            session.wait(lambda:session.state().get('state')=='awaiting-login','postboot confirmation')
            assert session.state()['primary']['label']=='Confirm this boot', session.state()
            session.trigger('updatePrimary')
            session.wait(lambda:session.state().get('state')=='done','confirmation')
            session.fixture(sources={'upstream':{'state':'current'},'cybexos':{'state':'current'}})
            session.call('update-test','refresh')
            session.wait(lambda:not session.state().get('hasUpdates'),'no updates')
            assert not session.state()['indicator']
            session.fixture(sources={'upstream':{'state':'unreachable','error':'offline'},'cybexos':{'state':'unavailable'}})
            session.call('update-test','refresh')
            session.wait(lambda:'offline' in session.state().get('error',''),'discovery error')
            assert not session.state()['indicator']
            session.status(state='recovery-failed',transaction='a'*32,error='Recovery interrupted')
            session.wait(lambda:session.state().get('state')=='recovery-failed','recovery action')
            assert session.state()['primary']['label']=='Restore previous generation', session.state()
            for log in session.logs:
                if log.name.startswith('qs-'):
                    errors=[line for line in log.read_text(errors='replace').splitlines() if welcome.ERRORS.search(line)]
                    assert not errors, '\n'.join(errors)
            print('PASS: both entry points, exact review/apply once, partial source availability, authorization cancellation, durable worker errors, shell restart, boot/confirm/recovery, hidden empty/error badge')
        except BaseException:
            for log in session.logs:
                if log.exists(): print(log.name, log.read_text(errors='replace')[-16000:])
            raise
        finally:
            if mouse: mouse.close()
            session.stop()
            for pid in welcome.own_processes(session.runtime):
                try: os.kill(pid,15)
                except ProcessLookupError: pass
            time.sleep(.2)
            process_guard(session.runtime)
            assert not welcome.own_processes(session.runtime)


if __name__=='__main__':
    main()
