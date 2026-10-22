import QtQuick
import ".."
import "../../Common"

// T3 Code status chip, inside the right cluster's chip group.
BarModule {
    id: root

    moduleId: "t3"
    detailSaving: Settings.modOpts.t3.showLabel ? t3Chip.detailSaving : 0

    T3Chip {
        id: t3Chip
        displayMode: root.compact || !Settings.modOpts.t3.showLabel ? 0 : 2
        host: root.host
        panelName: "t3code"
        isle: root.isle
        anchorItem: root.groupAnchor ?? t3Chip
    }
}
