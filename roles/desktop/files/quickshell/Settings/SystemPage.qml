pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/SettingsHelpers.js" as SettingsHelpers
import "../Common/RecoveryHelpers.js" as RecoveryHelpers

// Preferences for the machine as a whole. Diagnostics and the settings file
// live on About; the usage poll interval lives with the Usage widget.
SettingsPage {
    id: page

    // A user-owned hypridle.conf replaces the rendered idle configuration,
    // so these rows would change nothing while it exists.
    readonly property string idleOverrideReason: SysInfo.idleUserConfig
        ? "Set in your hypridle.conf" : ""

    function idleChoices(values) {
        return values.map(mins => ({
            value: mins,
            label: mins === 0 ? "Never" : mins < 60 ? mins + " min" : mins / 60 + " h"
        }));
    }

    onVisibleChanged: {
        if (visible)
            SysInfo.refreshIdleUserConfig();
    }

    // The clock caption shows hours and minutes, so tick on the minute, and
    // only while the page is on screen.
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
        enabled: page.visible
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Formats"

            PickerRow {
                width: parent.width
                label: "Clock"
                settingKey: "clock24"
                model: [
                    { value: true, label: "24 h" },
                    { value: false, label: "12 h" }
                ]
                caption: Qt.formatDateTime(clock.date, Settings.clock24 ? "HH:mm" : "h:mm AP")
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
        }

        SettingsGroup {
            width: parent.width
            title: "Touchpad"

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
                marks: [1.0]
                hint: "1.0× is Hyprland's default"
                dirty: Math.abs(Settings.scrollFactor - Settings.defaults.scrollFactor) > 0.001
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Night light"

            SwitchRow {
                width: parent.width
                label: "Night light"
                settingKey: "nightLight"
                description: SysInfo.nightLightError !== "" ? SysInfo.nightLightError
                    : SysInfo.nightLightPending
                        ? (Settings.nightLight ? "Starting…" : "Stopping…")
                    : "Warms the screen to reduce blue light"
                hintTone: SysInfo.nightLightError !== "" ? "error" : "info"
            }
            SliderRow {
                width: parent.width
                label: "Warmth"
                settingKey: "warmth"
                min: 1900
                max: 4500
                step: 50
                unit: "K"
                gradientTrack: true
                hint: "Lower is warmer"
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Idle"

            PickerRow {
                width: parent.width
                label: "Lock screen"
                settingKey: "idleLockMins"
                model: page.idleChoices(SettingsHelpers.IDLE_LOCK_MINS)
                disabledReason: page.idleOverrideReason
            }
            PickerRow {
                width: parent.width
                label: "Screen off"
                settingKey: "idleScreenOffMins"
                model: page.idleChoices(SettingsHelpers.IDLE_SCREEN_OFF_MINS)
                disabledReason: page.idleOverrideReason
            }
            PickerRow {
                width: parent.width
                label: "Suspend"
                settingKey: "idleSuspendMins"
                model: page.idleChoices(SettingsHelpers.IDLE_SUSPEND_MINS)
                disabledReason: page.idleOverrideReason
                hint: "Locks the screen first"
            }
            SwitchRow {
                width: parent.width
                visible: Battery.isLaptop || Settings.idleSuspendBatteryOnly
                label: "Only on battery"
                settingKey: "idleSuspendBatteryOnly"
                description: "Waits while plugged in; suspends once unplugged"
                disabledReason: page.idleOverrideReason !== "" ? page.idleOverrideReason
                    : Settings.idleSuspendMins === 0 ? "Suspend is set to Never" : ""
            }
            SettingsHint {
                width: parent.width
                text: SysInfo.idleUserConfig
                    ? "~/.config/cybexos/hypr/hypridle.conf replaces these timeouts. Remove it to use them."
                    : SysInfo.idleTimeoutsError !== "" ? SysInfo.idleTimeoutsError
                    : "Counted from the last keyboard or pointer input. Stay awake pauses them."
                tone: SysInfo.idleUserConfig ? "warning"
                    : SysInfo.idleTimeoutsError !== "" ? "error" : "info"
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
                hint: SysInfo.idleInhibited ? "Active · " + SysInfo.idleInhibitStatus
                    : "Keeps the screen on and the computer from sleeping"
                hintTone: SysInfo.idleInhibited ? "active" : "info"
                onPicked: value => SysInfo.setIdleInhibitMode(value)
            }

            ResponsiveActionRow {
                width: parent.width
                description: "Defaults and sign-in behavior"

                SettingsAction {
                    text: "Indicator settings"
                    glyph: "open_in_new"
                    Accessible.name: "Open Indicators widget settings"
                    onTriggered: Settings.openWidgetSettings("indicators")
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "On-screen display"

            PickerRow {
                width: parent.width
                label: "Placement"
                settingKey: "osd"
                resetLabel: "OSD placement"
                model: [
                    { value: "top", label: "Top center" },
                    { value: "bottom", label: "Bottom center" }
                ]
                hint: "Where the volume and brightness pop-up appears"
            }
        }

        // Recovery points: taken before every update, bootable from GRUB,
        // restorable here. The recovery-boot notification scrolls to it.
        SettingsGroup {
            id: recoveryGroup
            readonly property string settingKey: "recoveryPoints"
            property string confirmId: ""
            width: parent.width
            title: "Recovery points"
            rowSpacing: Theme.settingsContentSpacing

            SettingsHint {
                width: parent.width
                visible: Recovery.recoveryBoot
                tone: "warning"
                text: "You are running the recovery point from " + RecoveryHelpers.pointTime(Recovery.recoveryBootId)
                    + ". Changes made now are temporary and disappear when you restart."
            }
            ResponsiveActionRow {
                width: parent.width
                visible: Recovery.recoveryBoot && !Recovery.restartPending
                description: recoveryGroup.confirmId === Recovery.recoveryBootId
                    ? "Replaces the installed system at the next restart. Your home folder is not changed."
                    : "Keep this recovery point as the installed system"
                SettingsAction {
                    text: recoveryGroup.confirmId === Recovery.recoveryBootId
                        ? "Confirm restore" : "Restore this recovery point"
                    glyph: "history"
                    danger: recoveryGroup.confirmId === Recovery.recoveryBootId
                    enabled: !Recovery.busy
                    onTriggered: {
                        if (recoveryGroup.confirmId === Recovery.recoveryBootId)
                            Recovery.restore(Recovery.recoveryBootId);
                        else
                            recoveryGroup.confirmId = Recovery.recoveryBootId;
                    }
                }
                SettingsAction {
                    visible: recoveryGroup.confirmId === Recovery.recoveryBootId
                    text: "Cancel"
                    glyph: "close"
                    onTriggered: recoveryGroup.confirmId = ""
                }
            }
            SettingsHint {
                width: parent.width
                visible: Recovery.restartPending
                tone: "active"
                text: "A restored recovery point starts at the next restart."
            }
            SettingsHint {
                width: parent.width
                visible: Recovery.loaded && !Recovery.supported && !Recovery.recoveryBoot
                tone: "info"
                text: "Recovery points need the standard Btrfs layout"
                    + (Recovery.unsupportedReason !== "" ? " (" + Recovery.unsupportedReason + ")." : ".")
            }
            SettingsHint {
                width: parent.width
                visible: Recovery.supported && Recovery.points.length === 0
                text: "None yet. One is taken automatically before each update."
            }

            Repeater {
                model: Recovery.points
                delegate: Item {
                    id: pointRow
                    required property var modelData
                    readonly property bool confirming: recoveryGroup.confirmId === modelData.id
                    readonly property bool running: modelData.id === Recovery.recoveryBootId
                    width: recoveryGroup.width
                    implicitHeight: pointColumn.implicitHeight
                    height: implicitHeight

                    Column {
                        id: pointColumn
                        width: parent.width
                        spacing: Theme.settingsContentSpacing / 2

                        Text {
                            width: parent.width
                            leftPadding: Theme.settingsMarkInset
                            text: RecoveryHelpers.pointTime(pointRow.modelData.id) + " · "
                                + RecoveryHelpers.pointLabel(pointRow.modelData)
                                + (pointRow.running ? " · running now" : "")
                            color: Theme.textHi
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.control
                            elide: Text.ElideRight
                        }
                        ResponsiveActionRow {
                            width: parent.width
                            description: pointRow.confirming
                                ? "Replaces the installed system at the next restart. Your home folder is not changed."
                                : RecoveryHelpers.pointStatus(pointRow.modelData)
                            SettingsAction {
                                visible: !pointRow.running && !Recovery.restartPending
                                text: pointRow.confirming ? "Confirm restore" : "Restore…"
                                glyph: "history"
                                danger: pointRow.confirming
                                enabled: !Recovery.busy
                                Accessible.name: "Restore recovery point from " + RecoveryHelpers.pointTime(pointRow.modelData.id)
                                onTriggered: {
                                    if (pointRow.confirming)
                                        Recovery.restore(pointRow.modelData.id);
                                    else
                                        recoveryGroup.confirmId = pointRow.modelData.id;
                                }
                            }
                            SettingsAction {
                                visible: pointRow.confirming
                                text: "Cancel"
                                glyph: "close"
                                onTriggered: recoveryGroup.confirmId = ""
                            }
                        }
                    }
                }
            }

            SettingsHint {
                width: parent.width
                visible: Recovery.busy || Recovery.error !== "" || Recovery.result !== ""
                tone: Recovery.error !== "" ? "error" : "active"
                text: Recovery.busy ? "Restoring…" : Recovery.error !== "" ? Recovery.error : Recovery.result
            }
            SettingsHint {
                width: parent.width
                visible: Recovery.supported
                maximumLines: 4
                text: "The five newest are kept; your home folder is never rolled back. To try one "
                    + "without changing anything, restart and hold Shift (or press Esc) until the boot "
                    + "menu appears, then open CybexOS recovery points."
            }
        }
    }
}
