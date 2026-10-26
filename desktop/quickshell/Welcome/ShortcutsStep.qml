pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/KeybindEditor.js" as Editor
import "../Common/ShortcutEditor.js" as Helpers
import "../Settings" as SettingsUi

// Shortcuts: the Super keys as a keyboard on the left, the essentials in the
// installer's summary rows on the right. Both read the live Keybindings
// model, as Settings does, and edits use the same recorder and the same
// pending draft. Nothing is applied here: leaving the step with changes
// waiting asks to apply or discard them (ShortcutChangesSheet). A rejected
// keybindings.json leaves only Reset all.
Item {
    id: root
    objectName: "welcomeShortcutsStep"
    property string problem: ""
    readonly property bool readOnly: Keybindings.readOnly
    readonly property bool recovering: Keybindings.readOnly && Keybindings.dirty
    readonly property string message: Keybindings.error !== "" && Keybindings.error !== Keybindings.preferencesError
        ? Keybindings.error : root.problem
    readonly property var essentials: ["shell.launcher", "apps.terminal", "apps.browser", "apps.files",
        "windows.overview", "windows.close", "shell.settings", "shell.shortcuts"]
    readonly property var key: map.selectedKey
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
        // Custom entries keep their full form in Settings.
        if (row.custom) { root.openSettings(); return; }
        root.recorderItem()?.start(id, row.label, row.keys, true, Helpers.lockedKeys(row));
    }
    function recorded(combo, mode) {
        // A protected action's locked defaults stay; only its extra keys change.
        const keys = Helpers.nextKeys(Helpers.editableKeys(Keybindings.action(recorder.actionId)), combo, mode);
        if (keys) Keybindings.setKeys(recorder.actionId, keys);
    }
    function openSettings() {
        Welcome.stepAside(false);
        Settings.showPanel("shortcuts");
    }
    function describe(key) {
        if (!key) return "";
        if (root.readOnly) return I18n.tr("Shortcuts cannot be changed until keybindings.json is reset.");
        if (key.free) return I18n.tr("This key is free. Settings can make it open an app, a website or a command.");
        if (key.reservedBy) return I18n.tr("A protected shortcut always keeps this key.");
        if (key.owner.source === "user") return I18n.tr("Set in ~/.config/cybexos/hypr/user.lua. Change it there.");
        if (key.shared) return key.owners.map(owner => map.label(owner)).join(", ");
        if (key.protected) return I18n.format("%1 always keeps this key. You can give it other keys as well.", [map.label(key.owner)]);
        if (!key.owner.editable) return I18n.tr("This shortcut cannot be changed here.");
        return I18n.actionLabel(key.owner.group);
    }

    Column {
        id: heading
        x: Kiosk.px(64)
        y: Kiosk.px(34)
        width: parent.width - Kiosk.px(128)
        spacing: Kiosk.px(8)
        KioskText {
            width: parent.width
            text: I18n.tr("Your keyboard has superpowers.")
            size: 40
            font.weight: Font.Bold
            font.letterSpacing: -Kiosk.px(1)
            elide: Text.ElideRight
            Accessible.role: Accessible.Heading
        }
        KioskText {
            width: parent.width
            text: I18n.tr("Lit keys do something while you hold Super, the key with the Windows logo. Choose one to change it.")
            size: 19
            tone: "fog"
            elide: Text.ElideRight
        }
    }

    KioskCard {
        id: keyboard
        x: Kiosk.px(64)
        anchors.top: heading.bottom
        anchors.topMargin: Kiosk.px(22)
        width: parent.width - Kiosk.px(128) - essentialsCard.width - Kiosk.px(32)
        height: keyboardBody.implicitHeight + Kiosk.px(38)
        Column {
            id: keyboardBody
            x: Kiosk.px(22)
            y: Kiosk.px(18)
            width: parent.width - Kiosk.px(44)
            Item {
                width: parent.width
                height: Kiosk.px(26)
                KioskKicker { anchors.left: parent.left; text: I18n.tr("Super + …") }
                KioskText {
                    anchors.right: parent.right
                    text: Keybindings.loaded ? I18n.format("%1 keys in use", [map.used]) : I18n.tr("Loading shortcuts…")
                    mono: true
                    size: 12
                    tone: "faint"
                }
            }
            KioskKeyMap {
                id: map
                objectName: "welcomeShortcutMap"
                width: parent.width
                visible: Keybindings.loaded
            }
            Item { width: 1; height: Kiosk.px(16) }
            Rectangle { width: parent.width; height: Math.max(1, Kiosk.px(1)); color: Kiosk.line }
            Item { width: 1; height: Kiosk.px(14) }
            // What the chosen key does, or why shortcuts are paused.
            Item {
                width: parent.width
                height: Math.max(Kiosk.px(44), detail.implicitHeight)
                visible: !root.readOnly
                Row {
                    id: chosenKeys
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Kiosk.px(6)
                    visible: root.key !== null
                    KioskKeycap { anchors.verticalCenter: parent.verticalCenter; text: "Super" } // i18n: untranslated (key name)
                    KioskText { anchors.verticalCenter: parent.verticalCenter; text: "+"; size: 13; tone: "faint" } // i18n: untranslated (key separator)
                    KioskKeycap { anchors.verticalCenter: parent.verticalCenter; text: root.key ? root.key.key : "" }
                }
                Column {
                    id: detail
                    anchors.left: chosenKeys.visible ? chosenKeys.right : parent.left
                    anchors.leftMargin: chosenKeys.visible ? Kiosk.px(16) : 0
                    anchors.right: keyAction.left
                    anchors.rightMargin: Kiosk.px(12)
                    anchors.verticalCenter: parent.verticalCenter
                    KioskText {
                        width: parent.width
                        text: !root.key ? I18n.tr("Choose a key to see what it does.")
                            : root.key.free ? I18n.tr("Free")
                            : root.key.reservedBy ? I18n.actionLabel(root.key.reservedBy.label) : map.label(root.key.owner)
                        size: 17
                        font.weight: Font.DemiBold
                        tone: root.key ? "ink" : "fog"
                        elide: Text.ElideRight
                    }
                    KioskText {
                        width: parent.width
                        visible: text !== ""
                        text: root.problem !== "" ? root.problem : root.describe(root.key)
                        size: 14
                        tone: root.problem !== "" ? "red" : "fog"
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                }
                KioskButton {
                    id: keyAction
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    small: true
                    visible: root.key !== null && (root.key.free || root.key.shared || root.key.owner.editable)
                        && !root.key.reservedBy && (!root.key.owner || root.key.owner.source !== "user")
                    icon: root.key && root.key.free ? "" : "edit"
                    text: !root.key ? "" : root.key.free ? I18n.tr("Open in Settings")
                        : root.key.shared ? I18n.tr("Sort out in Settings") : I18n.tr("Change key")
                    onClicked: {
                        if (root.key.free || root.key.shared) root.openSettings();
                        else root.edit(root.key.owner.id);
                    }
                }
            }
            Rectangle {
                objectName: "welcomeShortcutsReadOnly"
                visible: root.readOnly
                width: parent.width
                height: readOnlyBody.implicitHeight + Kiosk.px(28)
                radius: Kiosk.px(14)
                color: root.recovering ? Kiosk.amberTint : Kiosk.redTint
                border.width: Math.max(1, Kiosk.px(1))
                border.color: root.recovering ? Kiosk.amberLine : Kiosk.redLine
                Column {
                    id: readOnlyBody
                    x: Kiosk.px(16)
                    y: Kiosk.px(14)
                    width: parent.width - Kiosk.px(32)
                    spacing: Kiosk.px(6)
                    KioskText {
                        width: parent.width
                        text: Keybindings.preferencesError
                        size: 15
                        font.weight: Font.DemiBold
                        wrapMode: Text.WordWrap
                    }
                    KioskText {
                        width: parent.width
                        visible: text !== ""
                        text: Keybindings.preferencesDetail
                        mono: true
                        size: 12
                        tone: "faint"
                        wrapMode: Text.WordWrap
                    }
                    KioskText {
                        width: parent.width
                        text: root.recovering
                            ? I18n.tr("Reset pending. Continue asks whether to apply it, which replaces keybindings.json with the defaults and keeps the broken file beside it as keybindings.json.invalid-<time>.")
                            : I18n.tr("The default shortcuts are in effect and cannot be changed until the file is fixed. Reset all replaces it with the defaults when you apply, and keeps the broken file beside it as keybindings.json.invalid-<time>.")
                        size: 13.5
                        tone: "fog"
                        wrapMode: Text.WordWrap
                    }
                    KioskButton {
                        visible: !root.recovering
                        small: true
                        kind: "danger"
                        icon: "undo"
                        text: I18n.tr("Reset all shortcuts")
                        enabled: Keybindings.loaded && !Keybindings.backend.busy
                        onClicked: { root.problem = ""; Keybindings.resetAll(); }
                    }
                }
            }
        }
    }

    KioskCard {
        id: essentialsCard
        anchors.right: parent.right
        anchors.rightMargin: Kiosk.px(64)
        anchors.top: keyboard.top
        width: Kiosk.px(384)
        height: essentials.implicitHeight + Kiosk.px(20)
        Column {
            id: essentials
            x: Kiosk.px(20)
            y: Kiosk.px(6)
            width: parent.width - Kiosk.px(40)
            Item {
                width: parent.width
                height: Kiosk.px(44)
                KioskKicker { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("The essentials") }
                KioskText {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.tr("Super + K shows all")
                    mono: true
                    size: 12
                    tone: "faint"
                }
            }
            Repeater {
                model: root.essentials
                delegate: Item {
                    id: row
                    required property string modelData
                    required property int index
                    readonly property var action: Keybindings.action(modelData)
                    readonly property var keys: Keybindings.keysFor(modelData)
                    readonly property bool locked: keys.length > 0 && Helpers.lockedKeys(action).some(other => Editor.same(keys[0], other))
                    width: essentials.width
                    height: Kiosk.px(45)
                    visible: action !== null
                    Rectangle { width: parent.width; height: Math.max(1, Kiosk.px(1)); color: Kiosk.line; visible: row.index > 0 }
                    KioskText {
                        anchors.left: parent.left
                        anchors.right: caps.left
                        anchors.rightMargin: Kiosk.px(8)
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.action ? I18n.actionLabel(row.action.label) : ""
                        size: 15
                        elide: Text.ElideRight
                    }
                    Row {
                        id: caps
                        anchors.right: lock.left
                        anchors.rightMargin: Kiosk.px(4)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Kiosk.px(4)
                        Repeater {
                            model: row.keys.length > 0 ? Editor.display(row.keys[0]) : []
                            delegate: Row {
                                id: part
                                required property string modelData
                                required property int index
                                spacing: Kiosk.px(4)
                                KioskText { anchors.verticalCenter: parent.verticalCenter; visible: part.index > 0; text: "+"; size: 12; tone: "faint" } // i18n: untranslated (key separator)
                                KioskKeycap { anchors.verticalCenter: parent.verticalCenter; small: true; text: part.modelData; locked: row.locked }
                            }
                        }
                        KioskText {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: row.keys.length > 1
                            text: "+" + (row.keys.length - 1) // i18n: untranslated (count)
                            mono: true
                            size: 12
                            tone: "faint"
                        }
                        KioskText {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: row.keys.length === 0
                            text: I18n.tr("Not bound")
                            size: 14
                            tone: "faint"
                        }
                    }
                    Item {
                        id: lock
                        anchors.right: edit.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Kiosk.px(18)
                        height: width
                        KioskIcon { anchors.centerIn: parent; visible: row.locked; name: "lock"; designSize: 13; color: Kiosk.faint }
                    }
                    Rectangle {
                        id: edit
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: Kiosk.px(30)
                        height: width
                        radius: Kiosk.px(8)
                        readonly property bool usable: !!row.action && row.action.editable && !root.readOnly
                        color: editMouse.containsMouse && usable ? Kiosk.card2 : "transparent"
                        opacity: usable ? 1 : 0.35
                        activeFocusOnTab: usable
                        Accessible.role: Accessible.Button
                        Accessible.name: I18n.format("Change %1", [row.action ? I18n.actionLabel(row.action.label) : ""])
                        Accessible.onPressAction: root.edit(row.modelData)
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                root.edit(row.modelData);
                                event.accepted = true;
                            }
                        }
                        KioskFocusRing { visible: edit.activeFocus; gap: 2; baseRadius: edit.radius }
                        KioskIcon { anchors.centerIn: parent; name: "edit"; designSize: 16; color: editMouse.containsMouse ? Kiosk.ink : Kiosk.faint }
                        MouseArea {
                            id: editMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: edit.usable
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.edit(row.modelData)
                        }
                    }
                }
            }
        }
    }

    KioskFooter {
        anchors.bottom: parent.bottom
        width: parent.width
        onNext: Welcome.move(1)
        // A link to Settings, or a note while changes wait for Continue.
        Row {
            id: footerNote
            anchors.verticalCenter: parent.verticalCenter
            spacing: Kiosk.px(8)
            KioskIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: Keybindings.dirty ? "pending" : "keyboard"
                designSize: 16
                color: Keybindings.dirty ? Kiosk.amber : Kiosk.faint
            }
            KioskLink {
                anchors.verticalCenter: parent.verticalCenter
                visible: !Keybindings.dirty
                text: I18n.tr("All shortcuts in Settings")
                onClicked: root.openSettings()
            }
            KioskText {
                objectName: "welcomeShortcutsPending"
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, footerNote.parent.width - Kiosk.px(24))
                visible: Keybindings.dirty
                text: I18n.tr("Not applied yet. Continue asks whether to apply or discard your changes.")
                size: 14
                tone: "amber"
                elide: Text.ElideRight
            }
        }
    }

    // A modal over the whole guide window. Created straight into the
    // window's content item, lazily on first use.
    property SettingsUi.ShortcutRecorder recorder: null
    Component {
        id: recorderComponent
        SettingsUi.ShortcutRecorder {
            objectName: "welcomeShortcutRecorder"
            fallbackFocus: root
            onAccepted: (combo, mode) => root.recorded(combo, mode)
        }
    }
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
