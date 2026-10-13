import QtQuick
import ".."
import "../../Common"

// The Fusebox mark and one live figure, recent sessions by default. The
// mark carries a badge only when something needs attention: amber for a fault
// that clears by itself, red for one that fails requests or for a lost
// connection. A healthy server is just its number.
BarModule {
    id: root

    readonly property string connection: Fusebox.connection
    readonly property bool configured: connection !== "setup"
    readonly property bool troubled: connection === "offline" || connection === "auth"
    readonly property string badge: troubled ? "critical" : Fusebox.faultLevel
    readonly property bool idle: Fusebox.options.metric !== "faults" && Fusebox.barValue === "0"

    moduleId: "fusebox"

    BarChip {
        id: chip
        host: root.host
        panelName: "fusebox"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        spacing: 6
        tooltip: {
            if (!root.configured)
                return "Fusebox · Set up";
            const f = Fusebox.figures;
            const lines = ["Fusebox · " + Fusebox.status];
            if (Fusebox.hasData)
                lines.push((f.sessions === 1 ? "1 session" : f.sessions + " sessions") + " · "
                    + f.serving + " in progress · " + f.rpm + " requests/min");
            const shown = Fusebox.shownFaults;
            if (shown.length)
                lines.push(shown.length === 1 ? "1 fault: " + shown[0].title
                    : shown.length + " faults · " + shown[0].title);
            if (Fusebox.resetReviews > 0)
                lines.push(Fusebox.resetReviews === 1 ? "A banked reset needs review"
                    : Fusebox.resetReviews + " banked resets need review");
            if (Fusebox.error)
                lines.push(Fusebox.error);
            return lines.join("\n");
        }

        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.barIconSize
            height: Theme.barIconSize

            BarBrandIcon {
                anchors.centerIn: parent
                width: Theme.barIconSize
                height: Theme.barIconSize
                name: "fusebox"
                highlighted: chip.held || chip.hovered
            }

            // Ringed in the bar surface so it reads as sitting on the mark,
            // as the notification bell's unread mark does.
            Rectangle {
                visible: root.configured && root.badge !== "ok"
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.rightMargin: -3
                anchors.topMargin: -3
                width: 8
                height: 8
                radius: 4
                color: Theme.barSurface

                Rectangle {
                    anchors.centerIn: parent
                    width: 5
                    height: 5
                    radius: 3
                    color: root.badge === "critical" ? Theme.barRedText : Theme.barAmber
                }
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: !root.configured ? "Set up" : Fusebox.hasData ? Fusebox.barValue : "–"
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightSemibold
            font.features: Theme.tabularNumberFeatures
            color: !root.configured ? Theme.barTextLow
                : root.troubled || !Fusebox.hasData ? Theme.barTextFaint
                : root.idle ? Theme.barTextLow : Theme.barTextHi

            Behavior on color {
                ColorAnimation { duration: Theme.chipFadeDuration }
            }
        }
    }
}
