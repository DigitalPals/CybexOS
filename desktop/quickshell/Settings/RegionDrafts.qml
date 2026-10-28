pragma Singleton
import QtQuick
import "../Common"

// The system timezone and language a person picked but has not applied yet.
// Session-owned like InputDrafts: leaving Region & language, searching or
// closing the window keeps the choice until Apply or Discard settles it, and
// the header's Changes review applies both as one system change, so a move
// to another country is one build and one restart (2026-10 redesign).
QtObject {
    id: root

    readonly property SystemSettingsBackend service: SystemSettings.region
    property string timezone: ""
    property string locale: ""
    property string originalTimezone: ""
    property string originalLocale: ""
    property var originalLocaleValues: []
    readonly property bool timezoneDirty: timezone !== originalTimezone
    readonly property bool localeDirty: locale !== originalLocale
    readonly property bool dirty: timezoneDirty || localeDirty
    readonly property bool busy: service.busy
    // What the last successful request prepared: the deployment holds it
    // until it is applied and the computer restarts, or it is discarded in
    // Software Update.
    property var prepared: ({})
    readonly property bool preparing: Updates.deployment.changeKind === "region"
        && (Updates.runActive || Updates.ready || Updates.rebootRecommended)

    function load() {
        if (!service.loaded)
            return;
        if (!timezoneDirty)
            timezone = originalTimezone = service.snapshot.timezone || "";
        if (!localeDirty) {
            locale = originalLocale = service.snapshot.locale || "";
            originalLocaleValues = service.snapshot.localeValues || [];
        }
    }

    function discardTimezone() {
        timezone = originalTimezone;
        load();
    }

    function discardLocale() {
        locale = originalLocale;
        load();
    }

    function discard() {
        timezone = originalTimezone;
        locale = originalLocale;
        load();
    }

    // Every pending regional change in one request (system_settings_region
    // "stage"); the updater builds one generation for them.
    function prepare() {
        const changes = [];
        if (timezoneDirty)
            changes.push({ field: "timezone", value: timezone, previous: originalTimezone });
        if (localeDirty)
            changes.push({ field: "locale", value: locale, previous: originalLocaleValues });
        if (changes.length === 0 || !service.loaded)
            return false;
        return service.run({ action: "stage", changes: changes });
    }

    property Connections updates: Connections {
        target: root.service
        function onSnapshotChanged() { root.load(); }
        function onLoadedChanged() { root.load(); }
        function onCompleted(result) {
            if (root.service.request.action !== "stage" || !result.success)
                return;
            // The preview now carries these values; the drafts are settled.
            // The running system keeps its old ones until the restart.
            const prepared = {};
            for (const change of root.service.request.changes)
                prepared[change.field] = change.value;
            root.prepared = prepared;
            root.timezone = root.originalTimezone;
            root.locale = root.originalLocale;
        }
    }
}
