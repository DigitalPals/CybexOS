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
        Qt.callLater(() => {
            Settings.closePanel();
            Quickshell.execDetached(["xdg-open", Settings.filePath]);
        });
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Shell health")

            ValueRow {
                width: parent.width
                label: I18n.tr("Status")
                dotColor: page.statusColor
                value: ShellHealth.busy ? "Checking…" : ShellHealth.statusLabel
                valueColor: Theme.textHi
                hint: ShellHealth.issueCount > 0
                    ? (ShellHealth.integrationIssues.concat(ShellHealth.recentWarnings))[0] || "" : ""
                hintTone: "warning"
            }
            ValueRow {
                width: parent.width
                label: I18n.tr("Service")
                valueMono: true
                value: ShellHealth.serviceActive
                    ? "PID " + ShellHealth.servicePid + " · up " + ShellHealth.uptimeLabel()
                    : (ShellHealth.refreshError || "Inactive")
                valueColor: ShellHealth.serviceActive ? Theme.textMid : Theme.redText
            }
            ValueRow {
                width: parent.width
                label: I18n.tr("Deployment")
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
                label: I18n.tr("Last deploy check")
                value: LocalTime.fromText(ShellHealth.deploymentCheckedAt, clock.date.getTime(),
                    Settings.clock24, ShellHealth.deploymentCheckedAt || "Not recorded")

                SettingsAction {
                    text: ShellHealth.busy ? I18n.tr("Checking") : I18n.tr("Refresh")
                    glyph: "refresh"
                    Accessible.name: I18n.tr("Refresh shell health")
                    onTriggered: ShellHealth.refresh()
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Welcome guide")
            ValueRow {
                width: parent.width
                label: I18n.tr("Welcome guide")
                hint: I18n.tr("Make yourself at home. Continue where you left off.")
                SettingsAction {
                    text: I18n.tr("Open")
                    Accessible.name: I18n.tr("Open the welcome guide")
                    onTriggered: Welcome.show("")
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Settings file")

            ValueRow {
                width: parent.width
                label: "~/.config/cybexos/shell.json"
                labelMono: true

                SettingsAction {
                    text: I18n.tr("Open")
                    glyph: "open_in_new"
                    Accessible.name: I18n.tr("Open the settings file")
                    onTriggered: page.openConfig()
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Reset")

            ValueRow {
                width: parent.width
                label: I18n.tr("Reset all settings")
                hint: I18n.tr("Every page back to its defaults. You can undo for 8 seconds.")

                SettingsAction {
                    text: I18n.tr("Reset all")
                    glyph: "restart_alt"
                    danger: true
                    onTriggered: Settings.resetAll()
                }
            }
        }
    }
}
