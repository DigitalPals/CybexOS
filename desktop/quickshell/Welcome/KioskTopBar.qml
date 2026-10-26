import QtQuick
import "../Common"

// installer/kiosk/ui/app.slint, TopBar: the wordmark, the step indicator
// centred on the canvas, and the status pills. In the guide the pills show
// the network, the keyboard layout and the language, each a way to change
// it, and the last one closes the guide.
Item {
    id: root
    property var steps: []
    property int current: 0
    readonly property var region: SystemSettings.region.snapshot
    readonly property var layouts: (SystemSettings.input.snapshot.keyboard || {}).layouts || []
    readonly property string network: EthernetState.connected ? I18n.tr("Ethernet")
        : WifiState.connected ? WifiState.name : NetworkStatus.online ? I18n.tr("Online") : I18n.tr("Offline")
    readonly property bool offline: !EthernetState.connected && !WifiState.connected && !NetworkStatus.online
    height: Kiosk.px(72)
    Claim { active: root.visible; onClaimed: SystemSettings.region.acquire(); onReleased: SystemSettings.region.release() }
    Claim { active: root.visible; onClaimed: SystemSettings.input.acquire(); onReleased: SystemSettings.input.release() }
    Claim { active: root.visible; onClaimed: EthernetState.acquire(); onReleased: EthernetState.release() }
    Image {
        x: Kiosk.px(40)
        anchors.verticalCenter: parent.verticalCenter
        height: Kiosk.px(39)
        width: height * 198 / 46.6
        source: "assets/cybexos-logo.svg"
        sourceSize.height: Math.ceil(height * 2)
        fillMode: Image.PreserveAspectFit
        smooth: true
        Accessible.role: Accessible.Graphic
        Accessible.name: "Cybex OS" // i18n: untranslated (brand)
    }
    KioskStepper {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        visible: root.current > 0
        steps: root.steps
        current: root.current
    }
    Row {
        anchors.right: parent.right
        anchors.rightMargin: Kiosk.px(40)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Kiosk.px(8)
        KioskChip {
            text: root.network
            icon: EthernetState.connected ? "network" : root.offline ? "wifi_off" : "wifi"
            warn: root.offline
            Accessible.name: I18n.format("Network: %1", [root.network])
            onClicked: { Welcome.stepAside(false); Settings.showPanel("network"); }
        }
        KioskChip {
            visible: root.layouts.length > 0
            text: root.layouts.length > 0 ? String(root.layouts[0].layout).toUpperCase() : ""
            icon: "keyboard"
            Accessible.name: I18n.tr("Change keyboard layout")
            onClicked: Welcome.openSheet("keyboard")
        }
        KioskChip {
            visible: !!root.region.locale
            text: String(root.region.locale || "").slice(0, 2).toUpperCase()
            icon: "language"
            Accessible.name: I18n.tr("Change language")
            onClicked: Welcome.openSheet("language")
        }
        KioskChip {
            icon: "close"
            Accessible.name: I18n.tr("Close welcome guide")
            onClicked: Welcome.dismiss()
        }
    }
}
