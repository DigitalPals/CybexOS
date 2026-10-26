pragma ComponentBehavior: Bound
import QtQuick

// installer/kiosk/ui/app.slint, Steps: numbered rings joined by short bars.
// Finished steps show a tick on a tinted disc, the current one an accent ring.
Row {
    id: root
    property var steps: []
    // 1-based, as in the installer; 0 shows every step as upcoming.
    property int current: 0
    spacing: Kiosk.px(10)
    Accessible.role: Accessible.List
    Repeater {
        model: root.steps
        delegate: Row {
            id: step
            required property string modelData
            required property int index
            readonly property bool done: index + 1 < root.current
            readonly property bool here: index + 1 === root.current
            spacing: Kiosk.px(10)
            Accessible.role: Accessible.ListItem
            Accessible.name: modelData
            Accessible.selected: here
            Rectangle {
                visible: step.index > 0
                anchors.verticalCenter: parent.verticalCenter
                width: Kiosk.px(40)
                height: Math.max(1, Kiosk.px(1.5))
                color: Kiosk.line2
            }
            Row {
                spacing: Kiosk.px(8)
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Kiosk.px(24)
                    height: width
                    radius: width / 2
                    color: step.done ? Kiosk.accentTint : "transparent"
                    border.width: step.done ? 0 : Math.max(1, Kiosk.px(1.5))
                    border.color: step.here ? Kiosk.accent : Kiosk.line2
                    KioskIcon {
                        anchors.centerIn: parent
                        visible: step.done
                        name: "check"
                        designSize: 13
                        color: Kiosk.accent
                    }
                    KioskText {
                        anchors.centerIn: parent
                        visible: !step.done
                        text: String(step.index + 1)
                        mono: true
                        size: 12
                        font.weight: Font.Bold
                        tone: step.here ? "accent" : "faint"
                    }
                }
                KioskText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: step.modelData
                    size: 14
                    font.weight: Font.Medium
                    tone: step.here ? "ink" : step.done ? "fog" : "faint"
                }
            }
        }
    }
}
