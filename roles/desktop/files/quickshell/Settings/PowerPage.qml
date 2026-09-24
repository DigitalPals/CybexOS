pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/SettingsHelpers.js" as SettingsHelpers
import "IdleTimelineModel.js" as IdleTimelineModel

// Power: what happens while the computer sits idle, and how to hold that
// off for a while. The timeline shows the three idle delays in order; each
// is a dropdown, because seven choices on one track wrapped at ordinary
// widths.
SettingsPage {
    id: page
    pageReset: true

    // A user-owned hypridle.conf replaces the rendered idle configuration,
    // so these rows would change nothing while it exists.
    readonly property string idleOverrideReason: SysInfo.idleUserConfig
        ? "Set in your hypridle.conf" : ""

    function idleChoices(values) {
        return values.map(mins => ({
            value: mins,
            label: IdleTimelineModel.durationLabel(mins)
        }));
    }

    onVisibleChanged: {
        if (visible)
            SysInfo.refreshIdleUserConfig();
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Idle"

            IdleTimeline {
                width: parent.width
                overridden: SysInfo.idleUserConfig
            }
            SelectRow {
                width: parent.width
                label: "Lock screen"
                settingKey: "idleLockMins"
                model: page.idleChoices(SettingsHelpers.IDLE_LOCK_MINS)
                disabledReason: page.idleOverrideReason
            }
            SelectRow {
                width: parent.width
                label: "Screen off"
                settingKey: "idleScreenOffMins"
                model: page.idleChoices(SettingsHelpers.IDLE_SCREEN_OFF_MINS)
                disabledReason: page.idleOverrideReason
            }
            SelectRow {
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
                hint: SysInfo.idleInhibitError !== "" ? SysInfo.idleInhibitError
                    : SysInfo.idleInhibited ? "Active · " + SysInfo.idleInhibitStatus
                    : "Keeps the screen on and the computer from sleeping"
                hintTone: SysInfo.idleInhibitError !== "" ? "error"
                    : SysInfo.idleInhibited ? "active" : "info"
                onPicked: value => SysInfo.setIdleInhibitMode(value)
            }

            // The bar's stay-awake indicator keeps its own options with the
            // other bar widgets; this row only points there.
            ValueRow {
                width: parent.width
                label: "Bar indicator"
                hint: "What a click on it starts, and whether it stays on after you sign in"

                SettingsAction {
                    text: "Indicator settings"
                    glyph: "arrow_forward"
                    Accessible.name: "Open Indicators widget settings"
                    onTriggered: Settings.openWidgetSettings("indicators")
                }
            }
        }
    }
}
