import QtQuick
import Quickshell
import "Common"
import "Bar"

ShellRoot {
    id: root
    property int attempts: 0
    property bool finished: false
    property bool saved: false
    property var runningPomodoro: null
    property bool openedPopup: false
    property var hosts: []

    function done(ok, detail) {
        if (finished)
            return;
        finished = true;
        console.warn("USER_WIDGET_RESULT " + (ok ? "pass " : "fail ") + detail);
        Quickshell.execDetached(["/usr/bin/bash", "-c",
            "sleep 0.2; kill -TERM -- \"$1\"", "bash", String(Quickshell.processId)]);
    }

    Component {
        id: factory
        UserWidgetHost {
            width: 120
            height: 30
            screenName: "test-output"
            themeValues: ({ foreground: "#ffffff", background: "#000000", accent: "#00ff00",
                fontFamily: "sans-serif", fontSize: 13, reducedMotion: true })
            onSettingRequested: (pluginId, key, value) => UserPlugins.setSetting(pluginId, key, value)
        }
    }
    PanelWindow {
        id: canvas
        anchors { top: true; left: true; right: true }
        implicitHeight: 32
        UserWidgets {
            id: barWidgets
            screenName: "test-output"
            availableWidth: 320
        }
    }
    Timer {
        interval: 100
        repeat: true
        running: !root.finished
        onTriggered: {
            if (++root.attempts > 90) {
                root.done(false, "timeout: " + UserPlugins.error + " " + root.hosts.map(h => h.error));
                return;
            }
            if (UserPlugins.plugins.length !== 5)
                return;
            if (root.hosts.length === 0) {
                for (const descriptor of UserPlugins.plugins) {
                    if (descriptor.format === "omarchy")
                        continue;
                    const host = factory.createObject(canvas, { descriptor: descriptor });
                    if (!host) {
                        root.done(false, "host construction failed");
                        return;
                    }
                    root.hosts.push(host);
                }
            }
            const good = root.hosts.find(h => h.descriptor.id === "example.good");
            const bad = root.hosts.find(h => h.descriptor.id === "example.broken");
            const future = root.hosts.find(h => h.descriptor.id === "example.future");
            const pomodoro = barWidgets.children.find(h => h.descriptor && h.descriptor.id === "markbusking.pomodoro");
            const spacer = barWidgets.children.find(h => h.descriptor && h.descriptor.id === "Example.Spacer_v1");
            if (!pomodoro || !spacer || !pomodoro.ready || !spacer.ready) {
                if (pomodoro && pomodoro.error)
                    root.done(false, pomodoro.error);
                if (spacer && spacer.error)
                    root.done(false, spacer.error);
                return;
            }
            if (!good.ready || !bad.error || !future.error)
                return;
            if (bad.ready || future.ready || !good.widget.apiContract
                    || good.widget.text !== "preserved:1:test-output") {
                root.done(false, "API or isolation contract failed");
                return;
            }
            if (!root.openedPopup) {
                pomodoro.widget.open();
                root.openedPopup = true;
                return;
            }
            const popup = pomodoro.widget.data.find(item => item.anchorItem !== undefined
                && item.backingWindowVisible !== undefined);
            if (!popup || !popup.backingWindowVisible || !popup.focusTarget.activeFocus)
                return;
            if (!pomodoro.widget.opened || UserPlugins.activePopout !== pomodoro.widget) {
                root.done(false, "popup ownership failed");
                return;
            }
            if (Quickshell.env("WIDGET_TEST_WRITE") === "1" && !root.saved) {
                good.widget.pluginApi.setSetting("savedByWidget", true);
                spacer.widget.bar.shell.updateEntryInline("Example.Spacer_v1", { size: 51 });
                root.runningPomodoro = pomodoro.widget;
                pomodoro.widget.toggleTimer();
                root.saved = true;
                return;
            }
            if (root.saved && !UserPlugins.plugins.find(p => p.id === "example.good").settings.savedByWidget)
                return;
            if (root.saved) {
                if (spacer.widget.span !== 51)
                    return;
                if (pomodoro.widget !== root.runningPomodoro || !pomodoro.widget.running
                        || pomodoro.widget.phase !== "work" || pomodoro.widget.remainingSeconds <= 0) {
                    root.done(false, "settings refresh destroyed timer state");
                    return;
                }
                pomodoro.widget.resetPhase();
            }
            if (pomodoro.widget.workMinutes !== 2 || pomodoro.widget.soundEnabled
                    || !spacer.widget.settings.preserved
                    || spacer.widget.bar.moduleWidgets("Example.Spacer_v1").length !== 1) {
                root.done(false, "Omarchy settings or broadcast contract failed");
                return;
            }
            if (barWidgets.implicitWidth > 320 || barWidgets.hiddenWidgets.length === 0) {
                root.done(false, "widget display budget failed");
                return;
            }
            Popouts.openPanel("audio", "right");
            if (pomodoro.widget.opened || UserPlugins.activePopout) {
                root.done(false, "native popout did not dismiss plugin popup");
                return;
            }
            Popouts.close();
            good.descriptor = Object.assign({}, good.descriptor, { error: "Rejected test manifest" });
            if (good.ready) {
                root.done(false, "invalidated manifest kept its widget alive");
                return;
            }
            for (const host of root.hosts)
                host.destroy();
            root.done(true, "external package loaded; invalid widgets isolated; API survived");
        }
    }
}
