pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

// Native reminder manager: quick presets and a validated custom countdown on
// top, followed by the canonical records sorted by the helper.
Surface {
    id: root

    implicitWidth: availableWidth > 0
        ? Math.min(Theme.popWidth, availableWidth) : Theme.popWidth
    padding: Theme.surfacePadding
    spacing: 10
    property bool clearArmed: false
    readonly property int selectedMinutes: {
        const value = Number(minutesInput.text);
        return Number.isInteger(value) && value > 0 ? value : 0;
    }

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    function remainingLabel(due) {
        const seconds = Math.max(0, Math.ceil(Number(due) - clock.date.getTime() / 1000));
        if (seconds < 60)
            return seconds + "s";
        const minutes = Math.ceil(seconds / 60);
        if (minutes < 60)
            return minutes + "m";
        const hours = Math.floor(minutes / 60);
        return hours + "h " + (minutes % 60) + "m";
    }

    function addReminder() {
        if (selectedMinutes <= 0)
            return;
        Reminders.add(selectedMinutes, messageInput.text.trim());
        messageInput.text = "";
    }

    Row {
        width: parent.width
        spacing: 8

        Sym {
            anchors.verticalCenter: parent.verticalCenter
            name: "notifications_active"
            size: Theme.iconMedium
            fill: Reminders.count > 0 ? 1 : 0
            color: Reminders.count > 0 ? Theme.accentText : Theme.textMid
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Reminders"
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.heading
            font.weight: Theme.weightBold
            color: Theme.textHi
        }
    }

    Row {
        width: parent.width
        spacing: 6

        Repeater {
            model: [5, 15, 30, 60]

            delegate: Rectangle {
                id: preset
                required property int modelData
                width: (parent.width - 18) / 4
                height: 30
                radius: height / 2
                color: root.selectedMinutes === modelData ? Theme.accent
                    : presetMouse.containsMouse ? Theme.chipHover : Theme.tile
                Accessible.role: Accessible.Button
                Accessible.name: modelData + " minutes"
                Accessible.onPressAction: minutesInput.text = String(modelData)

                Text {
                    anchors.centerIn: parent
                    text: preset.modelData + "m"
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.control
                    font.weight: Theme.weightSemibold
                    color: root.selectedMinutes === preset.modelData
                        ? Theme.textOnAccent : Theme.textMid
                }

                MouseArea {
                    id: presetMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: minutesInput.text = String(preset.modelData)
                }
            }
        }
    }

    Row {
        width: parent.width
        spacing: 6

        Rectangle {
            width: 82
            height: 34
            radius: Theme.rowRadius
            color: minutesInput.activeFocus ? Theme.chipHover : Theme.tile
            border.width: minutesInput.activeFocus ? 1 : 0
            border.color: root.selectedMinutes > 0 ? Theme.accentText : Theme.red

            TextInput {
                id: minutesInput
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                text: String(Settings.modOpts.indicators.reminderMinutes)
                inputMethodHints: Qt.ImhDigitsOnly
                validator: IntValidator { bottom: 1 }
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.control
                color: Theme.textHi
                selectionColor: Theme.accentBg
                activeFocusOnTab: true
                Accessible.role: Accessible.EditableText
                Accessible.name: "Minutes"
                Keys.onReturnPressed: root.addReminder()
                Keys.onEnterPressed: root.addReminder()
            }
        }

        Rectangle {
            width: parent.width - 82 - addButton.width - parent.spacing * 2
            height: 34
            radius: Theme.rowRadius
            color: messageInput.activeFocus ? Theme.chipHover : Theme.tile
            border.width: messageInput.activeFocus ? 1 : 0
            border.color: Theme.accentText

            TextInput {
                id: messageInput
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                color: Theme.textHi
                selectionColor: Theme.accentBg
                activeFocusOnTab: true
                clip: true
                Accessible.role: Accessible.EditableText
                Accessible.name: "Optional reminder message"
                Keys.onReturnPressed: root.addReminder()
                Keys.onEnterPressed: root.addReminder()

                Text {
                    visible: messageInput.text === ""
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    text: "Optional message"
                    font: messageInput.font
                    color: Theme.textFaint
                }
            }
        }

        Rectangle {
            id: addButton
            width: 56
            height: 34
            radius: height / 2
            color: enabled ? (addMouse.containsMouse ? Theme.accentHover : Theme.accent)
                : Theme.tile
            enabled: root.selectedMinutes > 0
            opacity: enabled ? 1 : 0.5
            activeFocusOnTab: enabled
            Accessible.role: Accessible.Button
            Accessible.name: "Add reminder"
            Accessible.onPressAction: root.addReminder()

            Row {
                anchors.centerIn: parent
                spacing: 3

                Sym {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "add"
                    size: Theme.iconSmall
                    symWeight: 600
                    color: addButton.enabled ? Theme.textOnAccent : Theme.textFaint
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Add"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    font.weight: Theme.weightBold
                    color: addButton.enabled ? Theme.textOnAccent : Theme.textFaint
                }
            }

            MouseArea {
                id: addMouse
                anchors.fill: parent
                enabled: addButton.enabled
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.addReminder()
            }
        }
    }

    HDivider { width: parent.width }

    Row {
        width: parent.width

        Text {
            width: parent.width - (clearAction.visible ? clearAction.width : 0)
            text: Reminders.count === 0 ? "No pending reminders"
                : Reminders.count + (Reminders.count === 1 ? " pending" : " pending")
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightSemibold
            color: Theme.textLow
        }
        ActionButton {
            id: clearAction
            visible: Reminders.count > 0
            label: root.clearArmed ? "Confirm clear all" : "Clear all"
            tint: Theme.redText
            fill: Theme.redBgSoft
            hPadding: 14
            onTriggered: {
                if (root.clearArmed) {
                    root.clearArmed = false;
                    Reminders.clear();
                } else {
                    root.clearArmed = true;
                    clearGuard.restart();
                }
            }
        }
    }

    Flickable {
        id: reminderList
        width: parent.width
        height: Reminders.count > 0
            ? Math.min(reminderColumn.implicitHeight,
                Math.max(80, root.availableHeight - 250)) : 0
        visible: height > 0
        contentWidth: width
        contentHeight: reminderColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
            id: reminderColumn
            width: parent.width
            spacing: 6

            Repeater {
                model: Reminders.records

                delegate: Rectangle {
                    id: reminderRow
                    required property var modelData
                    width: parent.width
                    height: 54
                    radius: Theme.rowRadius
                    color: Theme.tile

                    Column {
                        x: 11
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 58
                        spacing: 2

                        Text {
                            width: parent.width
                            text: reminderRow.modelData.message
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.primary
                            font.weight: Theme.weightSemibold
                            color: Theme.textHi
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            text: root.remainingLabel(reminderRow.modelData.due) + " · "
                                + Qt.formatDateTime(new Date(Number(reminderRow.modelData.due) * 1000),
                                    Settings.clock24 ? "HH:mm" : "h:mm AP")
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.typography.secondary
                            color: Theme.textLow
                        }
                    }

                    Rectangle {
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34
                        height: 34
                        radius: 17
                        color: cancelMouse.containsMouse ? Theme.redBg : "transparent"
                        Accessible.role: Accessible.Button
                        Accessible.name: "Cancel " + reminderRow.modelData.message
                        Accessible.onPressAction: Reminders.cancel(reminderRow.modelData.id)

                        Sym {
                            anchors.centerIn: parent
                            name: "delete"
                            size: Theme.iconSmall + 2
                            color: Theme.redText
                        }

                        MouseArea {
                            id: cancelMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Reminders.cancel(reminderRow.modelData.id)
                        }
                    }
                }
            }
        }

        ScrollChrome {
            anchors.fill: parent
            target: reminderList
        }
    }

    Text {
        visible: Reminders.error !== ""
        width: parent.width
        text: Reminders.error
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.redText
    }

    Timer {
        id: clearGuard
        interval: 3500
        onTriggered: root.clearArmed = false
    }
}
