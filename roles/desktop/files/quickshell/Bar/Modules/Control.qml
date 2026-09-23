import QtQuick
import ".."
import "../../Common"

BarModule {
    id: root
    moduleId: "control"

    BarChip {
        id: controlButton
        host: root.host
        panelName: "control"
        isle: root.isle
        anchorItem: root.groupAnchor ?? controlButton
        hPadding: 5
        tooltip: "Control Center"
        Accessible.role: Accessible.Button
        Accessible.name: "Control Center"

        BarBrandIcon {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.barIconSize
            height: Theme.barIconSize
            name: "fedora"
            highlighted: controlButton.held || controlButton.hovered
        }
    }
}
