pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "InputDraft.js" as Draft

// Region & formats: how the shell writes the time and the temperature. Each
// row's caption reads the result back just before its choices ("Now 19:16",
// "15° outside"), in the interface face: it is a phrase, not a code, and a
// mono caption beside a menu-face control read as a stray value.
SettingsPage {
    id: page
    pageReset: true
    readonly property SystemSettingsBackend service: SystemSettings.region
    property string timezone: ""
    property string locale: ""
    property string timezoneQuery: ""
    property string localeQuery: ""
    property string originalTimezone: ""
    property string originalLocale: ""
    property var originalLocaleValues: []
    readonly property bool timezoneDirty: timezone !== originalTimezone
    readonly property bool localeDirty: locale !== originalLocale
    readonly property string disabledReason: service.busy ? "Applying…" : !service.loaded ? "Loading…" : ""
    function load() {
        if (!service.loaded) return;
        if (!timezoneDirty) timezone = originalTimezone = service.snapshot.timezone || "";
        if (!localeDirty) {
            locale = originalLocale = service.snapshot.locale || "";
            originalLocaleValues = service.snapshot.localeValues || [];
        }
    }
    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: { page.service.acquire(); page.load(); }
        onReleased: page.service.release()
    }
    Connections {
        target: page.service
        function onSnapshotChanged() { page.load(); }
        function onLoadedChanged() { page.load(); }
        function onCompleted(result) {
            if (!result.success) return;
            if (page.service.request.action === "timezone") page.originalTimezone = page.timezone;
            if (page.service.request.action === "locale") page.originalLocale = page.locale;
        }
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

        SystemServiceStatus { width: parent.width; service: page.service; notice: page.service.message }
        SettingsGroup {
            width: parent.width
            title: "System timezone"
            DraftFieldRow {
                width: parent.width
                label: "Find a timezone"
                value: page.timezoneQuery
                placeholder: "City or region"
                mono: false
                onEdited: text => page.timezoneQuery = text
            }
            SelectRow {
                width: parent.width
                label: "Timezone"
                current: page.timezone
                model: Draft.filtered((page.service.snapshot.timezones || []).map(value => ({value: value, label: value.replace(/_/g, " ")})), page.timezoneQuery, page.timezone)
                disabledReason: page.disabledReason
                hint: "Changes the timezone for everyone on this computer. Authorization may be required."
                onPicked: value => page.timezone = value
            }
            ValueRow {
                width: parent.width
                visible: page.timezoneDirty
                label: "Timezone change"
                SettingsAction {
                    text: "Discard"
                    enabled: !page.service.busy
                    onTriggered: { page.timezone = page.originalTimezone; page.load(); }
                }
                SettingsAction {
                    text: "Apply timezone"
                    primary: true
                    enabled: page.service.loaded && !page.service.busy
                    onTriggered: page.service.run({action: "timezone", value: page.timezone, previous: page.originalTimezone})
                }
            }
        }
        SettingsGroup {
            width: parent.width
            title: "System language"
            DraftFieldRow {
                width: parent.width
                label: "Find a locale"
                value: page.localeQuery
                placeholder: "For example en_US or nl_NL"
                onEdited: text => page.localeQuery = text
            }
            SelectRow {
                width: parent.width
                label: "Language and region"
                current: page.locale
                model: Draft.filtered((page.service.snapshot.locales || []).map(value => ({value: value, label: value})), page.localeQuery, page.locale)
                disabledReason: page.disabledReason
                hint: "Installed locales only. Applies system wide after signing out; explicit regional format overrides are preserved."
                onPicked: value => page.locale = value
            }
            ValueRow {
                width: parent.width
                visible: page.localeDirty
                label: "Language change"
                hint: "Authorization may be required."
                SettingsAction {
                    text: "Discard"
                    enabled: !page.service.busy
                    onTriggered: { page.locale = page.originalLocale; page.load(); }
                }
                SettingsAction {
                    text: "Apply language"
                    primary: true
                    enabled: page.service.loaded && !page.service.busy
                    onTriggered: page.service.run({action: "locale", value: page.locale, previous: page.originalLocaleValues})
                }
            }
        }

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
                caption: "Now " + Qt.formatDateTime(clock.date, Settings.clock24 ? "HH:mm" : "h:mm AP")
                captionMono: false
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
                captionMono: false
            }
        }
    }
}
