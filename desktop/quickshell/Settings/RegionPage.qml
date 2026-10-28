pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "InputDraft.js" as Draft

// Region & language: the system timezone and language, which build a system
// change, and how the shell writes the time and the temperature, which apply
// at once. The two system rows draft into RegionDrafts, so the choice
// survives leaving the page, and the Apply bar (or the header's Changes
// review) prepares both together: one build and one restart. Each format
// row's caption reads the result back just before its choices ("Now 19:16",
// "15° outside"), in the interface face: it is a phrase, not a code.
SettingsPage {
    id: page
    pageReset: true
    readonly property SystemSettingsBackend service: SystemSettings.region
    property string timezoneQuery: ""
    property string localeQuery: ""
    readonly property string disabledReason: service.busy ? "Preparing…" : !service.loaded ? "Loading…" : ""
    readonly property string draftText: [
        RegionDrafts.timezoneDirty ? RegionDrafts.timezone.replace(/_/g, " ") : "",
        RegionDrafts.localeDirty ? I18n.localeName(RegionDrafts.locale) : ""
    ].filter(Boolean).join(" · ")
    readonly property string preparedText: [
        RegionDrafts.prepared.timezone ? RegionDrafts.prepared.timezone.replace(/_/g, " ") : "",
        RegionDrafts.prepared.locale ? I18n.localeName(RegionDrafts.prepared.locale) : ""
    ].filter(Boolean).join(" · ")
    bottomInset: applyBar.reservedHeight

    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: { page.service.acquire(); RegionDrafts.load(); }
        onReleased: page.service.release()
    }

    overlay: ApplyBar {
        id: applyBar
        pending: RegionDrafts.dirty
        title: I18n.tr("System change not prepared yet")
        detail: page.draftText + " · " + (SettingsChanges.systemBusy && !page.service.busy
            ? I18n.tr("finish the current system change first")
            : I18n.tr("needs an administrator and a restart"))
        busy: page.service.busy
        applyEnabled: page.service.loaded && !SettingsChanges.systemBusy
        applyText: I18n.tr("Prepare change")
        onDiscard: RegionDrafts.discard()
        onApply: RegionDrafts.prepare()
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
        // A prepared change is the deployment's now: say where it stands
        // until the restart that uses it.
        SettingsHint {
            width: parent.width
            visible: RegionDrafts.preparing && page.preparedText !== ""
            tone: "active"
            text: (Updates.rebootRecommended ? I18n.tr("Restart to use ")
                : Updates.ready ? I18n.tr("Review in Software Update, then restart: ")
                : I18n.tr("Preparing a system change: ")) + page.preparedText
        }
        SettingsGroup {
            width: parent.width
            title: I18n.tr("System timezone")
            changeTag: "restart"
            DraftFieldRow {
                width: parent.width
                label: I18n.tr("Find a timezone")
                value: page.timezoneQuery
                placeholder: I18n.tr("City or region")
                mono: false
                onEdited: text => page.timezoneQuery = text
            }
            SelectRow {
                width: parent.width
                label: I18n.tr("Timezone")
                current: RegionDrafts.timezone
                dirty: RegionDrafts.timezoneDirty
                model: Draft.filtered((page.service.snapshot.timezones || []).map(value => ({value: value, label: value.replace(/_/g, " ")})), page.timezoneQuery, RegionDrafts.timezone)
                disabledReason: page.disabledReason
                hint: RegionDrafts.timezoneDirty
                    ? I18n.tr("Was ") + RegionDrafts.originalTimezone.replace(/_/g, " ") + I18n.tr(" · applies after a restart")
                    : I18n.tr("Changes the timezone for everyone on this computer.")
                onPicked: value => RegionDrafts.timezone = value
                onResetRequested: RegionDrafts.discardTimezone()
            }
        }
        SettingsGroup {
            width: parent.width
            title: I18n.tr("System language")
            changeTag: "restart"
            DraftFieldRow {
                width: parent.width
                label: I18n.tr("Find a locale")
                value: page.localeQuery
                placeholder: I18n.tr("For example en_US or nl_NL")
                onEdited: text => page.localeQuery = text
            }
            SelectRow {
                width: parent.width
                label: I18n.tr("Language and region")
                current: RegionDrafts.locale
                dirty: RegionDrafts.localeDirty
                // Named as the welcome guide names it, so "Dutch" finds nl_NL too.
                model: Draft.filtered((page.service.snapshot.locales || []).map(value => {
                    const name = I18n.localeName(value);
                    return {value: value, label: name === value ? value : name + " · " + value};
                }), page.localeQuery, RegionDrafts.locale)
                disabledReason: page.disabledReason
                hint: RegionDrafts.localeDirty
                    ? I18n.tr("Was ") + I18n.localeName(RegionDrafts.originalLocale) + I18n.tr(" · applies after a restart")
                    : I18n.tr("Installed locales only. Explicit regional format overrides are preserved.")
                onPicked: value => RegionDrafts.locale = value
                onResetRequested: RegionDrafts.discardLocale()
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Formats")

            PickerRow {
                width: parent.width
                label: I18n.tr("Clock")
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
                label: I18n.tr("Temperature")
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
