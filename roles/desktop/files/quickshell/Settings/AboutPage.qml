import QtQuick
import Quickshell
import "../Common"

// Diagnostics and the settings file: things to read or act on once, not
// preferences, so they sit apart from System. Reset all gets a group of its
// own rather than a place beside Open, where a slip lands on it; the rail's
// eight-second Undo still covers it, as it covers every reset.
SettingsPage {
    id: page

    // The page loads asynchronously, often already visible, so a visibility
    // edge alone would leave the first open showing a stale probe.
    Component.onCompleted: ShellHealth.refresh()
    onVisibleChanged: {
        if (visible)
            ShellHealth.refresh();
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

            SettingsRow {
                width: parent.width
                label: "Status"

                Row {
                    x: parent.narrow ? parent.markInset : parent.labelWidth
                    width: parent.contentRight - x
                    y: parent.narrow ? Theme.settingsStackOffset : (parent.lineHeight - height) / 2
                    spacing: Theme.iconTextSpacing

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 7
                        height: 7
                        radius: 4
                        color: ShellHealth.healthy ? Theme.accent
                            : ShellHealth.serviceActive ? Theme.amber : Theme.red
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: ShellHealth.busy ? "Checking…" : ShellHealth.statusLabel
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightMedium
                        color: Theme.textHi
                    }
                }
            }

            SettingsRow {
                width: parent.width
                label: "Service"

                Text {
                    x: parent.narrow ? parent.markInset : parent.labelWidth
                    width: parent.contentRight - x
                    y: parent.narrow ? Theme.settingsStackOffset : (parent.lineHeight - height) / 2
                    text: ShellHealth.serviceActive
                        ? "PID " + ShellHealth.servicePid + " · up " + ShellHealth.uptimeLabel()
                        : (ShellHealth.refreshError || "inactive")
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.secondary
                    color: ShellHealth.serviceActive ? Theme.textMid : Theme.redText
                    elide: Text.ElideRight
                }
            }

            SettingsRow {
                width: parent.width
                label: "Deployment"

                Text {
                    x: parent.narrow ? parent.markInset : parent.labelWidth
                    width: parent.contentRight - x
                    y: parent.narrow ? Theme.settingsStackOffset : (parent.lineHeight - height) / 2
                    text: ShellHealth.deploymentId === ""
                        ? ShellHealth.deploymentDetail
                        : ShellHealth.deploymentStatus + " · "
                            + ShellHealth.deploymentId.slice(0, 10)
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.secondary
                    color: ShellHealth.deploymentStatus === "failed"
                        ? Theme.redText : Theme.textMid
                    elide: Text.ElideRight
                }
            }

            SettingsHint {
                width: parent.width
                text: ShellHealth.issueCount > 0
                    ? (ShellHealth.integrationIssues.concat(ShellHealth.recentWarnings))[0] || "" : ""
                tone: "warning"
            }

            ResponsiveActionRow {
                width: parent.width
                description: ShellHealth.deploymentCheckedAt === ""
                    ? "Live service and current-invocation warnings"
                    : "Last deploy check " + ShellHealth.deploymentCheckedAt

                SettingsAction {
                    text: ShellHealth.busy ? "Checking" : "Refresh"
                    glyph: "refresh"
                    onTriggered: ShellHealth.refresh()
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Settings file"

            ResponsiveActionRow {
                width: parent.width
                breakpoint: 560
                descriptionMono: true
                description: "~/.config/cybexos/shell.json"

                SettingsAction {
                    text: "Open"
                    glyph: "open_in_new"
                    onTriggered: page.openConfig()
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Reset"

            ResponsiveActionRow {
                width: parent.width
                breakpoint: 560
                description: "Every page back to its defaults; undo lasts 8 seconds"

                SettingsAction {
                    text: "Reset all settings"
                    glyph: "undo"
                    danger: true
                    onTriggered: Settings.resetAll()
                }
            }
        }
    }
}
