import QtQuick
import "../Common"

// The state line at the top of a page whose values belong to a system
// service (NetworkManager, PipeWire, GOA, Hyprland's outputs). It speaks only
// when there is something to say: while the first read is in flight, while a
// change is being applied, and when a read or a change failed — then with a
// Refresh that reads the service again. Otherwise it takes no room at all,
// so a page does not open on a standing button and an empty line.
//
// `service` is any backend with SystemSettingsBackend's shape (error, busy,
// loaded, loading, refresh()); DisplaySettings has the same one. A page whose
// Apply bar already says "Applying…" turns `showBusy` off, and a page with a
// result worth keeping on screen after the bar is gone — a trial that ran
// out — passes it as `notice`.
Column {
    id: root

    property var service
    property bool showBusy: true
    property string notice: ""
    readonly property string text: !service ? ""
        : service.error !== "" ? service.error
        : root.showBusy && service.busy ? "Applying…"
        : !service.loaded ? "Loading…"
        : root.notice

    visible: text !== ""
    spacing: Theme.settingsRowSpacing

    SettingsHint {
        width: parent.width
        text: root.text
        tone: root.service && root.service.error !== "" ? "error" : "info"
    }
    SettingsAction {
        x: Theme.settingsMarkInset - Theme.scaled(8)
        visible: !!root.service && root.service.error !== ""
        text: "Refresh"
        glyph: "refresh"
        enabled: !!root.service && !root.service.busy && !root.service.loading
        onTriggered: {
            root.service.error = "";
            root.service.refresh();
        }
    }
}
