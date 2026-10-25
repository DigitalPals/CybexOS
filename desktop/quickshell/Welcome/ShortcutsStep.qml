pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/KeybindEditor.js" as Editor
import "../Common/ShortcutEditor.js" as Helpers
import "../Settings" as SettingsUi
// The keyboard map, the main shortcuts with Edit, and the way into
// Settings → Keyboard shortcuts. Edits are a Keybindings draft like the
// Settings page's, with the same recorder and its own Apply bar here.
Column {
    id: root
    objectName: "welcomeShortcutsStep"
    spacing: Theme.scaled(18)
    property string problem: ""
    property string recordFor: "row"
    readonly property var essentials: [
        "shell.launcher", "shell.settings", "shell.shortcuts", "apps.terminal", "apps.browser",
        "apps.files", "windows.overview", "windows.close"]
    Claim {
        active: root.visible
        onClaimed: Keybindings.acquire()
        onReleased: Keybindings.release()
    }
    Connections {
        target: Keybindings
        function onFailed(message) { root.problem = message; }
        function onApplied() { root.problem = ""; }
    }
    function edit(id) {
        const row = Keybindings.action(id);
        if (!row || !row.editable) return;
        root.problem = "";
        if (row.custom) { form.begin(id); return; }
        recordFor = "row";
        recorderItem()?.start(id, row.label, Keybindings.keysFor(id), true);
    }
    function recorded(combo, mode) {
        if (recordFor === "form") { form.setKeys([combo]); return; }
        const keys = Helpers.nextKeys(Keybindings.keysFor(recorder.actionId), combo, mode);
        if (keys) Keybindings.setKeys(recorder.actionId, keys);
    }
    GuideText {
        width: root.width
        tone: "muted"
        text: I18n.tr("Hold Super and press a letter or digit. Choose any key below to change it, or a lit key to make it open something of yours.")
    }
    GuideText {
        width: root.width
        visible: text !== ""
        tone: root.problem !== "" || Keybindings.error !== "" ? "accent" : "muted"
        text: Keybindings.error !== "" ? Keybindings.error : root.problem !== "" ? root.problem
            : !Keybindings.loaded ? I18n.tr("Loading shortcuts…") : ""
    }
    SettingsUi.ShortcutKeyboardMap {
        objectName: "welcomeShortcutMap"
        width: root.width
        visible: Keybindings.loaded
        onEditRequested: id => root.edit(id)
        onAddRequested: (combo, type) => { root.problem = ""; form.begin("", combo, type); }
    }
    SettingsUi.ShortcutCustomForm {
        id: form
        width: root.width
        onRecordRequested: (exceptId, label, keys) => {
            root.recordFor = "form";
            root.recorderItem()?.start(exceptId, label, keys, false);
        }
    }
    GuideText { width: root.width; text: I18n.tr("The main shortcuts"); font.weight: Theme.weightSemibold }
    Column {
        width: root.width
        spacing: Theme.controlSpacing
        Repeater {
            model: root.essentials
            delegate: Rectangle {
                id: row
                required property string modelData
                readonly property var action: Keybindings.action(modelData)
                width: root.width; height: Theme.scaled(44); radius: Theme.chipRadius; color: Theme.cardFill
                visible: action !== null
                GuideText {
                    anchors.left: parent.left; anchors.leftMargin: Theme.scaled(16); anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - keys.width - edit.width - Theme.scaled(56); elide: Text.ElideRight; maximumLineCount: 1
                    text: row.action ? I18n.tr(row.action.label) : ""
                }
                Keycaps {
                    id: keys
                    anchors.right: edit.left; anchors.rightMargin: Theme.scaled(12); anchors.verticalCenter: parent.verticalCenter
                    combos: Keybindings.keysFor(row.modelData).map(key => Editor.display(key))
                }
                GuideText {
                    anchors.right: edit.left; anchors.rightMargin: Theme.scaled(12); anchors.verticalCenter: parent.verticalCenter
                    visible: Keybindings.keysFor(row.modelData).length === 0; text: I18n.tr("Not bound"); tone: "muted"
                }
                SettingsUi.SettingsAction {
                    id: edit
                    anchors.right: parent.right; anchors.rightMargin: Theme.scaled(6); anchors.verticalCenter: parent.verticalCenter
                    text: I18n.tr("Edit")
                    glyph: "edit"
                    enabled: !!row.action && row.action.editable
                    Accessible.name: I18n.format("Change %1", [row.action ? I18n.tr(row.action.label) : ""])
                    onTriggered: root.edit(row.modelData)
                }
            }
        }
    }
    // Inline, since the guide has no page overlay: the same pending/apply
    // contract as the Settings page's bar.
    Item {
        width: root.width
        height: applyBar.shown ? applyBar.height : 0
        visible: applyBar.shown
        SettingsUi.ApplyBar {
            id: applyBar
            pending: Keybindings.dirty
            radius: Theme.chipRadius
            title: I18n.tr("Shortcut changes not applied yet")
            detail: root.problem !== "" ? root.problem : I18n.tr("Apply reloads Hyprland. Your user.lua still loads last.")
            busy: Keybindings.backend.busy
            applyEnabled: Keybindings.loaded
            onApply: { root.problem = ""; Keybindings.apply(); }
            onDiscard: { root.problem = ""; Keybindings.discard(); }
        }
    }
    SettingsUi.SettingsAction {
        text: I18n.tr("All shortcuts in Settings")
        glyph: "keyboard"
        onTriggered: Settings.showPanel("shortcuts")
    }
    // A modal over the whole guide window, so the step's clipped, scrolling
    // viewport does not hold it. Created straight into the window's content
    // item: an item reparented out of the clipped Flickable was never drawn.
    property SettingsUi.ShortcutRecorder recorder: null
    Component {
        id: recorderComponent
        SettingsUi.ShortcutRecorder {
            objectName: "welcomeShortcutRecorder"
            onAccepted: (combo, mode) => root.recorded(combo, mode)
        }
    }
    // Lazily, on first use: the window is not attached yet at completion.
    function recorderItem(): SettingsUi.ShortcutRecorder {
        if (!recorder && root.QsWindow.contentItem)
            recorder = recorderComponent.createObject(root.QsWindow.contentItem) as SettingsUi.ShortcutRecorder;
        return recorder;
    }
    Component.onDestruction: {
        if (recorder)
            recorder.destroy();
    }
}
