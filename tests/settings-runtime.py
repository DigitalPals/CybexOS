#!/usr/bin/env python3
"""Settings UI audit for a disposable, installed Cybex OS qualification VM.

The --prepare option injects tests/qml/settings-audit-ipc.fragment into a private
copy of the shell. Controls and system helpers are unchanged. This script is
not safe for a personal desktop: it deliberately changes the test user's
preferences. A guest marker, hostname and QEMU identity are required.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback


class Audit:
    def __init__(self, report):
        assert os.geteuid() == 0, 'The disposable guest audit must run as root'
        assert Path('/run/cybexos-settings-audit').exists(), 'Disposable guest marker is required'
        assert Path('/etc/hostname').read_text().strip() == 'cybexos-qa'
        assert 'QEMU' in Path('/sys/class/dmi/id/sys_vendor').read_text()
        self.report_path = report
        self.report = {'scope': 'installed NixOS VM; test-only shell introspection; real controls and helpers',
                       'tests': [], 'pages': {}, 'settings': {}}
        self.prefix = ['runuser', '-u', 'cybexqa', '--', 'env']
        pid = self.user(['systemctl', '--user', 'show', 'quickshell.service', '-p', 'MainPID', '--value'], initial=True).strip()
        environ = Path('/proc', pid, 'environ').read_bytes().split(b'\0')
        self.prefix += [value.decode() for value in environ if value.split(b'=', 1)[0] in
                       (b'PATH', b'XKB_CONFIG_ROOT', b'QML_IMPORT_PATH', b'QT_PLUGIN_PATH', b'HYPRLAND_INSTANCE_SIGNATURE', b'WAYLAND_DISPLAY')]
        self.prefix += ['HOME=/home/cybexqa', 'XDG_RUNTIME_DIR=/run/user/1000',
                        'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus']

    def user(self, command, *, initial=False, input=None, timeout=30):
        prefix = self.prefix
        if initial:
            prefix = prefix + ['XDG_RUNTIME_DIR=/run/user/1000', 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus']
        return subprocess.run(prefix + command, input=input, text=True, capture_output=True,
                              timeout=timeout, check=True).stdout.strip()

    def evaluate(self, expression):
        body = self.user(['cybexos-runtime', 'ipc', 'settings-audit', 'evaluate', expression])
        value = json.loads(body)
        assert value['success'], (expression, value)
        return value.get('value')

    def wait(self, expression, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = self.evaluate(expression)
                if value:
                    return value
            except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
                # Monitor trials can briefly interrupt the shell IPC socket.
                # Retry the observation, never the mutating operation.
                pass
            time.sleep(.15)
        raise AssertionError('Timed out: ' + expression)

    # Views the audit names, as the 2026-10 pages and tabs hold them: About
    # became Home, Keyboard shortcuts a Keyboard tab, and Storage & cleanup
    # the Disk space and Recovery points tabs of Backup & storage.
    VIEWS = {'about': ('home', ''), 'shortcuts': ('keyboard', 'shortcuts'), 'keyboard': ('keyboard', 'layouts'),
             'storage': ('backup', 'storage'), 'recovery': ('backup', 'recovery'), 'backup': ('backup', 'backups')}
    KINDS = {'bar': 'ModulesPage', 'shortcuts': 'ShortcutsPage', 'storage': 'StoragePage', 'recovery': 'StoragePage',
             'about': 'HomePage'}

    def page(self, page):
        target, tab = self.VIEWS.get(page, (page, ''))
        self.evaluate('Settings.showPanel(' + json.dumps(target) + ')')
        if tab:
            self.evaluate('Settings.setTab(' + json.dumps(target) + ',' + json.dumps(tab) + ')')
        kind = self.KINDS.get(page, page.capitalize()+'Page')
        self.wait('Settings.page === ' + json.dumps(target) + ' && Settings.tab === ' + json.dumps(tab)
                  + ' && shell.auditItems().some(item => String(item).startsWith('+json.dumps(kind+'_')+'))')
        time.sleep(.35)

    def edit(self, value, *, key='', label=''):
        self.evaluate('shell.auditEdit(' + ','.join(map(json.dumps, (label, key, value))) + ')')

    def action(self, text):
        self.evaluate('shell.auditAction(' + json.dumps(text) + ')')

    def saved(self):
        self.wait('!Settings.savePending && !Settings.writeInFlight')
        assert not self.evaluate('Settings.persistenceError')
        return json.loads(Path('/home/cybexqa/.config/cybexos/shell.json').read_text())

    def test(self, name, fn):
        started = time.monotonic()
        result = {'name': name}
        try:
            detail = fn()
            result.update(result='passed')
            if detail is not None:
                result['detail'] = detail
        except Exception as error:
            result.update(result='failed', error=str(error), traceback=traceback.format_exc())
        result['seconds'] = round(time.monotonic() - started, 3)
        self.report['tests'].append(result)
        self.report_path.write_text(json.dumps(self.report, indent=2) + '\n')
        print(json.dumps(result), flush=True)
        return result['result'] == 'passed'

    def guard(self):
        pid = self.user(['systemctl', '--user', 'show', 'quickshell.service', '-p', 'MainPID', '--value'])
        names = {'qs', '.quickshell-wra'}
        pids = []
        for path in Path('/proc').iterdir():
            try:
                if path.name.isdigit() and path.stat().st_uid == 1000 and (path/'comm').read_text().strip() in names:
                    pids.append(path.name)
            except (OSError, ProcessLookupError):
                pass
        assert pids == [pid], (pid, pids)
        assert self.user(['systemctl', '--user', 'is-active', 'quickshell.service']) == 'active'
        return {'mainPID': pid, 'shellPIDs': pids}

    def prepare(self):
        self.guard()
        source=Path(__file__).resolve().parents[1]
        target=Path('/home/cybexqa/settings-test-source')
        assert not target.is_symlink()
        target.mkdir(exist_ok=True)
        for name in ['desktop','assets']:
            shutil.copytree(source/name,target/name,dirs_exist_ok=True)
        shutil.copyfile(source/'VERSION',target/'VERSION')
        shell=target/'desktop/quickshell/shell.qml'
        contents=shell.read_text().replace('    SettingsWindow {}','    SettingsWindow { id: auditSettingsWindow }')
        fragment=(source/'tests/qml/settings-audit-ipc.fragment').read_text()
        shell.write_text(contents.replace('    id: shell','    id: shell\n'+fragment,1))
        subprocess.run(['git','init',str(target)],check=True,capture_output=True)
        for path in [target,*target.rglob('*')]:
            if not path.is_symlink():os.chown(path,1000,100)
        config=Path('/home/cybexqa/.config/cybexos/dev-source')
        config.write_text(str(target)+'\n')
        os.chown(config,1000,100)
        self.user(['systemctl','--user','restart','quickshell.service'])
        self.wait('Settings.loaded',timeout=60)
        return self.guard()

    def inventory(self, page):
        self.page(page)
        self.evaluate('shell.auditItems().filter(item => /^SettingsDisclosure_/.test(String(item))).forEach(item => item.open = true)')
        if page == 'notifications':
            self.edit('custom', key='notifQuiet')
        if page == 'bar':
            self.edit('custom', label='Height')
            self.edit('floating', key='barStyle')
        if page == 'appearance':
            self.edit('fixed', key='paletteMode')
            self.edit('custom', key='surfaceBorderMode')
            self.edit(2, key='surfaceBorderWidth')
            self.edit(False, label='Match shell style')
            self.edit('custom', key='pluginBorderMode')
            self.edit(2, key='pluginBorderWidth')
        rows = self.evaluate('shell.auditRows()')
        self.report['pages'][page] = rows
        service = {'keyboard':'input', 'touchpad':'input', 'sound':'sound', 'network':'network',
                   'accounts':'accounts', 'region':'region', 'security':'security'}.get(page)
        if service:
            self.wait('SystemSettings[' + json.dumps(service) + '].loaded || SystemSettings[' + json.dumps(service) + '].error !== ""')
            status = self.evaluate('({loaded:SystemSettings.'+service+'.loaded,error:SystemSettings.'+service+'.error})')
            assert status['loaded'] and not status['error'], status
        if page == 'displays':
            self.wait('DisplaySettings.loaded || DisplaySettings.error !== ""')
            assert not self.evaluate('DisplaySettings.error'), self.evaluate('DisplaySettings.error')
        return {'rows':len(rows), 'visible':sum(row['visible'] for row in rows)}

    def scalar(self, page, row):
        key = row['key']
        snapshot = self.evaluate('Settings.snapshot()')
        baseline = self.evaluate('Settings[' + json.dumps(key) + ']')
        control = row['control']
        if key in ('gap', 'barRadius'):
            self.edit('floating', key='barStyle')
        if key in ('notifQuietStart', 'notifQuietEnd'):
            self.edit('custom', key='notifQuiet')
        if control.startswith('Toggle_'):
            values = [not baseline, baseline]
        elif row.get('choices'):
            values = [choice.get('value', choice.get('id')) if isinstance(choice, dict) else choice for choice in row['choices']]
        elif control.startswith('HSlider_'):
            values = [row['min'], row['max'], baseline]
        elif control.startswith('SettingsField_'):
            values = [0,435,1425,baseline] if row['type'].startswith('TimeRow_') else ['#123abc', baseline] if 'Color' in key else [baseline]
        else:
            raise AssertionError('Unhandled settings control ' + control)
        applied = []
        try:
            for value in values:
                if key == 'theme' and not value:
                    continue
                self.edit(value, key=key)
                self.wait('Settings['+json.dumps(key)+'] === '+json.dumps(value))
                if key == 'theme':
                    self.wait('!Themes.busy')
                actual = self.evaluate('Settings[' + json.dumps(key) + ']')
                assert actual == value or isinstance(actual, (int, float)) and abs(actual-value) < .0001, (key, value, actual)
                saved = self.saved()
                assert saved.get(key, self.evaluate('Settings.defaults['+json.dumps(key)+']')) == actual, (key, saved.get(key), actual)
                applied.append(value)
        finally:
            if key == 'theme':
                self.wait('!Themes.busy')
                self.evaluate('Settings.applyValues('+json.dumps(snapshot)+',"Audit restore","")')
            else:
                self.evaluate('Settings.set('+json.dumps(key)+','+json.dumps(baseline)+')')
            self.saved()
        self.report['settings'][key] = applied
        return {'key':key, 'values':applied}

    def input_preferences(self):
        self.page('touchpad')
        self.wait('SystemSettings.input.loaded && !SystemSettings.input.loading')
        baseline = self.evaluate('shell.auditPage().editState.draft')
        for label, key in [('Tap to click','tap'), ('Natural scrolling','naturalScroll'),
                           ('Swipe between workspaces','workspaceSwipe')]:
            self.edit(not baseline[key], label=label)
        sensitivity = .35 if baseline['sensitivity'] != .35 else -.35
        self.edit(sensitivity, label='Pointer sensitivity')
        assert self.evaluate('shell.auditPage().editState.dirty')
        # A pending edit survives destroying and rebuilding its page.
        self.page('about')
        self.page('touchpad')
        assert self.evaluate('shell.auditPage().editState.dirty')
        self.action('Discard')
        assert self.evaluate('shell.auditPage().editState.draft') == baseline
        self.edit(not baseline['tap'], label='Tap to click')
        self.edit(not baseline['naturalScroll'], label='Natural scrolling')
        self.edit(not baseline['workspaceSwipe'], label='Swipe between workspaces')
        self.edit(sensitivity, label='Pointer sensitivity')
        self.action('Apply')
        self.wait('!SystemSettings.input.busy && !shell.auditPage().editState.dirty')
        assert not self.evaluate('SystemSettings.input.error'), self.evaluate('SystemSettings.input.error')
        self.wait('!SystemSettings.input.loading')
        actual = self.evaluate('SystemSettings.input.snapshot.touchpad')
        assert actual['tap'] != baseline['tap'] and actual['naturalScroll'] != baseline['naturalScroll'], actual
        assert actual['workspaceSwipe'] != baseline['workspaceSwipe'] and abs(actual['sensitivity']-sensitivity)<.001, actual
        document = json.loads(Path('/home/cybexqa/.config/cybexos/input.json').read_text())
        assert document['touchpad']['tap'] == actual['tap']
        self.evaluate('shell.auditPage().editState.draft='+json.dumps(baseline))
        self.action('Apply')
        self.wait('!SystemSettings.input.busy && !shell.auditPage().editState.dirty && !SystemSettings.input.loading')
        assert not self.evaluate('SystemSettings.input.error')
        return {'liveTouchpadOptions':actual, 'discard':True, 'navigationPersistence':True, 'restored':True}

    def keyboard_preferences(self):
        self.page('keyboard')
        self.wait('SystemSettings.input.loaded && !SystemSettings.input.loading')
        baseline = self.evaluate('shell.auditPage().editState.draft')
        self.action('Add layout')
        assert len(self.evaluate('shell.auditPage().editState.draft.layouts')) == len(baseline['layouts'])+1
        self.evaluate('shell.auditPage().editLayouts([{layout:"us",variant:"intl"},{layout:"nl",variant:""}])')
        for shortcut in ['', 'grp:alt_shift_toggle', 'grp:ctrl_shift_toggle', 'grp:caps_toggle']:
            self.edit(shortcut, label='Shortcut')
            assert self.evaluate('shell.auditPage().editState.draft.shortcut') == shortcut
        self.edit('grp:alt_shift_toggle', label='Shortcut')
        self.action('Apply')
        self.wait('!SystemSettings.input.busy && !shell.auditPage().editState.dirty && !SystemSettings.input.loading')
        assert not self.evaluate('SystemSettings.input.error'), self.evaluate('SystemSettings.input.error')
        actual = self.evaluate('SystemSettings.input.snapshot.keyboard')
        assert actual['layouts'] == [{'layout':'us','variant':'intl'}, {'layout':'nl','variant':''}], actual
        self.action('Next layout')
        self.wait('!SystemSettings.input.busy && !SystemSettings.input.loading')
        assert not self.evaluate('SystemSettings.input.error')
        changed = self.evaluate('SystemSettings.input.snapshot.keyboard.active')
        assert changed != actual['active'], (actual, changed)
        self.action('Move up')
        assert self.evaluate('shell.auditPage().editState.draft.layouts[0].layout') == 'nl'
        self.action('Discard')
        self.evaluate('shell.auditPage().editState.draft='+json.dumps(baseline))
        self.action('Apply')
        self.wait('!SystemSettings.input.busy && !shell.auditPage().editState.dirty && !SystemSettings.input.loading')
        return {'layouts':actual['layouts'], 'switch':changed, 'reorderAndDiscard':True, 'restored':True}

    def workspaces(self):
        self.page('workspaces')
        self.wait('DesktopWorkspaces.ready')
        for mode in ['per-monitor','shared']:
            self.edit(mode, label='Workspace mode')
            self.wait('DesktopWorkspaces.mode === '+json.dumps(mode))
            assert not self.evaluate('DesktopWorkspaces.error')
        layouts = self.evaluate('shell.auditRow("Default workspace layout", "").model')
        for entry in layouts:
            self.edit(entry['value'], label='Default workspace layout')
            self.wait('DesktopWorkspaces.defaultLayout === '+json.dumps(entry['value']))
            assert not self.evaluate('DesktopWorkspaces.error')
        self.edit('dwindle', label='Default workspace layout')
        self.wait('DesktopWorkspaces.defaultLayout === "dwindle"')
        for entry in [{'value':'floating'}, {'value':'dwindle'}, {'value':'default'}]:
            self.edit(entry['value'], label='Layout')
            self.wait('shell.auditPage().selectedLayout === '+json.dumps(entry['value']))
        for enabled in [False,True]:
            self.edit(enabled, label='Floating titlebars')
            self.wait('DesktopWorkspaces.titlebarsEnabled === '+json.dumps(enabled))
        return {'modes':['per-monitor','shared'], 'layouts':[entry['value'] for entry in layouts], 'perWorkspace':True, 'titlebars':True}

    def default_applications(self):
        self.page('applications')
        self.wait('!DefaultApplications.busy && Object.keys(DefaultApplications.roles).length === 6')
        labels={'browser':'Web browser','terminal':'Terminal','editor':'Text editor',
                'pdf':'PDF viewer','image':'Image viewer','video':'Video player'}
        result={}
        for role,label in labels.items():
            state=self.evaluate('DefaultApplications.roles['+json.dumps(role)+']')
            result[role]=[]
            for choice in state['choices']:
                self.edit(choice['value'],label=label)
                self.wait('!DefaultApplications.busy')
                assert not self.evaluate('DefaultApplications.error'), self.evaluate('DefaultApplications.error')
                actual=json.loads(self.user(['cybexos-apps','status']))['roles'][role]
                assert actual['selected']==choice['value'],actual
                result[role].append(choice['value'])
            self.edit(state['selected'],label=label)
            self.wait('!DefaultApplications.busy')
        return result

    def persistence_and_reset(self):
        self.page('appearance')
        self.edit('light',key='themeMode')
        self.edit(True,key='reducedMotion')
        expected=self.evaluate('Settings.snapshot()')
        self.saved()
        self.user(['systemctl','--user','restart','quickshell.service'])
        deadline=time.monotonic()+30
        while True:
            try:
                if self.evaluate('Settings.loaded'):break
            except (subprocess.SubprocessError,ValueError,AssertionError):pass
            assert time.monotonic()<deadline,'shell did not restart'
            time.sleep(.3)
        assert self.evaluate('Settings.snapshot()') == expected
        self.page('appearance')
        self.evaluate('Settings.resetSection("appearance", "Appearance")')
        self.wait('Settings.themeMode === Settings.defaults.themeMode && Settings.undoAvailable')
        self.evaluate('Settings.undoReset()')
        assert self.evaluate('Settings.snapshot()') == expected
        # Unknown personal keys survive a normal UI write.
        path=Path('/home/cybexqa/.config/cybexos/shell.json')
        value=json.loads(path.read_text()); value['settingsAuditUnknown']={'keep':'personal'}
        path.write_text(json.dumps(value))
        self.wait('Settings.sourceDocument.settingsAuditUnknown !== undefined')
        self.edit('dark',key='themeMode')
        assert self.saved()['settingsAuditUnknown']=={'keep':'personal'}
        return {'shellRestart':True, 'resetUndo':True, 'preservedUnknownPersonalKey':True}

    def display_trial(self):
        self.page('displays')
        self.wait('DisplaySettings.loaded && !DisplaySettings.loading && shell.auditPage().drafts.length > 0')
        selected=self.evaluate('shell.auditPage().selected')
        scale=1.25 if selected['scale'] != 1.25 else 1.5
        self.edit(scale,label='Scale')
        assert self.evaluate('shell.auditPage().dirty')
        self.action('Discard')
        assert not self.evaluate('shell.auditPage().dirty')
        self.edit(scale,label='Scale')
        self.action('Apply')
        self.wait('!DisplaySettings.busy && (DisplaySettings.preview !== null || DisplaySettings.error !== "")')
        assert not self.evaluate('DisplaySettings.error'),self.evaluate('DisplaySettings.error')
        live=json.loads(self.user(['hyprctl','-j','monitors']))
        assert abs(live[0]['scale']-scale)<.001,live
        self.action('Revert now')
        self.wait('!DisplaySettings.busy && DisplaySettings.preview === null && !DisplaySettings.loading')
        assert abs(json.loads(self.user(['hyprctl','-j','monitors']))[0]['scale']-selected['scale'])<.001
        self.wait('!shell.auditPage().dirty')
        self.edit(scale,label='Scale')
        self.action('Apply')
        self.wait('!DisplaySettings.busy && DisplaySettings.preview !== null')
        self.action('Keep changes')
        self.wait('!DisplaySettings.busy && DisplaySettings.preview === null && !DisplaySettings.loading')
        path=Path('/home/cybexqa/.config/cybexos/displays.json')
        saved=json.loads(path.read_text())
        assert any(abs(monitor['scale']-scale)<.001 for monitor in saved['monitors'].values()),saved
        self.wait('!shell.auditPage().dirty')
        self.edit(selected['scale'],label='Scale')
        self.action('Apply')
        self.wait('!DisplaySettings.busy && DisplaySettings.preview !== null')
        # Leaving the page rolls a pending trial back without saving it.
        self.page('about')
        self.wait('!DisplaySettings.busy && DisplaySettings.preview === null')
        assert abs(json.loads(self.user(['hyprctl','-j','monitors']))[0]['scale']-scale)<.001
        self.page('displays')
        self.wait('!DisplaySettings.loading')
        self.edit(selected['scale'],label='Scale')
        self.action('Apply')
        self.wait('!DisplaySettings.busy && DisplaySettings.preview !== null')
        self.action('Keep changes')
        self.wait('!DisplaySettings.busy && DisplaySettings.preview === null && !DisplaySettings.loading')
        return {'trial':True,'discard':True,'keep':True,'revert':True,'pageExitRollback':True,'restored':True}

    def network_trial(self):
        self.page('network')
        self.wait('SystemSettings.network.loaded && !SystemSettings.network.loading && !!shell.auditPage().draft')
        self.evaluate('shell.auditPage().load(shell.auditPage().profiles.find(p => p.active).uuid)')
        before=self.evaluate('shell.auditPage().draft')
        self.edit(not before['autoconnect'],label='Autoconnect')
        assert self.evaluate('shell.auditPage().dirty')
        self.action('Discard')
        assert not self.evaluate('shell.auditPage().dirty')
        # DNS/metering exercise a real active NetworkManager checkpoint.
        metered=1 if before['metered'] != 1 else 2
        self.edit(metered,label='Metered connection')
        self.action('Apply')
        self.wait('!SystemSettings.network.busy && (SystemSettings.network.preview !== null || SystemSettings.network.error !== "")')
        assert not self.evaluate('SystemSettings.network.error'),self.evaluate('SystemSettings.network.error')
        self.action('Revert now')
        self.wait('!SystemSettings.network.busy && SystemSettings.network.preview === null && !SystemSettings.network.loading')
        self.wait('!shell.auditPage().dirty')
        self.edit(metered,label='Metered connection')
        self.action('Apply')
        self.wait('!SystemSettings.network.busy && SystemSettings.network.preview !== null')
        self.action('Keep changes')
        self.wait('!SystemSettings.network.busy && SystemSettings.network.preview === null && !SystemSettings.network.loading')
        self.wait('!shell.auditPage().dirty')
        assert self.evaluate('shell.auditPage().saved.metered')==metered
        self.edit(before['metered'],label='Metered connection')
        self.action('Apply')
        self.wait('!SystemSettings.network.busy && SystemSettings.network.preview !== null')
        self.action('Keep changes')
        self.wait('!SystemSettings.network.busy && SystemSettings.network.preview === null && !SystemSettings.network.loading')
        return {'activeProfile':before['name'],'discard':True,'checkpoint':True,'revert':True,'keep':True,'restored':True}

    def idle_and_night_light(self):
        self.page('power')
        self.wait('SysInfo.idleTimeoutsApplied === SysInfo.idleTimeoutsKey(Settings)')
        assert not self.evaluate('SysInfo.idleTimeoutsError'),self.evaluate('SysInfo.idleTimeoutsError')
        assert self.user(['systemctl','--user','is-active','hypridle.service'])=='active'
        for mode in ['30m','1h','always','off']:
            self.edit(mode,label='Duration')
            self.wait('SysInfo.idleInhibitMode === '+json.dumps(mode)+' && !SysInfo.idleInhibitPending')
            assert not self.evaluate('SysInfo.idleInhibitError'),self.evaluate('SysInfo.idleInhibitError')
            assert self.evaluate('SysInfo.idleInhibitEffective')==(mode!='off')
        self.page('displays')
        self.edit(True,key='nightLight')
        self.wait('!SysInfo.nightLightPending && (SysInfo.nightLightEffective || SysInfo.nightLightError !== "")')
        assert not self.evaluate('SysInfo.nightLightError'),self.evaluate('SysInfo.nightLightError')
        self.edit(4100,key='warmth')
        self.saved()
        self.edit(False,key='nightLight')
        self.wait('!SysInfo.nightLightPending && !SysInfo.nightLightEffective')
        assert not self.evaluate('SysInfo.nightLightError')
        return {'stayAwakeModes':['30m','1h','always','off'],'realHyprsunsetStartStop':True}

    def notifications(self):
        self.page('notifications')
        self.edit(True,label='Do Not Disturb')
        assert self.evaluate('Notifs.dnd')
        self.edit(False,label='Do Not Disturb')
        self.edit('custom',key='notifQuiet')
        for key in ['notifQuietStart','notifQuietEnd']:
            for value in [0,435,1425]:
                self.edit(value,key=key)
                assert self.evaluate('Settings['+json.dumps(key)+']')==value
        self.edit('off',key='notifQuiet')
        for corner in ['top-left','top-right','bottom-left','bottom-right']:
            self.edit(corner,key='notifPosition')
            assert self.saved()['notifPosition']==corner
        self.action('Send test')
        self.wait('Notifs.entries.length > 0')
        return {'doNotDisturb':True,'customQuietTimes':True,'corners':4,'realNotification':True}

    def audio(self):
        modules=[]
        processes=[]
        try:
            for name in ['qa_output_a','qa_output_b']:
                modules.append(self.user(['pactl','load-module','module-null-sink','sink_name='+name,
                                          'sink_properties=device.description='+name]))
            modules.append(self.user(['pactl','load-module','module-remap-source',
                                      'master=qa_output_a.monitor','source_name=qa_microphone']))
            self.user(['pactl','set-default-sink','qa_output_a'])
            self.user(['pactl','set-default-source','qa_microphone'])
            self.page('sound')
            self.evaluate('SystemSettings.sound.refresh()')
            self.wait('Audio.ready && Audio.sourceReady && !!shell.auditPage().outputInfo && !!shell.auditPage().inputInfo')
            self.edit(.37,label='Volume')
            self.wait('Math.abs(Audio.level - .37) < .02')
            sink=next(s for s in json.loads(self.user(['pactl','-f','json','list','sinks'])) if s['name']=='qa_output_a')
            # Quickshell exposes a perceptual volume; pactl's raw amplitude
            # follows PipeWire's cubic mapping. Both must actually change.
            assert 0 < next(iter(sink['volume'].values()))['value'] < 65536,sink['volume']
            self.evaluate('shell.auditRow("Volume", "").muteToggled()')
            self.wait('Audio.muted')
            sink=next(s for s in json.loads(self.user(['pactl','-f','json','list','sinks'])) if s['name']=='qa_output_a')
            assert sink['mute']
            self.evaluate('shell.auditRow("Volume", "").muteToggled()')
            self.wait('!Audio.muted')
            self.edit(-.5,label='Balance')
            self.wait('!SystemSettings.sound.busy && !!shell.auditPage().outputInfo && Math.abs(shell.auditPage().outputInfo.balance + .5) < .05')
            self.edit(.42,label='Input volume')
            self.wait('Math.abs(Audio.sourceLevel - .42) < .02')
            self.evaluate('shell.auditRow("Input volume", "").muteToggled()')
            self.wait('Audio.sourceMuted')
            self.evaluate('shell.auditRow("Input volume", "").muteToggled()')
            self.wait('!Audio.sourceMuted')
            self.evaluate('shell.auditItems().find(item => /^ChoiceRow_/.test(String(item)) && item.label === "qa_output_b").activated()')
            self.wait('Audio.outputSink && Audio.outputSink.name === "qa_output_b"')
            assert self.user(['pactl','get-default-sink'])=='qa_output_b'
            return {'nativePipeWireOutputs':2,'nativeMicrophone':True,'volume':True,'mute':True,'balance':True,'defaultOutput':True}
        finally:
            for process in processes:
                process.terminate()
                process.wait(timeout=5)
            for module in reversed(modules):
                self.user(['pactl','unload-module',module])

    def backup(self):
        self.page('backup')
        self.wait('!Backup.busy')
        destination=Path('/var/tmp/settings-audit-backups')
        destination.mkdir(exist_ok=True)
        os.chown(destination,1000,100)
        sample=Path('/home/cybexqa/Documents/settings-audit-sample.txt')
        sample.parent.mkdir(exist_ok=True)
        sample.write_text('settings audit recovery sample\n')
        os.chown(sample,1000,100)
        self.action('Set up…')
        self.evaluate('shell.auditPage().folder='+json.dumps(str(destination)))
        self.action('Continue')
        self.wait('!Backup.busy && (Backup.pendingKey !== "" || Backup.error !== "")',timeout=180)
        assert not self.evaluate('Backup.error'),self.evaluate('Backup.error')
        self.action('I saved it, back up now')
        self.wait('!Backup.busy && Backup.configured')
        self.wait('!Backup.running && !Backup.starting',timeout=180)
        for enabled in [False,True]:
            self.edit(enabled,label='Automatic backups')
            self.wait('!Backup.busy')
            assert not self.evaluate('Backup.error'),self.evaluate('Backup.error')
        self.evaluate('Backup.loadSnapshots()')
        self.wait('!Backup.busy && Backup.snapshotsLoaded')
        snapshots=self.evaluate('Backup.snapshots')
        assert snapshots,snapshots
        sample.write_text('changed after backup\n')
        self.evaluate('Backup.restore('+json.dumps(snapshots[0]['id'])+',"Documents/settings-audit-sample.txt")')
        self.wait('!Backup.starting && !Backup.running',timeout=180)
        restored=list(Path('/home/cybexqa/Restored').rglob('settings-audit-sample.txt'))
        assert any(path.read_text()=='settings audit recovery sample\n' for path in restored),restored
        assert sample.read_text()=='changed after backup\n'
        return {'encryptedResticRepository':True,'keyring':True,'recoveryKeyConfirmation':True,
                'automaticToggle':True,'snapshot':True,'restoreIntoNewFolder':True,'originalPreserved':True}

    def widget_options(self):
        self.page('bar')
        baseline=self.evaluate('Settings.snapshot()')
        modules=self.evaluate('shell.auditPage().entries.filter(e=>!e.plugin).map(e=>e.id)')
        result={}
        self.report['widgetOptions'] = result
        try:
            for module in modules:
                self.evaluate('Settings.openWidgetSettings('+json.dumps(module)+')')
                self.wait('shell.auditItems().some(item => item.moduleId === '+json.dumps(module)+')')
                time.sleep(.3)
                rows=self.evaluate('shell.auditRows()')
                result[module]=[]
                for index,row in enumerate(rows):
                    if row.get('module') != module or not row['visible'] or not row.get('control') or row['reason']:
                        continue
                    if module == 'updates' and 'automatically' in row['label']:
                        result[module].append({'label':row['label'],'result':'requires-polkit-fixture'})
                        continue
                    control=row['control']
                    initial=row.get('value')
                    if control.startswith('Toggle_'):
                        values=[not initial,initial]
                    elif row.get('choices'):
                        values=[choice.get('value') if isinstance(choice,dict) else choice for choice in row['choices']]
                    elif control.startswith('HSlider_'):
                        values=[row['min'],row['max'],initial]
                    else:
                        # Endpoint, path and credential fields need their own
                        # local service fixtures; never contact a real account.
                        result[module].append({'label':row['label'],'result':'requires-service-fixture'})
                        continue
                    def exercise():
                        for value in values:
                            self.evaluate('shell.auditEditAt('+str(index)+','+json.dumps(value)+')')
                            self.wait('JSON.stringify(shell.auditRows()['+str(index)+'].value) === '+json.dumps(json.dumps(value,separators=(',',':'))))
                            self.saved()
                        self.evaluate('shell.auditEditAt('+str(index)+','+json.dumps(initial)+')')
                        self.saved()
                        return {'module':module,'label':row['label'],'values':values}
                    passed = self.test('widget: '+module+' / '+row['label'], exercise)
                    result[module].append({'label':row['label'],'result':'passed' if passed else 'failed','values':values})
                self.evaluate('shell.auditItems().find(item => /^ModulesPage_/.test(String(item))).closeSubPage()')
        finally:
            self.evaluate('Settings.applyValues('+json.dumps(baseline)+',"Audit restore","")')
            self.saved()
        return result

    def wallpaper(self):
        self.page('wallpaper')
        before=self.evaluate('Settings.snapshot()')
        try:
            folder=Path('/home/cybexqa/Pictures/settings-audit-wallpapers')
            folder.mkdir(parents=True,exist_ok=True)
            os.chown(folder,1000,100)
            for name in ['first.png','second.png']:
                shutil.copyfile(self.evaluate('Wallpaper.defaultPath'),folder/name)
                os.chown(folder/name,1000,100)
            self.evaluate('Wallpaper.requestDirectory('+json.dumps(str(folder))+')')
            self.wait('!Wallpaper.loading && Wallpaper.files.length === 2')
            files=self.evaluate('Wallpaper.files')
            picker='shell.auditItems().find(item => /^WallpaperPicker_/.test(String(item)))'
            self.evaluate(picker+'.tab="library"')
            for path in files[:2]:
                self.evaluate(picker+'.chooseLocal({path:'+json.dumps(path)+',fileName:Wallpaper.basename('+json.dumps(path)+')})')
                self.evaluate(picker+'.useSelected()')
                self.wait('Settings.wall === Wallpaper.basename('+json.dumps(path)+')')
                self.saved()
            self.evaluate('shell.auditItems().filter(item => /^SettingsDisclosure_/.test(String(item))).forEach(item => item.open=true)')
            for mode in ['Off','15m','1h','1d']:
                self.edit(mode,key='shuffle')
                assert self.saved()['shuffle']==mode
            self.action('Shuffle now')
            self.wait('Settings.wall !== '+json.dumps(Path(files[1]).name))
            # A nonexistent folder cannot replace the last usable collection.
            previous=self.evaluate('Settings.wallDir')
            self.evaluate('Wallpaper.requestDirectory("/home/cybexqa/does-not-exist-audit")')
            self.wait('Wallpaper.directoryError !== ""')
            assert self.evaluate('Settings.wallDir')==previous
            return {'localPicker':2,'rotationChoices':4,'shuffle':True,'invalidFolderPreservesCollection':True}
        finally:
            self.evaluate('Settings.applyValues('+json.dumps(before)+',"Audit restore","")')
            self.saved()

    def appearance_extras(self):
        self.inventory('appearance')
        before=self.evaluate('Settings.snapshot()')
        try:
            self.edit('fixed',key='paletteMode')
            for color in self.evaluate('shell.auditPage().accentChoices'):
                self.evaluate('shell.auditPage().pickAccent('+json.dumps(color)+')')
                self.wait('Settings.accent === '+json.dumps(color))
                self.saved()
            for hue in [0,120,240,359]:
                self.edit(hue,label='Accent hue')
                assert self.evaluate('Settings.accent').startswith('#')
            self.edit('custom',key='surfaceBorderMode')
            self.edit(2,key='surfaceBorderWidth')
            self.wait('shell.auditRow("", "surfaceBorderOpacity").disabledReason === ""')
            row=next(row for row in self.evaluate('shell.auditRows()') if row['key']=='surfaceBorderOpacity')
            self.scalar('appearance',row)
            self.action('Save current as theme…')
            self.edit('Settings audit theme',label='Theme name')
            self.action('Save')
            self.wait('!Themes.busy && Themes.entries.some(e => e.name === "Settings audit theme")')
            assert not self.evaluate('Themes.error'),self.evaluate('Themes.error')
            entry=self.evaluate('Themes.entries.find(e => e.name === "Settings audit theme")')
            self.edit(entry['id'],key='theme')
            self.wait('!Themes.busy')
            return {'accentPresets':True,'hueBounds':True,'borderOpacityBounds':True,'customThemeSaveApply':True}
        finally:
            self.evaluate('Settings.applyValues('+json.dumps(before)+',"Audit restore","")')
            self.saved()

    def network_addresses(self):
        self.user(['nmcli','connection','add','type','ethernet','con-name','settings-audit-inactive',
                   'ifname','qa-unused0','connection.autoconnect','no'])
        try:
            self.page('network')
            self.evaluate('SystemSettings.network.refresh()')
            self.wait('!SystemSettings.network.loading && shell.auditPage().profiles.some(p => p.name === "settings-audit-inactive")')
            self.evaluate('shell.auditPage().load(shell.auditPage().profiles.find(p => p.name === "settings-audit-inactive").uuid)')
            self.edit(True,label='Autoconnect')
            self.edit(2,label='Metered connection')
            def ip_edit(family,label,value):
                self.evaluate('shell.auditEditRow(shell.auditWalk(shell.auditItems().find(item => /^IpSettings_/.test(String(item)) && item.title === '+json.dumps(family)+')).find(item => item.label === '+json.dumps(label)+'),'+json.dumps(value)+')')
            for family,address,gateway,dns in [('IPv4','192.0.2.10/24','192.0.2.1','192.0.2.53'),
                                                ('IPv6','2001:db8::10/64','2001:db8::1','2001:db8::53')]:
                ip_edit(family,'Method','manual')
                assert self.evaluate('shell.auditPage().problem')
                ip_edit(family,'Address','invalid')
                assert self.evaluate('shell.auditPage().problem')
                ip_edit(family,'Address',address)
                ip_edit(family,'Gateway',gateway)
                ip_edit(family,'Automatic DNS',False)
                ip_edit(family,'DNS servers',dns)
            assert not self.evaluate('shell.auditPage().problem')
            self.action('Apply')
            self.wait('!SystemSettings.network.busy && !SystemSettings.network.loading && !shell.auditPage().dirty')
            assert not self.evaluate('SystemSettings.network.error'),self.evaluate('SystemSettings.network.error')
            actual=self.user(['nmcli','-g','ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv6.method,ipv6.addresses,ipv6.gateway,ipv6.dns','connection','show','settings-audit-inactive'])
            assert '192.0.2.10/24' in actual and '2001' in actual,actual
            for family in ['IPv4','IPv6']:
                ip_edit(family,'Method','disabled')
            assert self.evaluate('shell.auditPage().problem')=='Enable at least one IP version'
            self.action('Discard')
            return {'realInactiveNetworkManagerProfile':True,'IPv4AndIPv6Manual':True,
                    'addressGatewayDNSAutoconnectMetering':True,'invalidAddressAndBothDisabledBlocked':True}
        finally:
            self.user(['nmcli','connection','delete','settings-audit-inactive'])

    def plugin_lifecycle(self):
        source=Path('/home/cybexqa/settings-audit-plugin')
        source.mkdir(exist_ok=True)
        manifest={'id':'audit.settings','apiVersion':1,'name':'Settings audit widget',
                  'version':'1.0.0','entrypoint':'Widget.qml'}
        (source/'manifest.json').write_text(json.dumps(manifest))
        (source/'Widget.qml').write_text('import QtQuick\nText { required property var pluginApi; text: "Audit widget" }\n')
        for path in [source,*source.iterdir()]: os.chown(path,1000,100)
        self.user(['git','init',str(source)])
        self.user(['git','-C',str(source),'add','.'])
        self.user(['git','-C',str(source),'-c','user.name=Settings audit','-c','user.email=audit@example.invalid','commit','--allow-empty','-m','Fixture'])
        self.page('plugins')
        self.edit(str(source),label='Source')
        self.action('Install')
        self.wait('!UserPlugins.busy && UserPlugins.plugins.some(p => p.id === "audit.settings")')
        assert not self.evaluate('UserPlugins.error'),self.evaluate('UserPlugins.error')
        row='shell.auditItems().find(item => /^PluginRow_/.test(String(item)) && item.plugin.id === "audit.settings")'
        for enabled in [True,False,True]:
            self.evaluate('shell.auditControl('+row+').toggled('+json.dumps(enabled)+')')
            self.wait('!UserPlugins.busy')
            assert not self.evaluate('UserPlugins.error'),self.evaluate('UserPlugins.error')
        for arguments in [['update','audit.settings','--preview'],['update','audit.settings']]:
            self.evaluate(row+'.run('+json.dumps(arguments)+')')
            self.wait('!UserPlugins.busy')
            assert not self.evaluate('UserPlugins.error'),self.evaluate('UserPlugins.error')
        self.evaluate(row+'.confirmRemoval=true')
        self.action('Cancel')
        assert self.evaluate('UserPlugins.plugins.some(p => p.id === "audit.settings")')
        self.evaluate(row+'.confirmRemoval=true')
        self.action('Remove')
        self.wait('!UserPlugins.busy && !UserPlugins.plugins.some(p => p.id === "audit.settings")')
        assert not self.evaluate('UserPlugins.error'),self.evaluate('UserPlugins.error')
        return {'localGitInstall':True,'enableDisable':True,'updatePreviewAndApply':True,'removalCancelConfirm':True}

    def bar_layout(self):
        self.page('bar')
        before=self.evaluate('Settings.snapshot()')
        try:
            for preset in ['focused','connected','everything']:
                self.evaluate('shell.auditPage().preset='+json.dumps(preset)+';Settings.applyModulePreset('+json.dumps(preset)+')')
                expected=self.evaluate('Settings.modulePresetIds('+json.dumps(preset)+')')
                actual=self.evaluate('Object.values(Settings.mods).reduce((a,b)=>a.concat(b),[]).filter(m=>m.on).map(m=>m.id)')
                assert sorted(expected)==sorted(actual),(expected,actual)
                self.saved()
            entries=self.evaluate('shell.auditPage().entries')
            for entry in entries:
                if entry.get('plugin'): continue
                self.evaluate('shell.auditPage().setEnabled(shell.auditPage().entries.find(e=>e.key==='+json.dumps(entry['key'])+'),false)')
                self.wait('!shell.auditPage().membershipBusy')
                self.evaluate('shell.auditPage().setEnabled(shell.auditPage().entries.find(e=>e.key==='+json.dumps(entry['key'])+'),true)')
                self.wait('!shell.auditPage().membershipBusy')
            return {'presets':3,'eachBuiltinMembership':len(entries),'saved':True}
        finally:
            self.evaluate('Settings.applyValues('+json.dumps(before)+',"Audit restore","")')
            self.saved()

    def vpn(self):
        import base64
        path=Path('/home/cybexqa/Downloads/qa-settings-vpn.conf')
        path.parent.mkdir(exist_ok=True)
        path.write_text('[Interface]\nPrivateKey = '+base64.b64encode(os.urandom(32)).decode()+
                        '\nAddress = 192.0.2.2/32\n')
        os.chown(path,1000,100)
        path.chmod(0o600)
        self.page('network')
        self.wait('SystemSettings.network.loaded && !SystemSettings.network.loading')
        group='shell.auditItems().find(item => /^VpnGroup_/.test(String(item)))'
        self.evaluate(group+'.run("import", {path:'+json.dumps(str(path))+'})')
        self.wait('!SystemSettings.network.busy && !SystemSettings.network.loading && SystemSettings.network.snapshot.vpns.some(p=>p.name==="qa-settings-vpn")')
        assert not self.evaluate(group+'.failure'),self.evaluate(group+'.failure')
        uuid=self.evaluate('SystemSettings.network.snapshot.vpns.find(p=>p.name==="qa-settings-vpn").uuid')
        try:
            self.edit(True,label='qa-settings-vpn')
            self.wait('!SystemSettings.network.busy && !SystemSettings.network.loading')
            assert not self.evaluate(group+'.failure'),self.evaluate(group+'.failure')
            assert uuid in self.user(['nmcli','-g','UUID','connection','show','--active'])
            self.edit(False,label='qa-settings-vpn')
            self.wait('!SystemSettings.network.busy && !SystemSettings.network.loading')
            assert uuid not in self.user(['nmcli','-g','UUID','connection','show','--active'])
            self.action('Remove qa-settings-vpn…')
            self.action('Cancel')
            self.action('Remove qa-settings-vpn…')
            self.action('Remove')
            self.wait('!SystemSettings.network.busy && !SystemSettings.network.loading && !SystemSettings.network.snapshot.vpns.some(p=>p.name==="qa-settings-vpn")')
            return {'wireguardImport':True,'realInterfaceActivation':True,'disconnect':True,
                    'removeCancelConfirm':True,'externalPeerHandshake':'requires a peer'}
        finally:
            subprocess.run(self.prefix+['nmcli','connection','delete',uuid],capture_output=True)
            path.unlink()

    def display_formats(self):
        self.page('displays')
        self.wait('DisplaySettings.loaded && !DisplaySettings.loading && shell.auditPage().selected !== null')
        results=[]
        for label in ['Resolution','Refresh rate','Rotation','Flipped','Adaptive sync']:
            row=next(row for row in self.evaluate('shell.auditRows()') if row['label']==label)
            choices=row.get('choices')
            values=[entry['value'] for entry in choices] if choices else [True,False]
            if label=='Resolution': values=values[:3]
            baseline=row['value']
            for value in values:
                if value==baseline:continue
                self.edit(value,label=label)
                self.wait('shell.auditPage().dirty')
                assert not self.evaluate('shell.auditPage().problem'),self.evaluate('shell.auditPage().problem')
                self.action('Apply')
                self.wait('!DisplaySettings.busy && (DisplaySettings.preview !== null || DisplaySettings.error !== "")')
                assert not self.evaluate('DisplaySettings.error'),self.evaluate('DisplaySettings.error')
                live=json.loads(self.user(['hyprctl','-j','monitors']))
                if label=='Rotation': assert live[0]['transform']%4==value%4,live
                if label=='Flipped': assert (live[0]['transform']>=4)==value,live
                self.action('Revert now')
                self.wait('!DisplaySettings.busy && DisplaySettings.preview === null && !DisplaySettings.loading && !shell.auditPage().dirty')
                results.append({'control':label,'value':value})
        # The independent trial watchdog restores the compositor on timeout.
        scale=self.evaluate('shell.auditPage().selected.scale')
        self.edit(1.25 if scale!=1.25 else 1.5,label='Scale')
        self.action('Apply')
        self.wait('!DisplaySettings.busy && DisplaySettings.preview !== null')
        self.wait('!DisplaySettings.busy && DisplaySettings.preview === null && !DisplaySettings.loading',timeout=45)
        assert abs(json.loads(self.user(['hyprctl','-j','monitors']))[0]['scale']-scale)<.001
        return {'trials':results,'watchdogRollback':True,'physicalVRR':'not measurable on virtio-vga'}

    def control_center(self):
        self.page('bar')
        before=self.evaluate('Settings.snapshot()')
        try:
            self.evaluate('Settings.openWidgetSettings("control")')
            drawer='shell.auditItems().find(item=>/^DrawerPage_/.test(String(item)))'
            self.wait(drawer+' !== undefined')
            labels=self.evaluate(drawer+'.tabMeta')
            for tab in before['drawerTabs']:
                label='Show the '+labels[tab['id']]['label']+' tab'
                control='shell.auditItems().find(item=>/^Toggle_/.test(String(item)) && item.accessibleName==='+json.dumps(label)+')'
                if tab['id']=='overview':
                    assert self.evaluate(control+'.enabled') is False
                    continue
                for enabled in [False,True]:
                    self.evaluate(control+'.toggled('+json.dumps(enabled)+')')
                    assert next(t for t in self.saved()['drawerTabs'] if t['id']==tab['id'])['on']==enabled
            order=[t['id'] for t in self.evaluate('Settings.drawerTabs')]
            self.evaluate(drawer+'.beginDrag(1);'+drawer+'.moveDrop(1);'+drawer+'.commitTabDrag()')
            changed=self.evaluate('Settings.drawerTabs.map(t=>t.id)')
            assert changed[2]==order[1] and changed[1]==order[2]
            self.evaluate(drawer+'.beginDrag(1);'+drawer+'.moveDrop(-1);'+drawer+'.cancelTabDrag()')
            assert self.evaluate('Settings.drawerTabs.map(t=>t.id)')==changed
            for row in self.evaluate('shell.auditRows()'):
                if row.get('module')!='control' or not row.get('control') or not row['visible'] or row['reason']:continue
                if row['control'].startswith('Toggle_'):
                    for value in [not row['value'],row['value']]:self.edit(value,label=row['label'])
                elif row['control'].startswith('HSlider_'):
                    for value in [row['min'],row['max'],row['value']]:self.edit(value,label=row['label'])
                self.saved()
            self.evaluate('shell.auditItems().find(item=>/^ModulesPage_/.test(String(item))).closeSubPage()')
            return {'allTabToggles':True,'overviewProtected':True,'reorderCommitCancel':True,
                    'overviewSectionsHoverWidth':True}
        finally:
            self.evaluate('Settings.applyValues('+json.dumps(before)+',"Audit restore","")')
            self.saved()

    def hotspot(self):
        subprocess.run(['modprobe','mac80211_hwsim','radios=2'],check=True,capture_output=True)
        try:
            self.user(['nmcli','radio','wifi','on'])
            self.page('network')
            self.evaluate('SystemSettings.network.refresh()')
            self.wait('!SystemSettings.network.loading && SystemSettings.network.snapshot.hotspot.supported')
            group='shell.auditItems().find(item=>/^HotspotGroup_/.test(String(item)))'
            self.edit('Settings audit hotspot',label='Network name')
            self.action('Save')
            self.wait('!SystemSettings.network.busy && !SystemSettings.network.loading')
            assert not self.evaluate(group+'.failure'),self.evaluate(group+'.failure')
            self.edit(True,label='Hotspot')
            self.wait('!SystemSettings.network.busy && !SystemSettings.network.loading',timeout=90)
            assert not self.evaluate(group+'.failure'),self.evaluate(group+'.failure')
            self.wait('SystemSettings.network.snapshot.hotspot.active')
            self.action('Show password and QR code')
            self.wait('NetworkOverlayState.open')
            self.evaluate('NetworkOverlayState.close()')
            self.edit('Settings audit renamed',label='Network name')
            self.action('Save')
            self.wait('!SystemSettings.network.busy && !SystemSettings.network.loading')
            assert not self.evaluate(group+'.failure'),self.evaluate(group+'.failure')
            assert self.evaluate('SystemSettings.network.snapshot.hotspot.ssid')=='Settings audit renamed'
            self.edit(False,label='Hotspot')
            self.wait('!SystemSettings.network.busy && !SystemSettings.network.loading')
            assert not self.evaluate('SystemSettings.network.snapshot.hotspot.active')
            uuid=self.evaluate('SystemSettings.network.snapshot.hotspot.uuid')
            self.user(['nmcli','connection','delete',uuid])
            return {'simulatedKernelRadio':True,'realNetworkManagerAP':True,'rename':True,
                    'joinCard':True,'stop':True,'physicalRadio':'not qualified'}
        finally:
            subprocess.run(['modprobe','-r','mac80211_hwsim'],capture_output=True)

    def multiple_displays(self):
        self.user(['hyprctl','output','create','headless','SETTINGS-AUDIT'])
        try:
            self.page('displays')
            self.evaluate('DisplaySettings.refresh()')
            self.wait('!DisplaySettings.loading && shell.auditPage().drafts.some(d=>d.name==="SETTINGS-AUDIT")')
            second=self.evaluate('shell.auditPage().drafts.find(d=>d.name==="SETTINGS-AUDIT")')
            first=self.evaluate('shell.auditPage().drafts.find(d=>d.name!=="SETTINGS-AUDIT")')
            self.evaluate('shell.auditPage().selectedKey='+json.dumps(second['key']))
            for label,value in [('Mirror',first['key']),('Use this display',False)]:
                self.edit(value,label=label)
                assert not self.evaluate('shell.auditPage().problem'),self.evaluate('shell.auditPage().problem')
                self.action('Apply')
                self.wait('!DisplaySettings.busy && (DisplaySettings.preview !== null || DisplaySettings.error !== "")')
                assert not self.evaluate('DisplaySettings.error'),self.evaluate('DisplaySettings.error')
                self.action('Revert now')
                self.wait('!DisplaySettings.busy && DisplaySettings.preview === null && !DisplaySettings.loading && !shell.auditPage().dirty')
            arrangement='shell.auditItems().find(item=>/^DisplayArrangement_/.test(String(item)))'
            self.evaluate(arrangement+'.nudged('+json.dumps(second['key'])+',"left")')
            assert self.evaluate('shell.auditPage().dirty')
            self.action('Apply')
            self.wait('!DisplaySettings.busy && (DisplaySettings.preview !== null || DisplaySettings.error !== "")')
            assert not self.evaluate('DisplaySettings.error'),self.evaluate('DisplaySettings.error')
            self.action('Revert now')
            self.wait('!DisplaySettings.busy && DisplaySettings.preview === null && !DisplaySettings.loading && !shell.auditPage().dirty')
            return {'secondHeadlessOutput':True,'mirrorTrial':True,'disableTrial':True,'arrangeTrial':True}
        finally:
            self.user(['hyprctl','output','remove','SETTINGS-AUDIT'])

    def late_credentials(self):
        # Run this explicitly just after a fresh graphical login, without
        # --prepare or any preceding test that could initialize Secret Service.
        started=float(Path('/proc/uptime').read_text().split()[0])
        assert started < 90, 'Run late_credentials immediately after a fresh boot/login'
        def owner():
            return self.user(['busctl','--user','call','org.freedesktop.DBus',
                              '/org/freedesktop/DBus','org.freedesktop.DBus',
                              'GetNameOwner','s','org.freedesktop.secrets'])
        initial=owner()  # Queries the bus; does not activate Secret Service.
        while float(Path('/proc/uptime').read_text().split()[0]) < 180:
            time.sleep(5)
        assert owner()==initial, 'The initialized login keyring exited after login'
        locked=self.user(['busctl','--user','get-property','org.freedesktop.secrets',
                          '/org/freedesktop/secrets/collection/login',
                          'org.freedesktop.Secret.Collection','Locked'])
        assert locked=='b false',locked
        try:
            self.user(['secret-tool','store','--label=Settings late-login audit',
                       'cybexos','settings-late-login-audit'],input='late-login-value',timeout=15)
            assert self.user(['secret-tool','lookup','cybexos','settings-late-login-audit'],timeout=15)=='late-login-value'
        finally:
            self.user(['secret-tool','clear','cybexos','settings-late-login-audit'],timeout=15)
        return {'daemonOwnerPreserved':True,'unlockedAfter180SecondsUptime':True,'credentialStoreLookup':True}

    def administration(self):
        def clients():return json.loads(self.user(['hyprctl','clients','-j']))
        def new_window(before):
            deadline=time.monotonic()+30
            while time.monotonic()<deadline:
                windows=[c for c in clients() if c['address'] not in before and c.get('mapped')]
                active=json.loads(self.user(['hyprctl','activewindow','-j']))
                if any(c['address']==active.get('address') for c in windows):return windows
                time.sleep(.2)
            raise AssertionError(clients())
        def close_windows(windows):
            for c in windows:self.user(['hyprctl','dispatch','hl.dsp.window.close({window='+json.dumps('address:'+c['address'])+'})'])
        self.page('recovery')
        self.wait('Maintenance.snapshot.space.total > 0 && !Maintenance.busy')
        for key, values in [('automatic',[True,False]),('keepConfirmed',[5,10,20,50,100]),('keepDays',[30,60,90,180,365])]:
            for value in values:
                labels={'automatic':'Automatic weekly cleanup','keepConfirmed':'Confirmed deployments to keep','keepDays':'Days of recovery history'}
                self.evaluate('shell.auditEdit(I18n.tr('+json.dumps(labels[key])+'),"",'+json.dumps(value)+')')
                actual=self.evaluate('shell.auditPage().draft.'+key)
                assert actual==value,(key,value,actual)
        self.action('Discard')
        assert not self.evaluate('shell.auditPage().dirty')
        self.page('home')
        self.wait('!ShellHealth.busy')
        self.action('Refresh')
        self.wait('!ShellHealth.busy && ShellHealth.serviceActive')
        expected=self.evaluate('Settings.snapshot()')
        unknown=self.saved().get('settingsAuditUnknown')
        self.action('Reset all')
        self.wait('Settings.undoAvailable')
        assert self.saved().get('settingsAuditUnknown')==unknown
        self.evaluate('Settings.undoReset()')
        assert self.evaluate('Settings.snapshot()')==expected
        self.saved()
        # The first Open action is the Welcome guide.
        self.action('Open')
        self.wait('Welcome.open')
        self.evaluate('Welcome.dismiss()')
        self.page('applications')
        self.action('Open Software…')
        self.wait('Software.open')
        self.evaluate('Software.close()')
        self.page('home')
        before={c['address'] for c in clients()}
        self.evaluate('shell.auditWalk(shell.auditRow("Settings file","")).find(i=>/^SettingsAction_/.test(String(i))).triggered()')
        self.wait('!Settings.panelOpen')
        close_windows(new_window(before))
        self.page('wallpaper')
        self.evaluate('shell.auditItems().filter(i=>/^SettingsDisclosure_/.test(String(i))).forEach(i=>i.open=true)')
        original=self.evaluate('Settings.wallDir')
        folder=Path('/home/cybexqa/settings-open-folder-audit');folder.mkdir(exist_ok=True)
        try:
            self.evaluate('Settings.wallDir='+json.dumps(str(folder)))
            self.wait('Wallpaper.dir === '+json.dumps(str(folder)))
            before={c['address'] for c in clients()}
            self.action('Open')
            self.wait('!Settings.panelOpen')
            close_windows(new_window(before))
        finally:
            self.evaluate('Settings.wallDir='+json.dumps(original))
            self.saved();folder.rmdir()
        self.page('accounts')
        self.wait('SystemSettings.accounts.loaded && !SystemSettings.accounts.busy')
        snapshot=self.evaluate('SystemSettings.accounts.snapshot')
        assert snapshot['available'] and not snapshot['accounts'],snapshot
        self.action('Add account')
        self.wait('!Settings.panelOpen')
        deadline=time.monotonic()+30
        while True:
            account=[c for c in clients() if 'onlineaccounts' in c.get('class','').lower() or 'online-accounts' in c.get('class','').lower()]
            if account:break
            assert time.monotonic()<deadline,clients()
            time.sleep(.2)
        for c in account:self.user(['hyprctl','dispatch','hl.dsp.window.close({window='+json.dumps('address:'+c['address'])+'})'])
        self.wait('!SystemSettings.externalBusy')
        for page, action, identity in [('sound','Open','pavucontrol'),('network','Advanced connection editor','nm-connection-editor')]:
            self.page(page)
            self.action(action)
            self.wait('!Settings.panelOpen')
            deadline=time.monotonic()+30
            while True:
                windows=[c for c in clients() if identity in c.get('class','').lower()]
                if windows:break
                assert time.monotonic()<deadline,clients()
                time.sleep(.2)
            for c in windows:self.user(['hyprctl','dispatch','hl.dsp.window.close({window='+json.dumps('address:'+c['address'])+'})'])
            self.wait('!SystemSettings.externalBusy')
        self.page('security')
        self.action('Change password')
        self.wait('!Settings.panelOpen')
        deadline=time.monotonic()+30
        while True:
            password=[c for c in clients() if c.get('title')=='Change your Cybex OS password']
            if password:break
            assert time.monotonic()<deadline,clients()
            time.sleep(.2)
        for c in password:self.user(['hyprctl','dispatch','hl.dsp.window.close({window='+json.dumps('address:'+c['address'])+'})'])
        self.page('about')
        before={c['address'] for c in clients()}
        self.evaluate('Settings.openExternalUrl("https://example.com")')
        self.wait('!Settings.panelOpen')
        close_windows(new_window(before))
        return {'retentionDraftChoices':12,'discard':True,'healthRefresh':True,'resetAllUndo':True,
                'welcome':True,'software':True,'accountsWindow':True,'passwordWindow':True,
                'advancedAudioWindow':True,'advancedNetworkWindow':True,
                'settingsFileVisible':True,'wallpaperFolderVisible':True,'externalBrowserVisible':True}

    def run(self, *, scalars=True):
        self.test('one managed shell before audit', self.guard)
        # Every page, and the second views of the tabbed ones.
        pages = self.evaluate('Settings.validPages') + ['shortcuts', 'recovery', 'storage']
        for page in pages:
            if self.test('page: '+page, lambda page=page:self.inventory(page)) and scalars:
                rows = self.report['pages'][page]
                for row in rows:
                    if row['key'] and row.get('control') and row['visible'] and not row['reason']:
                        self.test('preference: '+row['key'], lambda row=row,page=page:self.scalar(page,row))
        self.test('one managed shell after audit', self.guard)
        self.evaluate('Settings.closePanel()')
        return not any(test['result']=='failed' for test in self.report['tests'])


EXTENDED = ['input_preferences','keyboard_preferences','workspaces','default_applications',
            'display_trial','display_formats','network_trial','network_addresses','vpn',
            'idle_and_night_light','notifications','audio','wallpaper','appearance_extras',
            'bar_layout','widget_options','plugin_lifecycle','persistence_and_reset','backup']
EXTENDED += ['control_center','hotspot','multiple_displays','administration']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--inventory-only',action='store_true')
    parser.add_argument('--prepare',action='store_true',help='Install test instrumentation in the disposable guest only')
    parser.add_argument('--suite',choices=['preferences','extended','all'],default='preferences')
    parser.add_argument('--only',choices=EXTENDED+['late_credentials'],action='append',help='Run selected extended cases')
    args=parser.parse_args()
    audit=Audit(args.report)
    if args.prepare:
        audit.prepare()
    if args.only:
        methods=args.only
    else:
        if args.suite in ['preferences','all']:
            audit.run(scalars=not args.inventory_only)
        methods=EXTENDED if args.suite in ['extended','all'] else []
    for method in methods:
        audit.test(method,getattr(audit,method))
    audit.test('one managed shell at completion',audit.guard)
    raise SystemExit(1 if any(test['result']=='failed' for test in audit.report['tests']) else 0)


if __name__ == '__main__':
    main()
