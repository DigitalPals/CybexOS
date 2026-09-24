pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "LocalTime.js" as LocalTime

// Diagnostics and the settings file: things to read or act on once, not
// preferences, so they sit apart from the other pages. Every row reads as
// label, value and action on the page's one control edge. Reset all gets a
// group of its own rather than a place beside Open, where a slip lands on
// it; the rail's eight-second Undo still covers it, as it covers every
// reset.
SettingsPage {
    id: page

    // Status colours are the shell's status colours: green for healthy,
    // amber for a shell that runs but reports a problem, red for one that
    // does not run. The accent is a mark, not a verdict.
    readonly property color statusColor: !ShellHealth.serviceActive ? Theme.red
        : !ShellHealth.healthy || ShellHealth.issueCount > 0 ? Theme.amber
        : Theme.connected
    readonly property bool deploymentFailed: ShellHealth.deploymentStatus === "failed"
    readonly property bool deploymentRolledBack: ShellHealth.deploymentStatus === "rolled-back"

    // The page loads asynchronously, often already visible, so a visibility
    // edge alone would leave the first open showing a stale probe.
    Component.onCompleted: ShellHealth.refresh()
    onVisibleChanged: {
        if (visible)
            ShellHealth.refresh();
    }

    // Relative dates only change at midnight; an hourly tick while the page
    // is on screen is enough to roll "Today" over to "Yesterday".
    SystemClock {
        id: clock
        precision: SystemClock.Hours
        enabled: page.visible
    }

    function openConfig() {
        Settings.saveNow();
        Qt.callLater(() => Quickshell.execDetached(["xdg-open", Settings.filePath]));
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Shell health"

            ValueRow {
                width: parent.width
                label: "Status"
                dotColor: page.statusColor
                value: ShellHealth.busy ? "Checking…" : ShellHealth.statusLabel
                valueColor: Theme.textHi
                hint: ShellHealth.issueCount > 0
                    ? (ShellHealth.integrationIssues.concat(ShellHealth.recentWarnings))[0] || "" : ""
                hintTone: "warning"
            }
            ValueRow {
                width: parent.width
                label: "Service"
                valueMono: true
                value: ShellHealth.serviceActive
                    ? "PID " + ShellHealth.servicePid + " · up " + ShellHealth.uptimeLabel()
                    : (ShellHealth.refreshError || "Inactive")
                valueColor: ShellHealth.serviceActive ? Theme.textMid : Theme.redText
            }
            ValueRow {
                width: parent.width
                label: "Deployment"
                valueMono: ShellHealth.deploymentId !== ""
                value: ShellHealth.deploymentId !== ""
                    ? ShellHealth.deploymentId.slice(0, 10) + " · " + ShellHealth.deploymentStatus
                    : page.deploymentFailed ? "Unreadable" : "None yet"
                valueColor: page.deploymentFailed ? Theme.redText : Theme.textMid
                hint: page.deploymentFailed || page.deploymentRolledBack
                    ? ShellHealth.deploymentDetail : ""
                hintTone: page.deploymentFailed ? "error"
                    : page.deploymentRolledBack ? "warning" : "info"
            }
            // The deploy writes this time; Refresh re-reads it with the live
            // service and warnings, so it does not start a new deploy check.
            ValueRow {
                width: parent.width
                label: "Last deploy check"
                value: LocalTime.fromText(ShellHealth.deploymentCheckedAt, clock.date.getTime(),
                    Settings.clock24, ShellHealth.deploymentCheckedAt || "Not recorded")

                SettingsAction {
                    text: ShellHealth.busy ? "Checking" : "Refresh"
                    glyph: "refresh"
                    Accessible.name: "Refresh shell health"
                    onTriggered: ShellHealth.refresh()
                }
            }
        }

        RecoveryGroup {
            width: parent.width
            nowMs: clock.date.getTime()
        }

        SettingsGroup {
            width: parent.width
            title: "Settings file"

            ValueRow {
                width: parent.width
                label: "~/.config/cybexos/shell.json"
                labelMono: true

                SettingsAction {
                    text: "Open"
                    glyph: "open_in_new"
                    Accessible.name: "Open the settings file"
                    onTriggered: page.openConfig()
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Reset"

            ValueRow {
                width: parent.width
                label: "Reset all settings"
                hint: "Every page back to its defaults. You can undo for 8 seconds."

                SettingsAction {
                    text: "Reset all"
                    glyph: "restart_alt"
                    danger: true
                    onTriggered: Settings.resetAll()
                }
            }
        }
    }
}
