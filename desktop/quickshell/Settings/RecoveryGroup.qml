import QtQuick
import "../Common"
SettingsGroup {
    width: parent.width
    title: I18n.tr("System generations")
    SettingsHint {
        width: parent.width
        text: I18n.tr("NixOS generations retain system code and configuration. Credentials, VPN profiles, documents, databases and plugin data stay in persistent storage. Generation rollback does not restore application data.")
    }
    ValueRow {
        width: parent.width
        label: I18n.tr("Boot menu")
        hint: Updates.deployment.recovery || I18n.tr("Earlier versions are in the boot menu: press Esc while the computer starts.")
        SettingsAction { text: I18n.tr("View generations"); onTriggered: Updates.openRecoveryPoints() }
    }
}
