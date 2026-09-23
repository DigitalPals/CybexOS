import QtQuick
import ".."
import "../../Common"

// Retained session notification history. The bell carries an accent unread
// mark rather than a count, per the edge-drawer design; the drawer's
// Notifications tab holds the numbers. Opening the panel is intentionally
// read-only: dismissing a card or clearing the history is what lowers count.
BarModule {
    id: root

    moduleId: "notifications"

    BarIcon {
        id: chip

        host: root.host
        panelName: "notifications"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        glyph: Notifs.dnd ? "notifications_off" : "notifications"
        glyphSize: Theme.barIconSize
        glyphWeight: 550
        // Critical history stays visible even while DND suppresses its toast.
        alert: Notifs.hasUrgent
        active: Notifs.dnd && !Notifs.hasUrgent
        tooltip: Notifs.dnd
            ? "Notifications · Do Not Disturb · " + Notifs.count
            : Notifs.count === 1 ? "1 notification"
            : Notifs.count + " notifications"
        tooltipAlign: 1

        // The unread mark, ringed in the bar surface so it reads as sitting
        // on the bell rather than beside it. Urgency keeps the red identity.
        Rectangle {
            visible: Notifs.count > 0
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: 4
            anchors.topMargin: 4
            width: 8
            height: 8
            radius: 4
            color: Theme.barSurface
            z: 2

            Rectangle {
                anchors.centerIn: parent
                width: 5
                height: 5
                radius: 3
                color: Notifs.hasUrgent ? Theme.barRedText : Theme.barAccent
            }
        }
    }
}
