pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// [label][toggle chips][undo]: any subset of a short list. PickerRow's
// segmented control is one-of-many; these chips are checkboxes wearing the
// same held-chip grammar, so a chosen option reads the same in both.
SettingsRow {
    id: root

    // [{ value, label }]
    property var model: []
    property var chosen: []
    signal toggledOption(var value)

    narrowHeight: Theme.settingsStackOffset + Math.max(Theme.settingsControlHeight,
        chips.implicitHeight) + Theme.settingsRowSpacing
    wideHeight: Math.max(Theme.panelRowHeight, chips.implicitHeight)
    narrowLabelInset: root.undoWidth

    Flow {
        id: chips
        x: root.narrow ? root.markInset : root.labelWidth
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        width: Math.max(0, root.contentRight - x)
        opacity: root.controlOpacity
        spacing: Theme.panelRowSpacing

        Repeater {
            id: chipRepeater
            model: root.model

            delegate: Rectangle {
                id: chip

                required property var modelData
                required property int index
                readonly property bool on: root.chosen.indexOf(modelData.value) >= 0

                width: Math.min(chips.width, chipRow.implicitWidth + 20)
                height: Theme.chipInnerHeight
                radius: Theme.chipRadius
                color: chip.on ? Theme.chipHover : "transparent"
                border.width: activeFocus ? 1 : 0
                border.color: Theme.accentText
                activeFocusOnTab: true
                Accessible.role: Accessible.CheckBox
                Accessible.name: chip.modelData.label
                Accessible.checkable: true
                Accessible.checked: chip.on
                Accessible.onToggleAction: root.toggledOption(chip.modelData.value)
                Accessible.onPressAction: root.toggledOption(chip.modelData.value)

                Keys.onPressed: event => {
                    let next = -1;
                    if (event.key === Qt.Key_Left || event.key === Qt.Key_Up)
                        next = Math.max(0, index - 1);
                    else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down)
                        next = Math.min(root.model.length - 1, index + 1);
                    else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
                            || event.key === Qt.Key_Enter) {
                        chipState.pulseCenter();
                        root.toggledOption(chip.modelData.value);
                        event.accepted = true;
                        return;
                    }
                    // Arrows only move focus: unlike a radio group, landing
                    // on a checkbox must not change it.
                    if (next >= 0) {
                        chipRepeater.itemAt(next).forceActiveFocus();
                        event.accepted = true;
                    }
                }

                StateLayer {
                    id: chipState
                    anchors.fill: parent
                    radius: parent.radius
                    hovered: chipMouse.containsMouse
                    pressed: chipMouse.pressed
                    focused: chip.activeFocus
                    tint: chip.on ? Theme.accent : Theme.textHi
                    pressPoint: Qt.point(chipMouse.mouseX, chipMouse.mouseY)
                }

                Row {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: 4

                    Sym {
                        anchors.verticalCenter: parent.verticalCenter
                        name: chip.on ? "check" : "add"
                        size: Theme.iconSmall
                        color: chip.on ? Theme.textHi : Theme.textLow
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, chips.width - 40)
                        elide: Text.ElideRight
                        text: chip.modelData.label
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.control
                        font.weight: Theme.weightMedium
                        color: chip.on ? Theme.textHi : Theme.textLow
                    }
                }

                MouseArea {
                    id: chipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        chip.forceActiveFocus();
                        root.toggledOption(chip.modelData.value);
                    }
                }
            }
        }
    }
}
