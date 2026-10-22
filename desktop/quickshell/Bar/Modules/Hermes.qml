import QtQuick
import ".."
import "../../Common"

// Hermes Agent mini-client, inside the right cluster's chip group.
BarModule {
    id: root

    moduleId: "hermes"
    detailSaving: Settings.modOpts.hermes.showLabel ? hermesChip.detailSaving : 0

    HermesChip {
        id: hermesChip
        displayMode: root.compact || !Settings.modOpts.hermes.showLabel ? 0 : 2
        host: root.host
        panelName: "hermes"
        isle: root.isle
        anchorItem: root.groupAnchor ?? hermesChip
    }
}
