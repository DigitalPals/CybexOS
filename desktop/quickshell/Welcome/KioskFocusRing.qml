import QtQuick

// The installer's keyboard focus ring: 2 px of accent, 4 px outside.
Rectangle {
    property real gap: 4
    property real baseRadius: 0
    anchors.fill: parent
    anchors.margins: -Kiosk.px(gap)
    radius: baseRadius + Kiosk.px(gap)
    color: "transparent"
    border.width: Math.max(1, Kiosk.px(2))
    border.color: Kiosk.accent
}
