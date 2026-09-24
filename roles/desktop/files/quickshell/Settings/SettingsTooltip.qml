import QtQuick
import QtQuick.Controls as Controls
import "../Common"

// The hover tip inside the settings window: the panel's own surface and ink
// rather than Qt's default yellow box. It answers to the pointer only; a
// keyboard user already hears the control's accessible name, and a tip that
// opens on focus sat over the page every time the window gave focus to a
// button.
Controls.ToolTip {
    id: root

    delay: 450
    timeout: -1
    margins: Theme.scaled(6)
    padding: 0
    y: parent ? parent.height + Theme.scaled(6) : 0

    contentItem: Text {
        text: root.text
        leftPadding: Theme.controlSpacing
        rightPadding: Theme.controlSpacing
        topPadding: Theme.scaled(4)
        bottomPadding: Theme.scaled(4)
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textHi
    }

    background: Rectangle {
        radius: Theme.chipRadius
        color: Theme.popBg
        border.width: 1
        border.color: Theme.stroke
    }
}
