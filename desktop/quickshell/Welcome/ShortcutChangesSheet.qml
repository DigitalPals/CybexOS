pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/KeybindEditor.js" as Editor

// Leaving the Shortcuts step while changes wait: what applying them would
// change, then Apply or Discard, after which the guide goes where the person
// was going (Welcome.leaving). Keep editing, Escape and the scrim close the
// sheet and keep the draft. Apply is focused, so Enter applies.
KioskSheet {
    id: root
    objectName: "welcomeShortcutChanges"
    readonly property bool recovering: Keybindings.readOnly && Keybindings.dirty
    readonly property var changes: Keybindings.changes
    property bool applying: false
    property string problem: ""
    title: root.recovering ? I18n.tr("Reset your shortcuts?") : I18n.tr("Apply your shortcut changes?")
    subtitle: root.recovering
        ? I18n.tr("Apply replaces keybindings.json with the defaults. The broken file is kept beside it as keybindings.json.invalid-<time>.")
        : I18n.tr("Apply reloads Hyprland with them. Discard keeps the shortcuts you had.")
    onClosed: if (!root.applying) Welcome.closeSheet()
    Connections {
        target: Keybindings
        function onApplied() {
            if (!root.applying) return;
            root.applying = false;
            Welcome.proceed();
        }
        function onFailed(message) {
            if (!root.applying) return;
            root.applying = false;
            root.problem = message;
        }
    }
    function apply() {
        root.problem = "";
        if (!Keybindings.dirty) { Welcome.proceed(); return; }
        root.applying = true;
        // A refusal before the request starts reports itself through failed().
        if (!Keybindings.apply() && root.applying) {
            root.applying = false;
            root.problem = Keybindings.error || I18n.tr("Wait for the shortcut change to finish");
        }
    }
    function discard() {
        root.problem = "";
        if (Keybindings.discard()) Welcome.proceed();
        else root.problem = Keybindings.error;
    }
    function spoken(keys, removed) {
        return keys.length ? keys.map(key => Editor.display(key).join(" + ")).join(", ")
            : removed ? I18n.tr("Removed") : I18n.tr("Not bound");
    }

    // One key as the installer's small keycaps, "+N" for its alternatives.
    component Combo: Row {
        id: combo
        property var keys: []
        property bool dim: false
        property bool removed: false
        spacing: Kiosk.px(4)
        Repeater {
            model: combo.keys.length > 0 ? Editor.display(combo.keys[0]) : []
            delegate: Row {
                id: part
                required property string modelData
                required property int index
                spacing: Kiosk.px(4)
                KioskText { anchors.verticalCenter: parent.verticalCenter; visible: part.index > 0; text: "+"; size: 12; tone: "faint" } // i18n: untranslated (key separator)
                KioskKeycap { anchors.verticalCenter: parent.verticalCenter; small: true; text: part.modelData; locked: combo.dim }
            }
        }
        KioskText {
            anchors.verticalCenter: parent.verticalCenter
            visible: combo.keys.length > 1
            text: "+" + (combo.keys.length - 1) // i18n: untranslated (count)
            mono: true
            size: 12
            tone: "faint"
        }
        KioskText {
            anchors.verticalCenter: parent.verticalCenter
            visible: combo.keys.length === 0
            text: combo.removed ? I18n.tr("Removed") : I18n.tr("Not bound")
            size: 14
            tone: "faint"
        }
    }

    Rectangle {
        id: summary
        visible: root.changes.length > 0
        width: parent.width
        height: Math.min(list.contentHeight + Kiosk.px(12), status.y - Kiosk.px(16))
        radius: Kiosk.px(14)
        color: Kiosk.bgDeep
        border.width: Math.max(1, Kiosk.px(1))
        border.color: Kiosk.line
        ListView {
            id: list
            objectName: "welcomeShortcutChangeList"
            anchors.fill: parent
            anchors.margins: Kiosk.px(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.changes
            delegate: Item {
                id: change
                required property var modelData
                required property int index
                width: list.width
                height: rows.implicitHeight + Kiosk.px(22)
                Accessible.role: Accessible.StaticText
                Accessible.name: I18n.format("%1: %2 to %3", [label.text, root.spoken(modelData.before, false),
                    root.spoken(modelData.after, modelData.removed)])
                Rectangle {
                    x: Kiosk.px(12)
                    width: parent.width - Kiosk.px(24)
                    height: Math.max(1, Kiosk.px(1))
                    color: Kiosk.line
                    visible: change.index > 0
                }
                Column {
                    id: rows
                    x: Kiosk.px(12)
                    y: Kiosk.px(11)
                    width: parent.width - Kiosk.px(24)
                    spacing: Kiosk.px(8)
                    KioskText {
                        id: label
                        width: parent.width
                        text: change.modelData.custom ? change.modelData.label : I18n.actionLabel(change.modelData.label)
                        size: 15
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Row {
                        spacing: Kiosk.px(10)
                        Combo {
                            anchors.verticalCenter: parent.verticalCenter
                            keys: change.modelData.before
                            dim: true
                        }
                        KioskIcon { anchors.verticalCenter: parent.verticalCenter; name: "arrow_forward"; designSize: 14; color: Kiosk.faint }
                        Combo {
                            anchors.verticalCenter: parent.verticalCenter
                            keys: change.modelData.after
                            removed: change.modelData.removed
                        }
                    }
                }
            }
        }
    }
    KioskText {
        id: status
        anchors.bottom: actions.top
        anchors.bottomMargin: Kiosk.px(12)
        width: parent.width
        visible: text !== ""
        text: root.problem !== "" ? root.problem : root.applying ? I18n.tr("Applying…") : ""
        size: 13.5
        tone: root.problem !== "" ? "red" : "fog"
        wrapMode: Text.WordWrap
    }
    Row {
        id: actions
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        spacing: Kiosk.px(12)
        KioskButton {
            small: true
            text: I18n.tr("Keep editing")
            enabled: !root.applying
            onClicked: Welcome.closeSheet()
        }
        KioskButton {
            objectName: "welcomeShortcutDiscard"
            small: true
            text: I18n.tr("Discard")
            enabled: !root.applying && !Keybindings.backend.busy
            onClicked: root.discard()
        }
        KioskButton {
            objectName: "welcomeShortcutApply"
            small: true
            kind: "primary"
            focus: true
            text: root.applying ? I18n.tr("Applying…") : I18n.tr("Apply")
            enabled: !root.applying && Keybindings.loaded && !Keybindings.backend.busy
            onClicked: root.apply()
        }
    }
}
