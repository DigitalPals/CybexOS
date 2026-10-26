pragma ComponentBehavior: Bound
import QtQuick

// A segmented choice in the installer's field style: a deep well holding
// 36 px segments, the chosen one raised. Each segment is a tab stop.
Rectangle {
    id: root
    // [{ value, label, icon? }]
    property var model: []
    property string current: ""
    property string label: ""
    signal picked(string value)
    implicitWidth: segments.implicitWidth + Kiosk.px(8) + border.width * 2
    implicitHeight: Kiosk.px(44) + border.width * 2
    radius: Kiosk.px(12)
    color: Kiosk.bgDeep
    border.width: Math.max(1, Kiosk.px(1))
    border.color: Kiosk.line2
    Accessible.role: Accessible.Grouping
    Accessible.name: label
    Row {
        id: segments
        anchors.centerIn: parent
        spacing: Kiosk.px(4)
        Repeater {
            model: root.model
            delegate: Rectangle {
                id: segment
                required property var modelData
                readonly property bool chosen: root.current === modelData.value
                implicitWidth: segmentRow.implicitWidth + Kiosk.px(28)
                height: Kiosk.px(36)
                radius: Kiosk.px(9)
                color: chosen ? Kiosk.card2 : "transparent"
                border.width: chosen ? Math.max(1, Kiosk.px(1)) : 0
                border.color: Kiosk.line2
                activeFocusOnTab: root.enabled && root.visible
                Accessible.role: Accessible.RadioButton
                Accessible.name: modelData.label
                Accessible.checkable: true
                Accessible.checked: chosen
                Accessible.onPressAction: root.picked(modelData.value)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        if (!event.isAutoRepeat)
                            root.picked(segment.modelData.value);
                        event.accepted = true;
                    }
                }
                KioskFocusRing { visible: segment.activeFocus; gap: 2; baseRadius: segment.radius }
                Row {
                    id: segmentRow
                    anchors.centerIn: parent
                    spacing: Kiosk.px(8)
                    KioskIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !!segment.modelData.icon
                        name: segment.modelData.icon || ""
                        designSize: 16
                        color: segment.chosen ? Kiosk.ink : Kiosk.fog
                    }
                    KioskText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: segment.modelData.label
                        size: 14
                        font.weight: Font.Medium
                        tone: segment.chosen ? "ink" : "fog"
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picked(segment.modelData.value)
                }
            }
        }
    }
}
