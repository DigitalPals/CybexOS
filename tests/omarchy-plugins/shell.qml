pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "Common"
import "Bar"
import "Settings"

ShellRoot {
    id: root
    property int attempts: 0
    property int stage: 0
    property var savedService: null
    property var savedPanel: null
    property bool finished: false
    property bool ipcChecked: false

    FloatingWindow {
        visible: true
        implicitWidth: 650
        implicitHeight: 600
        PluginsPage { anchors.fill: parent }
    }

    Process {
        id: ipcCheck
        command: ["python3", "-c", "import subprocess,sys,json; h=sys.argv[1]; call=lambda *a: subprocess.check_output([h,'shell',*a],text=True).strip(); assert call('ping')=='pong'; assert 'bar' in json.loads(call('listShellConfig')); assert call('reloadConfig')=='ok'; assert call('putBarWidget','markbusking.pomodoro','{}')=='ok'; assert call('moveBarWidget','markbusking.pomodoro','{\"section\":\"bad\"}')=='invalid section'; assert call('applyTheme','YWNjZW50ID0gXCIjMTIzNDU2XCI=','')=='ok'; print('pong')", Quickshell.shellDir + "/compat/omarchy/bin/omarchy-shell"]
        stdout: StdioCollector {
            onStreamFinished: { root.ipcChecked = root.check(text.trim() === "pong", "bundled IPC helper ping: " + text); }
        }
    }

    function done(ok, detail) {
        if (finished) return;
        finished = true;
        console.warn("OMARCHY_PARITY " + (ok ? "pass " : "fail ") + detail);
        Quickshell.execDetached(["bash", "-c", 'sleep 0.2; kill -TERM -- "$1"', "bash", String(Quickshell.processId)]);
    }
    function check(value, detail) {
        if (!value) { done(false, detail); return false; }
        return true;
    }
    function entry(id, kind) {
        const record = OmarchyPlugins.records[id + ":" + kind];
        return record && record.host ? record.host.instance : null;
    }
    function cli(args) { UserPlugins.enqueue(["python3", UserPlugins.helper].concat(args)); }

    Variants {
        model: OmarchyPlugins.replacementActive ? [] : Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; left: true; right: true }
            implicitHeight: 32
            Row {
                UserWidgets { section: "left"; screenName: modelData.name; availableWidth: 640 }
                UserWidgets { section: "right"; screenName: modelData.name; availableWidth: 640 }
            }
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: !root.finished
        onTriggered: {
            if (++root.attempts > 280) {
                root.done(false, "timeout at " + root.stage + " " + JSON.stringify(OmarchyPlugins.errors)
                    + " " + UserPlugins.widgetHosts.map(h => h.error));
                return;
            }
            if (root.stage === 0) {
                const shared = OmarchyPlugins.serviceFor("example.bundle");
                const panel = root.entry("example.bundle", "panel");
                const media = OmarchyPlugins.serviceFor("omarchy.media");
                const widgets = UserPlugins.widgetHosts.filter(h => h.descriptor.id === "example.bundle" && h.ready);
                if (!shared || !panel || !media || widgets.length !== Quickshell.screens.length * 2) return;
                const first = widgets.filter(h => h.descriptor.instanceName === "one");
                const second = widgets.filter(h => h.descriptor.instanceName === "two");
                if (!root.check(first.every(h => h.widget.settings.label === "first")
                        && second.every(h => h.widget.settings.label === "second"), "independent instance settings")) return;
                first[0].widget.saveLabel("changed");
                ipcCheck.running = true;
                if (!root.check(widgets.every(h => h.widget.shared === shared), "per-output widgets must share one service")) return;
                if (!root.check(panel.service === shared && shared.shell.serviceFor("example.bundle") === shared,
                        "service injection and self lookup")) return;
                if (!root.check(shared.shell.serviceFor("omarchy.media") === null, "service facade escaped its scope")) return;
                if (!root.check(!shared.manifest.__isFirstParty && shared.manifest.__hostCapabilities.length === 0,
                        "untrusted manifest gained host capabilities")) return;
                root.savedService = shared;
                shared.increment("");
                OmarchyPlugins.summon("example.bundle", '{"first":1}');
                OmarchyPlugins.summon("example.bundle", '{"second":2}');
                if (!root.check(panel.received.length === 2 && panel.received[1] === '{"second":2}', "summon payload delivery")) return;
                OmarchyPlugins.hide("example.bundle");
                if (!root.check(!panel.opened && root.entry("example.bundle", "panel") === panel, "keepLoaded panel lifetime")) return;
                OmarchyPlugins.summon("example.overlay", "overlay-payload");
                OmarchyPlugins.summon("example.menu", "menu-payload");
                root.stage++;
            } else if (root.stage === 1) {
                const menu = root.entry("example.menu", "menu");
                const overlay = root.entry("example.overlay", "overlay");
                if (!menu || !overlay || !menu.opened || !overlay.opened || !root.ipcChecked) return;
                if (!root.check(menu.shell.appLibrary !== null
                        && Array.isArray(menu.shell.appLibrary.sortedEntries("")), "menu application library")) return;
                if (!root.check(OmarchyPlugins.call("example.overlay", "echo", "payload") === "payload", "method routing")) return;
                OmarchyPlugins.hide("example.overlay");
                if (!root.check(root.entry("example.overlay", "overlay") === null, "on-demand overlay did not unload")) return;
                menu.shell.updateEntryInline("example.menu", { persisted: true, nested: { preserved: 7 } });
                root.stage++;
            } else if (root.stage === 2) {
                const menu = UserPlugins.plugins.find(p => p.id === "example.menu");
                if (!menu.settings.persisted) return;
                const widgets = UserPlugins.widgetHosts.filter(h => h.descriptor.id === "example.bundle" && h.ready);
                if (!widgets.every(h => h.widget.settings.label === (h.descriptor.instanceName === "one" ? "changed" : "second"))) return;
                if (!root.check(OmarchyPlugins.serviceFor("example.bundle") === root.savedService
                        && root.savedService.count === 1, "settings refresh recreated shared service")) return;
                root.savedPanel = root.entry("example.bundle", "panel");
                const item = UserPlugins.plugins.find(p => p.id === "example.bundle");
                UserPlugins.enqueue(["python3", "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('var revision = 2;\\n')", item.packagePath + "/ReloadProbe.js"]);
                root.stage = 20;
            } else if (root.stage === 20) {
                const widgets = UserPlugins.widgetHosts.filter(h => h.descriptor.id === "example.bundle" && h.ready);
                if (widgets.length !== Quickshell.screens.length * 2 || !widgets.every(h => h.widget.reloadRevision === 2)) return;
                if (!root.check(OmarchyPlugins.serviceFor("example.bundle") === root.savedService
                    && root.savedService.count === 1, "hot reload discarded keepLoaded service")) return;
                if (!root.check(root.entry("example.bundle", "panel") !== root.savedPanel, "panel code did not reload")) return;
                root.cli(["bar", "omarchy.bar"]);
                root.stage = 3;
            } else if (root.stage === 3) {
                const bar = root.entry("omarchy.bar", "bar");
                if (!bar || !OmarchyPlugins.replacementActive) return;
                if (!root.check(bar.barWidgetRegistry.has("markbusking.pomodoro"), "replacement widget catalogue")) return;
                if (!root.check(bar.shell.pluginShellForBarEntry("omarchy.bar", "example.bundle").serviceFor("example.bundle") === null,
                        "replacement entry facade exposes shared services")) return;
                for (const id of ["omarchy.idle", "omarchy.nightlight", "omarchy.notifications", "omarchy.media"])
                    if (!root.check(bar.shell.firstPartyServiceFor(id) !== null, "missing first-party proxy " + id)) return;
                if (!root.check(bar.shell.firstPartyServiceFor("omarchy.lock") === null, "authentication service exposed")) return;
                if (!root.check(OmarchyPlugins.placeWidget("markbusking.pomodoro", "{}", "put") === "ok", "idempotent put")) return;
                if (!root.check(OmarchyPlugins.placeWidget("markbusking.pomodoro", '{"section":"invalid"}', "move") === "invalid section", "placement validation")) return;
                root.cli(["bar", "omarchy.bar", "--position", "left"]);
                root.stage++;
            } else if (root.stage === 4) {
                const bar = root.entry("omarchy.bar", "bar");
                if (!bar || bar.position !== "left") return;
                if (!root.check(root.entry("example.menu", "menu").shell.bar.position === "left",
                        "menu bar geometry did not follow replacement")) return;
                root.cli(["bar", "example.badbar"]);
                root.stage++;
            } else if (root.stage === 5) {
                if (!OmarchyPlugins.errors["example.badbar:bar"] || OmarchyPlugins.replacementActive) return;
                if (!root.check(root.entry("omarchy.bar", "bar") === null, "old replacement was not retired")) return;
                root.cli(["disable", "example.bundle"]);
                root.cli(["disable", "example.menu"]);
                root.cli(["bar", "native"]);
                root.stage++;
            } else if (root.stage === 6) {
                if (UserPlugins.plugins.some(p => ["example.bundle", "example.menu"].includes(p.id) && p.enabled)) return;
                if (OmarchyPlugins.serviceFor("example.bundle") || root.entry("example.bundle", "panel")
                        || root.entry("example.menu", "menu")) return;
                if (OmarchyPlugins.replacementActive) return;
                const widgets = UserPlugins.widgetHosts.filter(h => h.descriptor.id === "markbusking.pomodoro" && h.ready);
                if (widgets.length !== Quickshell.screens.length) return;
                root.done(true, "all six kinds, shared lifetime, settings, vertical replacement, failure recovery and disable");
            }
        }
    }
}
