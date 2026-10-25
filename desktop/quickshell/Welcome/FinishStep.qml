pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Settings" as SettingsUi
Column {
    id: root
    spacing: Theme.scaled(20)
    function itemY(id) {
        for (let i = 0; i < items.count; i++) {
            const item = items.itemAt(i);
            if (item && item.objectName === id) return item.y;
        }
        return 0;
    }
    function label(id) {
        const labels = {webapps: I18n.tr("Web apps"), assistant: I18n.tr("AI assistant"),
            fingerprint: I18n.tr("Fingerprint"), security: I18n.tr("Security keys"), backup: I18n.tr("Backups"), accounts: I18n.tr("Online accounts")};
        return labels[id] || id;
    }
    function detail(id) {
        const details = {webapps: I18n.tr("Keep the apps you like, remove the ones you do not, or add your own."),
            assistant: I18n.tr("Choose an agent and sign in when you want a hand."),
            fingerprint: I18n.tr("Use your fingerprint for unlocking and authorisation."),
            security: I18n.tr("Manage hardware security keys in Settings. Connected keys are not detected here."),
            backup: I18n.tr("Give your personal files a second home."),
            accounts: I18n.tr("Connect your calendars and online accounts.")};
        return details[id] || "";
    }
    Component.onCompleted: { Welcome.refreshWebapps(); Backup.refresh(); }
    Claim { active: root.visible; onClaimed: SystemSettings.security.acquire(); onReleased: SystemSettings.security.release() }
    Claim { active: root.visible; onClaimed: SystemSettings.accounts.acquire(); onReleased: SystemSettings.accounts.release() }
    Rectangle {
        width: parent.width; height: summary.height + Theme.scaled(32); radius: Theme.cardRadius; color: Theme.accentBgSoft
        Column {
            id: summary; x: Theme.scaled(16); y: Theme.scaled(16); width: parent.width - x * 2; spacing: Theme.controlSpacing
            GuideText { text: I18n.tr("A space that feels like you."); font.pixelSize: Theme.typography.title; font.weight: Theme.weightSemibold }
            GuideText {
                width: parent.width; tone: "muted"
                text: I18n.format("%1 mode · %2 accent · %3 text", [Settings.themeMode === "light" ? I18n.tr("Light") : I18n.tr("Dark"),
                    Settings.paletteMode === "wallpaper" ? I18n.tr("Wallpaper") : Settings.accent,
                    Settings.textScale === "default" ? I18n.tr("Default") : Settings.textScale === "large" ? I18n.tr("Large") : I18n.tr("Larger")])
            }
            GuideText { width: parent.width; text: Settings.wall ? I18n.format("Wallpaper: %1", [Settings.wall]) : I18n.tr("Your wallpaper is ready to choose."); tone: "muted"; elide: Text.ElideMiddle; maximumLineCount: 1 }
        }
    }
    GuideText { width: parent.width; text: I18n.tr("A few more things, whenever you are ready"); font.weight: Theme.weightSemibold }
    Repeater {
        id: items
        model: Welcome.checklist
        delegate: Column {
            id: item
            required property var modelData
            objectName: modelData.id
            width: root.width; spacing: Theme.controlSpacing
            Rectangle { width: parent.width; height: 1; color: Theme.stroke }
            Row {
                width: parent.width; spacing: Theme.controlSpacing
                Sym { name: item.modelData.done === true ? "check" : "circle"; size: Theme.iconMedium; color: item.modelData.done === true ? Theme.connected : Theme.textFaint; anchors.verticalCenter: parent.verticalCenter }
                GuideText { text: root.label(item.modelData.id); font.weight: Theme.weightSemibold; anchors.verticalCenter: parent.verticalCenter }
                GuideText { visible: item.modelData.later; text: I18n.tr("Later"); tone: "muted"; anchors.verticalCenter: parent.verticalCenter }
                SettingsUi.SettingsAction {
                    text: I18n.tr("Open")
                    Accessible.name: I18n.format("Open %1 settings", [root.label(item.modelData.id)])
                    onTriggered: Settings.showPanel(item.modelData.page)
                }
                SettingsUi.SettingsAction {
                    text: item.modelData.later ? I18n.tr("Show again") : I18n.tr("Later")
                    Accessible.name: I18n.format("%1: %2", [root.label(item.modelData.id), text])
                    onTriggered: Welcome.later(item.modelData.id, !item.modelData.later)
                }
            }
            GuideText { width: parent.width; text: root.detail(item.modelData.id); tone: "muted"; font.pixelSize: Theme.typography.secondary }
            Column {
                visible: item.modelData.id === "webapps"; width: parent.width; spacing: Theme.controlSpacing
                GuideText { width: parent.width; visible: Welcome.webappsError !== ""; text: Welcome.webappsError; tone: "muted" }
                Repeater {
                    model: item.modelData.id === "webapps" ? Welcome.webapps.filter(app => app.default) : []
                    delegate: Row {
                        id: app
                        required property var modelData
                        width: item.width; spacing: Theme.controlSpacing
                        GuideText { width: Theme.scaled(160); text: app.modelData.name; anchors.verticalCenter: parent.verticalCenter }
                        SettingsUi.SettingsAction {
                            text: I18n.tr("Keep"); enabled: !Welcome.webappsBusy
                            Accessible.name: I18n.format("Keep %1", [app.modelData.name])
                            onTriggered: { Welcome.later("webapps", false); keepNote.text = I18n.format("%1 is installed and ready to use.", [app.modelData.name]); }
                        }
                        SettingsUi.SettingsAction {
                            text: I18n.tr("Remove"); enabled: !Welcome.webappsBusy
                            Accessible.name: I18n.format("Remove %1", [app.modelData.name])
                            onTriggered: Welcome.removeWebapp(app.modelData.id)
                        }
                    }
                }
                GuideText { id: keepNote; width: parent.width; visible: text !== ""; tone: "muted" }
                Row {
                    spacing: Theme.controlSpacing
                    SettingsUi.SettingsAction {
                        text: I18n.tr("Install another…")
                        onTriggered: { Launcher.openRequest = {tab: "actions", query: "Install web app"}; Launcher.show(); }
                    }
                    SettingsUi.SettingsAction { text: I18n.tr("Open Software"); onTriggered: Software.show() }
                }
            }
        }
    }
    GuideText { width: parent.width; text: I18n.tr("Everything here is also in Settings. Your password always remains available."); tone: "muted" }
}
