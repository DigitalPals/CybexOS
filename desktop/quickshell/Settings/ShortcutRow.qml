pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/ShortcutEditor.js" as Helpers

// One shortcut on Settings → Keyboard shortcuts: [label][key caps][Edit,
// Disable][reset chip]. The row itself is the list's one tab stop while it is
// current (roving focus): Up/Down/Home/End move between rows, Enter
// records, Delete disables, and Tab reaches this row's own actions.
// Read-only rows (mouse drags, user.lua) show their keys and say why. A
// protected row's reserved defaults are locked caps: they always stay bound.
// While keybindings.json is rejected (Keybindings.readOnly) nothing here edits.
ValueRow {
    id: root

    required property var entry
    property bool current: false
    signal editRequested()
    signal disableRequested()
    signal removeRequested()
    signal moveRequested(int delta)
    signal moveToEdge(bool last)
    signal focused()

    readonly property bool frozen: Keybindings.readOnly
    readonly property bool canEdit: !entry.readOnly && !frozen
    readonly property bool canDisable: canEdit && !entry.protected && entry.keys.length > 0
    readonly property bool canReset: canEdit && !entry.custom && entry.source !== "user"
        && (entry.changed || entry.source === "changed")

    label: I18n.actionLabel(entry.label)
    // The row's reset chip is its Reset, as on every settings row.
    dirty: canReset
    resetLabel: I18n.actionLabel(entry.label)
    hint: entry.userBind ? I18n.tr("Set in user.lua. Change it there.")
        : entry.source === "user" ? I18n.tr("Changed in user.lua, which loads last and wins.")
        : !entry.editable ? I18n.tr("Mouse and hardware keys cannot be changed here.")
        : entry.conflict ? I18n.tr("Shares a key with another shortcut.")
        : entry.keys.length === 0 ? I18n.tr("Disabled")
        : entry.custom ? root.runText(entry.run)
        : entry.protected ? I18n.tr("Protected: its default keys always work. You can add others.") : ""
    hintTone: entry.conflict ? "warning" : "info"
    activeFocusOnTab: current
    Accessible.role: Accessible.ListItem
    Accessible.name: I18n.format("%1: %2", [I18n.actionLabel(entry.label), caps.Accessible.name])
    Accessible.description: hint
    Accessible.onPressAction: if (canEdit) editRequested()
    onActiveFocusChanged: if (activeFocus) focused()

    function runText(run) {
        if (!run)
            return "";
        return run.type === "app" ? I18n.format("Opens the app %1", [String(run.desktopId).replace(/\.desktop$/, "")])
            : run.type === "url" ? I18n.format("Opens %1", [run.url])
            : run.type === "webapp" ? I18n.format("Opens the web app %1", [run.id])
            : I18n.format("Runs %1", [run.command]);
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
            moveRequested(event.key === Qt.Key_Up ? -1 : 1); event.accepted = true;
        } else if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
            moveToEdge(event.key === Qt.Key_End); event.accepted = true;
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)
                && canEdit) {
            editRequested(); event.accepted = true;
        } else if (event.key === Qt.Key_Delete && (canDisable || (canEdit && entry.custom))) {
            entry.custom ? removeRequested() : disableRequested(); event.accepted = true;
        }
    }

    // Held as a property: ValueRow's default property is its action row,
    // and the ring belongs to the whole row.
    property Rectangle focusRing: Rectangle {
        parent: root
        x: -Theme.scaled(4)
        width: root.width + Theme.scaled(8)
        height: root.height
        visible: root.activeFocus
        color: "transparent"
        radius: Theme.rowRadius
        border.width: 1
        border.color: Theme.accentText
    }

    ShortcutKeycaps {
        id: caps
        anchors.verticalCenter: parent.verticalCenter
        keys: root.entry.keys
        lockedKeys: Helpers.lockedKeys(root.entry)
        emptyText: I18n.tr("Not bound")
    }
    SettingsAction {
        visible: !root.entry.readOnly
        enabled: root.canEdit
        compact: true
        glyph: "edit"
        text: I18n.format("Change %1", [I18n.actionLabel(root.entry.label)])
        tooltip: root.entry.custom ? I18n.tr("Edit") : I18n.tr("Record new keys")
        Accessible.role: Accessible.Button
        Accessible.name: text
        activeFocusOnTab: root.current && visible && enabled
        onTriggered: root.editRequested()
    }
    // Protected rows keep the column: a dimmed lock where Disable would be.
    SettingsAction {
        visible: !root.entry.readOnly && root.entry.protected
        enabled: false
        compact: true
        glyph: "lock"
        text: I18n.tr("Protected")
    }
    SettingsAction {
        visible: !root.entry.readOnly && !root.entry.protected
        enabled: root.canDisable || (root.canEdit && root.entry.custom)
        compact: true
        danger: root.entry.custom
        glyph: root.entry.custom ? "delete" : "do_not_disturb_on"
        text: root.entry.custom ? I18n.format("Remove %1", [I18n.actionLabel(root.entry.label)])
            : I18n.format("Disable %1", [I18n.actionLabel(root.entry.label)])
        tooltip: root.entry.custom ? I18n.tr("Remove") : I18n.tr("Disable")
        Accessible.role: Accessible.Button
        Accessible.name: text
        activeFocusOnTab: root.current && visible && enabled
        onTriggered: root.entry.custom ? root.removeRequested() : root.disableRequested()
    }
}
