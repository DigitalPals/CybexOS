pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../../Common"
import "../../Common/ProcessListHelpers.js" as ProcessListHelpers
import "../../Common/SysInfoHelpers.js" as SysInfoHelpers
import ".."

// Overview's Top processes: the six busiest processes by CPU or by memory,
// read only while this list is on screen (Common/ProcessList.qml). A row
// offers End process for the person's own processes, behind a confirmation;
// a process that ignores the request is offered a force quit. The full
// picture is one click away in the system monitor.
Column {
    id: root

    width: parent ? parent.width : 0
    spacing: Theme.scaled(2)

    // Keyed on visibility, not construction: the drawer's `control`
    // instance stays latched by the popout host.
    Claim {
        active: root.visible
        onClaimed: ProcessList.acquire()
        onReleased: ProcessList.release()
    }

    readonly property var stuck: ProcessList.ending !== null
        && ProcessList.ending.stage === "stuck" ? ProcessList.ending : null

    function openMonitor() {
        Popouts.close();
        // The same command as Super+Shift+T (bindings.lua).
        Quickshell.execDetached(["kitty", "-e", "btop"]);
    }

    Item {
        width: parent.width
        height: Math.max(heading.height, modeSwitch.height)

        SectionLabel {
            id: heading
            anchors.left: parent.left
            anchors.right: modeSwitch.left
            anchors.rightMargin: Theme.controlSpacing
            anchors.verticalCenter: parent.verticalCenter
            text: I18n.tr("TOP PROCESSES")
        }

        // Sort by CPU share or by memory; a view choice, not a setting.
        Row {
            id: modeSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.scaled(2)

            Repeater {
                model: [
                    { id: "cpu", label: I18n.tr("CPU") },
                    { id: "memory", label: I18n.tr("Memory") }
                ]

                delegate: Rectangle {
                    id: segment

                    required property var modelData
                    readonly property bool taken: ProcessList.mode === modelData.id

                    width: segmentText.implicitWidth + Theme.scaled(16)
                    height: Theme.scaled(24)
                    radius: Theme.chipRadius
                    color: taken ? Theme.chip : "transparent"
                    border.width: activeFocus ? 1 : 0
                    border.color: Theme.accentText
                    activeFocusOnTab: true
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: "Sort by " + modelData.label
                    Accessible.checked: taken
                    Accessible.onPressAction: ProcessList.setMode(segment.modelData.id)

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            ProcessList.setMode(segment.modelData.id);
                            event.accepted = true;
                        }
                    }

                    StateLayer {
                        anchors.fill: parent
                        radius: parent.radius
                        hovered: segmentMouse.containsMouse
                        pressed: segmentMouse.pressed
                        pressPoint: Qt.point(segmentMouse.mouseX, segmentMouse.mouseY)
                    }

                    Text {
                        id: segmentText
                        anchors.centerIn: parent
                        text: segment.modelData.label
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.metadata
                        font.weight: segment.taken ? Theme.weightSemibold : Theme.weightMedium
                        color: segment.taken ? Theme.textHi : Theme.textFaint
                    }

                    MouseArea {
                        id: segmentMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: ProcessList.setMode(segment.modelData.id)
                    }
                }
            }
        }
    }

    Text {
        visible: !ProcessList.loaded || ProcessList.error !== ""
        width: parent.width
        leftPadding: Theme.scaled(8)
        text: ProcessList.error !== "" ? ProcessList.error : "Reading processes…"
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: ProcessList.error !== "" ? Theme.redText : Theme.textFaint
    }

    // Fixed slots: each shows whichever process holds that rank, so the
    // rows are not rebuilt on every two-second sample.
    Repeater {
        model: ProcessList.limit

        delegate: Rectangle {
            id: slot

            required property int index
            readonly property var row: ProcessList.rows[index] ?? null
            readonly property bool endable: row !== null && ProcessList.canEnd(row)
            readonly property bool byMemory: ProcessList.mode === "memory"

            visible: row !== null
            width: root.width
            height: Theme.listRowHeight
            radius: Theme.rowRadius
            color: slotHover.hovered ? Theme.chip : "transparent"

            Accessible.role: Accessible.StaticText
            Accessible.name: row ? row.name + ", CPU " + ProcessListHelpers.formatCpu(row.cpu)
                + ", memory " + SysInfoHelpers.formatIecBytes(row.memory) : ""

            HoverHandler {
                id: slotHover
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.scaled(8)
                anchors.right: cpuText.left
                anchors.rightMargin: Theme.controlSpacing
                anchors.verticalCenter: parent.verticalCenter
                text: slot.row ? slot.row.name : ""
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightMedium
                color: Theme.textHi
            }

            Text {
                id: cpuText
                anchors.right: memoryText.left
                anchors.rightMargin: Theme.controlSpacing
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.scaled(48)
                horizontalAlignment: Text.AlignRight
                text: slot.row ? ProcessListHelpers.formatCpu(slot.row.cpu) : ""
                font.family: Theme.fontNumeric
                font.pixelSize: Theme.typography.secondary
                font.features: Theme.tabularNumberFeatures
                color: slot.byMemory ? Theme.textFaint : Theme.textHi
            }

            Text {
                id: memoryText
                anchors.right: endButton.left
                anchors.rightMargin: Theme.scaled(4)
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.scaled(72)
                horizontalAlignment: Text.AlignRight
                text: slot.row ? SysInfoHelpers.formatIecBytes(slot.row.memory) : ""
                font.family: Theme.fontNumeric
                font.pixelSize: Theme.typography.secondary
                font.features: Theme.tabularNumberFeatures
                color: slot.byMemory ? Theme.textHi : Theme.textFaint
            }

            // Only the person's own processes, and never one whose end takes
            // the session with it (ProcessListHelpers.canEnd).
            DrawerIconButton {
                id: endButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.scaled(28)
                height: Theme.scaled(28)
                visible: slot.endable
                enabled: ProcessList.ending === null
                glyph: "close"
                glyphSize: Theme.iconSmall
                tint: Theme.textFaint
                accessibleName: slot.row ? "End " + slot.row.name : "End process"
                onClicked: ProcessList.requestEnd(slot.row)
            }
        }
    }

    // The confirmation, then — if the process ignored the request — the
    // offer to force it. Both say what is at stake before acting.
    Rectangle {
        visible: ProcessList.confirming !== null || root.stuck !== null
        width: parent.width
        height: confirmContent.implicitHeight + Theme.scaled(20)
        radius: Theme.rowRadius
        color: Theme.chip

        Column {
            id: confirmContent
            x: Theme.scaled(10)
            y: Theme.scaled(10)
            width: parent.width - Theme.scaled(20)
            spacing: Theme.scaled(8)

            Text {
                width: parent.width
                text: ProcessList.confirming !== null
                    ? "End " + ProcessList.confirming.name + " (" + ProcessList.confirming.pid
                        + ")? Unsaved work in it may be lost."
                    : root.stuck !== null
                    ? root.stuck.name + " is still running. Force quit stops it at once; unsaved work is lost."
                    : ""
                wrapMode: Text.WordWrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textHi
                Accessible.role: Accessible.AlertMessage
                Accessible.name: text
            }

            Row {
                spacing: Theme.scaled(16)

                LinkText {
                    text: ProcessList.confirming !== null ? I18n.tr("End process") : I18n.tr("Force quit")
                    onClicked: {
                        if (ProcessList.confirming !== null)
                            ProcessList.confirmEnd();
                        else
                            ProcessList.forceQuit();
                    }
                }

                LinkText {
                    text: I18n.tr("Cancel")
                    onClicked: ProcessList.cancel()
                }
            }
        }
    }

    Text {
        visible: ProcessList.notice !== ""
            || (ProcessList.ending !== null && ProcessList.ending.stage !== "stuck")
        width: parent.width
        leftPadding: Theme.scaled(8)
        wrapMode: Text.WordWrap
        text: ProcessList.notice !== "" ? ProcessList.notice
            : ProcessList.ending !== null ? "Ending " + ProcessList.ending.name + "…" : ""
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: ProcessList.notice.indexOf("Couldn’t") === 0 ? Theme.redText : Theme.textMid
        Accessible.role: Accessible.AlertMessage
        Accessible.name: text
    }

    Item {
        width: parent.width
        height: monitorLink.implicitHeight + Theme.scaled(6)

        LinkText {
            id: monitorLink
            anchors.right: parent.right
            anchors.rightMargin: Theme.scaled(4)
            anchors.bottom: parent.bottom
            text: I18n.tr("Open system monitor")
            onClicked: root.openMonitor()
        }
    }
}
