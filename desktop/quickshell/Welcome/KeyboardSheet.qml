pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Settings" as SettingsUi

// The installer's keyboard sheet over the guide. Choosing a layout makes it
// the first one, which is used when you sign in; other layouts stay. It
// applies through the same session draft as Settings → Keyboard.
KioskSheet {
    id: root
    readonly property var editState: SettingsUi.InputDrafts.keyboard
    readonly property var service: editState.service
    readonly property var layouts: (service.snapshot.keyboard || {}).layouts || []
    readonly property string current: layouts.length > 0 ? layouts[0].layout : ""
    property string choice: current
    property bool submitted: false
    title: I18n.tr("Keyboard")
    subtitle: I18n.tr("The layout you type with. The same list is in Settings → Keyboard.")
    onClosed: Welcome.closeSheet()
    onCurrentChanged: if (choice === "") choice = current
    Claim {
        active: true
        onClaimed: { root.service.acquire(); root.editState.refresh(); }
        onReleased: root.service.release()
    }
    Connections {
        target: root.service
        function onCompleted(result) {
            if (root.submitted && result.success) Welcome.closeSheet();
            root.submitted = false;
        }
    }
    function use() {
        const rest = root.layouts.filter(entry => entry.layout !== root.choice);
        root.editState.draft = Object.assign({}, root.editState.draft,
            {layouts: [{layout: root.choice, variant: ""}].concat(rest).slice(0, 4)});
        root.submitted = true;
        root.editState.apply();
    }
    KioskPickList {
        anchors.top: parent.top
        anchors.bottom: test.top
        anchors.bottomMargin: Kiosk.px(12)
        width: parent.width
        focus: true
        placeholder: I18n.tr("Search layouts")
        model: (root.service.snapshot.catalog || []).map(entry => ({value: entry.value, label: entry.label, detail: entry.value}))
        current: root.current
        selected: root.choice
        onChosen: value => root.choice = value
    }
    KioskField {
        id: test
        anchors.bottom: status.top
        anchors.bottomMargin: Kiosk.px(12)
        width: parent.width
        placeholder: I18n.tr("Type here to test your keyboard")
    }
    KioskText {
        id: status
        anchors.bottom: actions.top
        anchors.bottomMargin: visible ? Kiosk.px(12) : 0
        width: parent.width
        visible: text !== ""
        text: root.service.error || (root.service.busy ? I18n.tr("Applying…") : "")
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
            readonly property var entry: (root.service.snapshot.catalog || []).find(choice => choice.value === root.choice)
            text: I18n.format("Use %1", [entry ? entry.label : root.choice])
            enabled: root.service.loaded && !root.service.busy && root.choice !== "" && root.choice !== root.current
            onClicked: root.use()
        }
    }
}
