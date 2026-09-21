import QtQuick
import Quickshell
import "../Common"
import "../Common/Format.js" as Format

SettingsPage {
    id: page

    property double nowSecs: Date.now() / 1000
    readonly property date nowDate: new Date(page.nowSecs * 1000)
    readonly property int pollLeft: Usage.nextPollSecs

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: page.nowSecs = Date.now() / 1000
    }

    Claim {
        active: page.visible
        onClaimed: Usage.acquireCountdown()
        onReleased: Usage.releaseCountdown()
    }

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
            title: "General"
            dirty: Settings.clock24 !== Settings.defaults.clock24
                || Settings.unit !== Settings.defaults.unit
                || Math.abs(Settings.scrollFactor - Settings.defaults.scrollFactor) > 0.001
            onResetRequested: Settings.resetKeys(["clock24", "unit", "scrollFactor"], "General")

            PickerRow {
                width: parent.width
                label: "Clock"
                settingKey: "clock24"
                model: [
                    { value: true, label: "24 h" },
                    { value: false, label: "12 h" }
                ]
                caption: Qt.formatDateTime(page.nowDate, Settings.clock24 ? "HH:mm" : "h:mm AP")
            }
            PickerRow {
                width: parent.width
                label: "Temperature"
                settingKey: "unit"
                model: [
                    { value: "c", label: "°C" },
                    { value: "f", label: "°F" }
                ]
                caption: Weather.ready ? Weather.temp + "° outside" : ""
            }
            SliderRow {
                width: parent.width
                label: "Scroll speed"
                settingKey: "scrollFactor"
                resetLabel: "Touchpad scroll speed"
                min: 0.2
                max: 2.0
                step: 0.1
                decimals: 1
                unit: "×"
                dirty: Math.abs(Settings.scrollFactor - Settings.defaults.scrollFactor) > 0.001
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Night light"
            dirty: Settings.warmth !== Settings.defaults.warmth
            onResetRequested: Settings.resetKeys(["warmth"], "Night light")

            SliderRow {
                width: parent.width
                label: "Warmth"
                settingKey: "warmth"
                min: 1900
                max: 4500
                step: 50
                unit: "K"
                gradientTrack: true
            }
            Text {
                width: parent.width
                leftPadding: page.width < Theme.settingsNarrowWidth
                    ? Theme.settingsMarkInset : Theme.settingsMarkInset + Theme.settingsLabelWidth
                text: "Tint applies while Night light is on in Control Panel — "
                    + (SysInfo.nightLight ? "currently on" : "currently off")
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textDim
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Stay awake"

            PickerRow {
                width: parent.width
                label: "Duration"
                // Runtime session choice; there is no persisted default to reset.
                dirty: false
                resetKeys: []
                current: SysInfo.idleInhibitMode
                model: [
                    { value: "off", label: "Off" },
                    { value: "30m", label: "30 min" },
                    { value: "1h", label: "1 hour" },
                    { value: "unplugged", label: "Until unplugged" },
                    { value: "always", label: "Always" }
                ]
                onPicked: value => SysInfo.setIdleInhibitMode(value)
            }

            Text {
                width: parent.width
                leftPadding: page.width < Theme.settingsNarrowWidth
                    ? Theme.settingsMarkInset : Theme.settingsMarkInset + Theme.settingsLabelWidth
                text: SysInfo.idleInhibited
                    ? "Active · " + SysInfo.idleInhibitStatus
                    : "Off · default duration and sign-in behavior are configured under Widgets → Indicators."
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: SysInfo.idleInhibited ? Theme.amber : Theme.textDim
                wrapMode: Text.Wrap
            }
        }

        SettingsGroup {
            width: parent.width
            title: "OSD"
            dirty: Settings.osd !== Settings.defaults.osd
            onResetRequested: Settings.resetKeys(["osd"], "OSD")

            PickerRow {
                width: parent.width
                label: "Placement"
                settingKey: "osd"
                model: [
                    { value: "top", label: "Top center" },
                    { value: "bottom", label: "Bottom center" }
                ]
                caption: "volume / brightness popup"
                captionMono: false
            }
        }

        SettingsGroup {
            width: parent.width
            title: "T3 usage"
            dirty: Settings.pollMax !== Settings.defaults.pollMax
            onResetRequested: Settings.resetKeys(["pollMax"], "T3 usage")

            PickerRow {
                width: parent.width
                label: "Poll every"
                settingKey: "pollMax"
                model: [
                    { value: 60, label: "1 min" },
                    { value: 300, label: "5 min" },
                    { value: 600, label: "10 min" }
                ]
                caption: "next " + Format.mmss(page.pollLeft)
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Shell health"

            SettingsRow {
                width: parent.width
                label: "Status"

                Row {
                    x: parent.narrow ? parent.markInset : parent.labelWidth
                    width: parent.contentRight - x
                    y: parent.narrow ? Theme.settingsStackOffset : (parent.height - height) / 2
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
                    y: parent.narrow ? Theme.settingsStackOffset : (parent.height - height) / 2
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
                    y: parent.narrow ? Theme.settingsStackOffset : (parent.height - height) / 2
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

            Text {
                visible: ShellHealth.issueCount > 0
                width: parent.width
                leftPadding: page.width < Theme.settingsNarrowWidth
                    ? Theme.settingsMarkInset : Theme.settingsMarkInset + Theme.settingsLabelWidth
                text: (ShellHealth.integrationIssues.concat(ShellHealth.recentWarnings))[0] || ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.amber
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
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
            title: "Config"

            ResponsiveActionRow {
                width: parent.width
                breakpoint: 560
                descriptionMono: true
                description: "~/.config/fedora-config/shell.json"

                SettingsAction {
                    text: "Open"
                    glyph: "open_in_new"
                    onTriggered: page.openConfig()
                }
                SettingsAction {
                    text: "Reset all"
                    glyph: "undo"
                    danger: true
                    onTriggered: Settings.resetAll()
                }
            }
        }
    }
}
