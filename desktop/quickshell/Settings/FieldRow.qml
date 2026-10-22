import QtQuick
import "../Common"

// [label][text field][actions][reset column]: a one-off entry and the
// button that acts on it — a plugin source and Install, a new ID and Clone.
// Unlike SettingsTextRow nothing is stored, so the text stays as typed until
// the owner clears it, and focus moving to the button loses nothing. The
// field ends at the actions, which end on the page's right-hand edge like
// every other control; Enter in the field is `accepted()`.
SettingsRow {
    id: root

    default property alias actions: actionRow.data
    property alias text: input.text
    property alias placeholder: input.placeholderText
    // Some forms read better with a narrower field than the whole lane.
    property int fieldWidth: Theme.scaled(360, Theme.typeScale)
    signal accepted()

    readonly property real actionsWidth: actionRow.implicitWidth
    readonly property real actionsLeft: contentRight - actionsWidth
    readonly property real controlTop: narrow ? Theme.settingsStackOffset : 0
    readonly property real controlHeight: narrow ? Theme.settingsControlHeight : lineHeight

    function focusField() {
        input.forceActiveFocus();
    }

    dirty: false
    resetKeys: []
    narrowHeight: Theme.settingsStackOffset + Theme.settingsControlHeight
    narrowLabelInset: undoWidth
    controlLeft: input.x

    SettingsField {
        id: input
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
        font.weight: Theme.weightRegular
        readonly property real fieldEnd: root.actionsLeft
            - (root.actionsWidth > 0 ? Theme.controlSpacing : 0)
        x: root.narrow ? root.markInset
            : Math.max(root.labelWidth, fieldEnd - root.fieldWidth)
        y: root.controlTop + (root.controlHeight - height) / 2
        width: Math.max(0, fieldEnd - x)
        height: Theme.settingsControlHeight
        opacity: root.controlOpacity
        Accessible.name: root.label
        Accessible.description: root.hint
        onAccepted: root.accepted()
        // Escape leaves the field without reaching the window, which would
        // close Settings; the text stays for another try.
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                focus = false;
                event.accepted = true;
            }
        }
    }

    Row {
        id: actionRow
        x: root.actionsLeft
        y: root.controlTop + (root.controlHeight - height) / 2
        spacing: Theme.iconTextSpacing
        opacity: root.controlOpacity
    }
}
