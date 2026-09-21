import QtQuick
import ".."
import "../../Common"
import "../../Common/GitHubHelpers.js" as Helpers

// GitHub Inbox and repository feed, inside the right cluster's chip group.
// Running state is independent from the configurable unread badge, so
// badge-off still shows live workflows.
BarModule {
    id: root

    moduleId: "gh"
    detailSaving: ghChip.detailSaving

    BarChip {
        id: ghChip

        readonly property color badgeTone: GitHub.badgeTone === "red" ? Theme.barRed
            : GitHub.badgeTone === "amber" ? Theme.barAmber : Theme.barAccent
        readonly property bool detailAvailable: GitHub.pendingInboxCount > 0
            && GitHub.badgeMode !== "count"
        readonly property real detailSaving: detailAvailable
            ? countLabel.implicitWidth + spacing : 0

        host: root.host
        panelName: "github"
        isle: root.isle
        anchorItem: root.groupAnchor ?? ghChip
        shape: "inner"
        hPadding: 9
        spacing: 6
        tooltipAlign: 1
        tooltip: {
            let summary = Helpers.githubTooltip(GitHub.runningCount,
                GitHub.pendingInboxCount, GitHub.unreadRepoCount);
            if (GitHub.error !== "")
                summary += " · repositories unavailable";
            if (GitHub.inboxError !== "")
                summary += " · Inbox paused";
            return summary;
        }

        // Keep the mark pristine, as T3 does. Live work gets its own narrow
        // status lane and pending activity stays in the adjacent label.
        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.barIconSize
            height: Theme.barIconSize

            BarBrandIcon {
                id: mark
                anchors.centerIn: parent
                width: Theme.barIconSize
                height: Theme.barIconSize
                name: "github"
                highlighted: ghChip.held || ghChip.hovered
            }
        }

        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: GitHub.runningCount > 0 ? 5 : 0
            height: 5
            opacity: GitHub.runningCount > 0 ? 1 : 0

            Behavior on width {
                NumberAnimation {
                    duration: Theme.expandDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.springCurve
                }
            }

            Behavior on opacity {
                NumberAnimation { duration: Theme.chipFadeDuration }
            }

            // Static by design: a permanent workflow marker should not pulse.
            Rectangle {
                anchors.centerIn: parent
                width: 5
                height: 5
                radius: 2.5
                color: Theme.barAccent
            }
        }

        Text {
            id: countLabel
            visible: !root.compact && ghChip.detailAvailable
            anchors.verticalCenter: parent.verticalCenter
            text: GitHub.pendingInboxCount + " pending"
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightMedium
            font.features: Theme.tabularNumberFeatures
            color: ghChip.badgeTone
        }
    }
}
