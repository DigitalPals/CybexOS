import QtQuick
import Quickshell
import "ModelUsage" as ModelUsage

ShellRoot {
    id: root
    property int phase: 0
    property int ticks: 0
    property var form: null
    function check(ok, message) {
        if (!ok) { console.error("POPUP TEST FAILED: " + message); Qt.exit(1); }
    }
    function focused(item) {
        if (!item) return false;
        if (item.activeFocus) return true;
        var children = item.children || [];
        for (var i = 0; i < children.length; i++) if (focused(children[i])) return true;
        return false;
    }
    PanelWindow {
        anchors { top: true; left: true; right: true }
        implicitHeight: 32
        ModelUsage.Panel {
            id: widget
            width: 120
            height: 32
            automaticRefreshEnabled: false
            settings: ({ enabledProviders: [], barProviders: [], costLocalCodex: false,
                costLocalClaude: false, costLocalKimi: false })
        }
    }
    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: {
            root.check(++root.ticks < 80, "timeout at phase " + root.phase);
            if (root.phase === 0) {
                root.check(!widget.popupLoaded && widget.settingsForm === null, "closed popup stays unconstructed");
                widget.showSettings();
                root.check(widget.popupLoaded && widget.settingsForm !== null, "settings construct synchronously");
                root.form = widget.settingsForm;
                root.form.setValue("cliproxyUrl", "http://draft.example:8317");
                root.phase = 1;
            } else if (root.phase === 1 && widget.popup.backingWindowVisible && root.focused(widget.activeSettingsForm)) {
                root.check(widget.activeSettingsForm === root.form, "settings focus target exists");
                widget.close();
                root.check(widget.settingsForm === root.form && widget.popupLoaded, "closing retains popup objects");
                root.check(root.form.draft.cliproxyUrl === "http://draft.example:8317", "closing retains nonsecret draft");
                widget.showCosts();
                root.phase = 2;
            } else if (root.phase === 2 && widget.popup.backingWindowVisible) {
                widget.showCostSettings();
                root.check(widget.costSettingsForm && widget.viewMode === "cost-settings", "cost settings open");
                root.phase = 3;
            } else if (root.phase === 3 && root.focused(widget.activeSettingsForm)) {
                widget.leaveSettings();
                widget.showLimits();
                root.check(widget.settingsForm === root.form && widget.viewMode === "limits", "view switches retain forms");
                widget.close();
                console.log("Model Usage lazy popup lifecycle passed");
                Qt.quit();
            }
        }
    }
}
