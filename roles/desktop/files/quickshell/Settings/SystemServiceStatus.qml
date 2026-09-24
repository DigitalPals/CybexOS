import QtQuick
import "../Common"

Column {
    id: root
    property SystemSettingsBackend service
    spacing: Theme.settingsRowSpacing
    SettingsHint {
        width: parent.width
        text: root.service.error || (root.service.busy ? "Applying…"
            : root.service.message || (!root.service.loaded ? "Loading…" : ""))
        tone: root.service.error ? "error" : "info"
    }
    SettingsAction {
        text: "Refresh"
        enabled: !root.service.busy && !root.service.loading
        onTriggered: { root.service.error = ""; root.service.refresh(); }
    }
}
