pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Settings" as SettingsUi
Column {
    id: root
    spacing: Theme.scaled(18)
    readonly property var region: SystemSettings.region.snapshot
    readonly property var input: SystemSettings.input.snapshot.keyboard || ({})
    readonly property var chips: [
        {label: I18n.tr("Language"), value: region.locale || I18n.tr("Not available"), page: "region"},
        {label: I18n.tr("Keyboard layout"), value: (input.layouts || []).map(entry => entry.layout + (entry.variant ? " · " + entry.variant : "")).join(", ") || I18n.tr("Not available"), page: "keyboard"},
        {label: I18n.tr("Timezone"), value: region.timezone || I18n.tr("Not available"), page: "region"}
    ]
    Claim { active: root.visible; onClaimed: SystemSettings.region.acquire(); onReleased: SystemSettings.region.release() }
    Claim { active: root.visible; onClaimed: SystemSettings.input.acquire(); onReleased: SystemSettings.input.release() }
    Rectangle {
        width: parent.width; height: Theme.scaled(126)
        radius: Theme.cardRadius; color: Theme.accentBgSoft
        Row {
            anchors.fill: parent; anchors.margins: Theme.scaled(24); spacing: Theme.scaled(22)
            Image {
                width: Theme.scaled(64); height: width
                anchors.verticalCenter: parent.verticalCenter
                source: "../assets/cybexos.svg"
                fillMode: Image.PreserveAspectFit
            }
            Column {
                width: parent.width - Theme.scaled(90); anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.controlSpacing
                GuideText { width: parent.width; text: I18n.tr("Your desktop, your way."); font.pixelSize: Theme.typography.title; font.weight: Theme.weightSemibold }
                GuideText { width: parent.width; text: I18n.tr("A few small choices to make this space feel like home. Every change takes effect right away."); tone: "muted" }
            }
        }
    }
    GuideText { text: I18n.tr("Already set up for you"); font.weight: Theme.weightSemibold }
    Repeater {
        model: root.chips
        delegate: Rectangle {
            id: chip
            required property var modelData
            width: root.width; height: Theme.scaled(60)
            radius: Theme.chipRadius; color: Theme.cardFill
            Column {
                anchors.left: parent.left; anchors.leftMargin: Theme.scaled(16)
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - change.width - Theme.scaled(40))
                GuideText { text: chip.modelData.label; tone: "muted"; font.pixelSize: Theme.typography.secondary }
                GuideText { width: parent.width; text: chip.modelData.value; maximumLineCount: 1; elide: Text.ElideRight }
            }
            SettingsUi.SettingsAction {
                id: change
                anchors.right: parent.right; anchors.rightMargin: Theme.controlSpacing; anchors.verticalCenter: parent.verticalCenter
                text: I18n.tr("Change")
                Accessible.name: I18n.format("Change %1", [chip.modelData.label])
                onTriggered: Settings.showPanel(chip.modelData.page)
            }
        }
    }
    Row {
        spacing: Theme.controlSpacing
        Rectangle { width: Theme.scaled(8); height: width; radius: width / 2; color: NetworkStatus.online ? Theme.connected : Theme.amber; anchors.verticalCenter: parent.verticalCenter }
        GuideText { anchors.verticalCenter: parent.verticalCenter; text: NetworkStatus.online ? I18n.tr("You are connected. Make yourself at home.") : I18n.tr("You can explore offline, too."); tone: "muted" }
        SettingsUi.SettingsAction {
            visible: !NetworkStatus.online
            text: I18n.tr("Connect to Wi-Fi")
            onTriggered: Settings.showPanel("network")
        }
    }
}
