import QtQuick
import "../Common"
import "../Common/SettingsHelpers.js" as SettingsHelpers

// Preferences for the machine as a whole. Diagnostics and the settings file
// live on About; the usage poll interval lives with the Usage widget.
SettingsPage {
    id: page

    property double nowSecs: Date.now() / 1000
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
    readonly property date nowDate: new Date(page.nowSecs * 1000)

    Timer {
        interval: 1000
        running: page.visible
        repeat: true
        onTriggered: page.nowSecs = Date.now() / 1000
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
                description: "Stays awake while plugged in"
                disabledReason: page.idleOverrideReason !== "" ? page.idleOverrideReason
                    : Settings.idleSuspendMins === 0 ? "Suspend is set to Never" : ""
            }
            SettingsHint {
                width: parent.width
                text: SysInfo.idleUserConfig
                    ? "~/.config/fedora-config/hypr/hypridle.conf replaces these timeouts. Remove it to use them."
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
    }
}
