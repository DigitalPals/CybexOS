pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/KeybindEditor.js" as Editor
import "../Common/ShortcutEditor.js" as Helpers
import "../Settings" as SettingsUi
// The keyboard map, the main shortcuts with Edit, and the way into
// Settings → Keyboard shortcuts. Edits are a Keybindings draft like the
// Settings page's, with the same recorder and its own Apply bar here. A
// rejected keybindings.json makes the step read only except Reset all.
Column {
    id: root
    objectName: "welcomeShortcutsStep"
    spacing: Theme.scaled(18)
    property string problem: ""
    property string recordFor: "row"
    readonly property bool readOnly: Keybindings.readOnly
    readonly property bool recovering: Keybindings.readOnly && Keybindings.dirty
    readonly property string message: Keybindings.error !== "" && Keybindings.error !== Keybindings.preferencesError
        ? Keybindings.error : root.problem
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
        if (!row || !row.editable || root.readOnly) return;
        root.problem = "";
        if (row.custom) { form.begin(id); return; }
        recordFor = "row";
        recorderItem()?.start(id, row.label, row.keys, true, Helpers.lockedKeys(row));
    }
    function recorded(combo, mode) {
        if (recordFor === "form") { form.setKeys([combo]); return; }
        // A protected action's locked defaults stay; only its extra keys change.
        const keys = Helpers.nextKeys(Helpers.editableKeys(Keybindings.action(recorder.actionId)), combo, mode);
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
        tone: root.message !== "" ? "accent" : "muted"
        text: root.message !== "" ? root.message : !Keybindings.loaded ? I18n.tr("Loading shortcuts…") : ""
    }
    // keybindings.json was rejected: say why, and offer only Reset all.
    Rectangle {
        objectName: "welcomeShortcutsReadOnly"
        width: root.width
        height: readOnlyBody.implicitHeight + Theme.scaled(32)
        visible: root.readOnly
        radius: Theme.chipRadius
        color: Theme.cardFill
        border.width: 1
        border.color: root.recovering ? Theme.amberBorder : Theme.redBorder
        Column {
            id: readOnlyBody
            x: Theme.scaled(16); y: Theme.scaled(16); width: parent.width - Theme.scaled(32)
            spacing: Theme.controlSpacing
            Row {
                width: parent.width; spacing: Theme.controlSpacing
                Sym { id: readOnlyIcon; name: root.recovering ? "warning" : "error"; size: Theme.iconMedium; color: root.recovering ? Theme.amber : Theme.redText }
                GuideText {
                    width: parent.width - readOnlyIcon.width - parent.spacing
                    text: Keybindings.preferencesError; font.weight: Theme.weightSemibold
                }
            }
            GuideText {
                width: parent.width; tone: "muted"
                text: root.recovering
                    ? I18n.tr("Reset pending. Apply to replace keybindings.json with the defaults; the broken file is kept beside it as keybindings.json.invalid-<time>.")
                    : I18n.tr("The default shortcuts are in effect and cannot be changed until the file is fixed. Reset all replaces it with the defaults when you apply, and keeps the broken file beside it as keybindings.json.invalid-<time>.")
            }
            SettingsUi.SettingsAction {
                visible: !root.recovering
                text: I18n.tr("Reset all shortcuts")
                glyph: "undo"
                danger: true
                enabled: Keybindings.loaded && !Keybindings.backend.busy
                onTriggered: { root.problem = ""; Keybindings.resetAll(); }
            }
        }
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
                    text: row.action ? I18n.actionLabel(row.action.label) : ""
                }
                Keycaps {
                    id: keys
                    anchors.right: edit.left; anchors.rightMargin: Theme.scaled(12); anchors.verticalCenter: parent.verticalCenter
                    combos: Keybindings.keysFor(row.modelData).map(key => Editor.display(key))
                    // A protected action's defaults always stay: drawn locked.
                    locked: Keybindings.keysFor(row.modelData).map(key => Helpers.lockedKeys(row.action).some(other => Editor.same(key, other)))
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
                    enabled: !!row.action && row.action.editable && !root.readOnly
                    Accessible.name: I18n.format("Change %1", [row.action ? I18n.actionLabel(row.action.label) : ""])
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
            detail: root.problem !== "" ? root.problem
                : root.recovering ? I18n.tr("Apply replaces keybindings.json with the defaults. The broken file is kept beside it as keybindings.json.invalid-<time>.")
                : I18n.tr("Apply reloads Hyprland. Your user.lua still loads last.")
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
