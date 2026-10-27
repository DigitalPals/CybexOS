import QtQuick
import ".."
import "../../Common"

// One indicator for confirmed available updates; it opens Software Update.
// Errors, recovery and completed transactions stay reachable through
// Control Center and the launcher.
BarModule {
    id: root
    moduleId: "updates"
    detailSaving: chip.detailSaving

    BarIcon {
        id: chip
        host: root.host
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        glyph: "deployed_code_update"
        glyphSize: Theme.barIconSize - 1
        glyphWeight: 600
        glyphWidth: Theme.barIconSize
        label: ""
        compact: root.compact
        tooltip: Updates.ready ? I18n.tr("Update ready to install · Open Software Update")
            : I18n.tr("System updates available · Open Software Update")
        tooltipAlign: 1
        Accessible.role: Accessible.Button
        Accessible.name: I18n.tr("Software Update")
        onClicked: Updates.show()
    }
}
