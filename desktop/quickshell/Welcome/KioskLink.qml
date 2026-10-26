import QtQuick

// installer/kiosk/ui/widgets.slint, LinkButton: accent text that acts.
KioskText {
    id: root
    signal clicked()
    size: 14
    tone: "accent"
    font.weight: Font.Medium
    activeFocusOnTab: enabled && visible
    opacity: enabled ? 1 : 0.4
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: if (root.enabled) root.clicked()
    Keys.onPressed: event => {
        if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
            if (!event.isAutoRepeat && root.enabled)
                root.clicked();
            event.accepted = true;
        }
    }
    KioskFocusRing { visible: root.activeFocus; gap: 3; baseRadius: Kiosk.px(5) }
    MouseArea {
        anchors.fill: parent
        anchors.margins: -Kiosk.px(6)
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
