pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// The installer's time zone sheet over the guide, on the region backend
// Settings uses. It changes the zone for everyone on this computer and may
// ask for authorization.
KioskSheet {
    id: root
    readonly property SystemSettingsBackend service: SystemSettings.region
    readonly property string current: service.snapshot.timezone || ""
    property string choice: current
    title: I18n.tr("Time zone")
    subtitle: I18n.tr("Changes the time zone for everyone on this computer.")
    onClosed: Welcome.closeSheet()
    onCurrentChanged: if (choice === "") choice = current
    Claim { active: true; onClaimed: root.service.acquire(); onReleased: root.service.release() }
    Connections {
        target: root.service
        function onCompleted(result) {
            if (result.success && root.service.request.action === "timezone") Welcome.closeSheet();
        }
    }
    function city(zone) { return String(zone || "").split("/").pop().replace(/_/g, " "); }
    KioskPickList {
        anchors.top: parent.top
        anchors.bottom: status.top
        anchors.bottomMargin: Kiosk.px(10)
        width: parent.width
        focus: true
        placeholder: I18n.tr("Search cities or regions")
        model: (root.service.snapshot.timezones || []).map(value => ({value: value, label: root.city(value), detail: value}))
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
            text: I18n.format("Use %1", [root.city(root.choice)])
            enabled: root.service.loaded && !root.service.busy && root.choice !== "" && root.choice !== root.current
            onClicked: root.service.run({action: "timezone", value: root.choice, previous: root.current})
        }
    }
}
