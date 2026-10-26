pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// The installer's language sheet over the guide, on the region backend
// Settings uses. Installed locales only; it applies after signing out and
// may ask for authorization.
KioskSheet {
    id: root
    readonly property SystemSettingsBackend service: SystemSettings.region
    readonly property string current: service.snapshot.locale || ""
    property string choice: current
    title: I18n.tr("Language")
    subtitle: I18n.tr("Installed languages. The change applies everywhere after you sign out.")
    onClosed: Welcome.closeSheet()
    onCurrentChanged: if (choice === "") choice = current
    Claim { active: true; onClaimed: root.service.acquire(); onReleased: root.service.release() }
    Connections {
        target: root.service
        function onCompleted(result) {
            if (result.success && root.service.request.action === "locale") Welcome.closeSheet();
        }
    }
    function use() {
        root.service.run({action: "locale", value: root.choice, previous: root.service.snapshot.localeValues || []});
    }
    KioskPickList {
        id: list
        anchors.top: parent.top
        anchors.bottom: status.top
        anchors.bottomMargin: Kiosk.px(10)
        width: parent.width
        focus: true
        placeholder: I18n.tr("Search languages")
        model: (root.service.snapshot.locales || []).map(value => {
            const name = I18n.localeName(value);
            return {value: value, label: name === value ? value : name, detail: value};
        })
        current: root.current
        selected: root.choice
        onChosen: value => root.choice = value
    }
    KioskText {
        id: status
        anchors.bottom: actions.top
        anchors.bottomMargin: Kiosk.px(12)
        width: parent.width
        visible: text !== ""
        text: root.service.error || root.service.message || (root.service.busy ? I18n.tr("Applying…") : "")
        size: 13.5
        tone: root.service.error ? "red" : "fog"
        wrapMode: Text.WordWrap
    }
    Row {
        id: actions
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        spacing: Kiosk.px(12)
        KioskButton { small: true; text: I18n.tr("Cancel"); onClicked: Welcome.closeSheet() }
        KioskButton {
            small: true
            kind: "primary"
            text: I18n.format("Use %1", [I18n.localeName(root.choice)])
            enabled: root.service.loaded && !root.service.busy && root.choice !== "" && root.choice !== root.current
            onClicked: root.use()
        }
    }
}
