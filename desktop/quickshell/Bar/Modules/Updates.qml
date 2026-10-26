import QtQuick
import ".."
import "../../Common"

// One indicator for confirmed available updates. Errors, recovery and completed
// transactions remain accessible through Control Center and the launcher.
BarModule {
    id: root
    moduleId: "updates"
    detailSaving: chip.detailSaving

    BarIcon {
        id: chip
        host: root.host
        panelName: "updates"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        glyph: "deployed_code_update"
        glyphSize: Theme.barIconSize - 1
        glyphWeight: 600
        glyphWidth: Theme.barIconSize
        label: ""
        compact: root.compact
        tooltip: I18n.tr("System updates available · Review before installing")
        tooltipAlign: 1
    }
}
