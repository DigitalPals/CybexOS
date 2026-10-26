pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Settings/InputDraft.js" as Draft

// The installer sheets' searchable list: a search field over 54 px rows. The
// row in use carries a tick; the chosen row is tinted with an accent edge.
// Up and Down move from the field into the list; Return chooses.
FocusScope {
    id: root
    // [{ value, label, detail? }]
    property var model: []
    property string current: ""
    property string selected: current
    property string placeholder: ""
    readonly property var rows: Draft.filtered(model, field.text.trim(), selected)
    signal chosen(string value)
    function focusSearch() { field.forceActiveFocus(); }
    KioskField {
        id: field
        width: parent.width
        designHeight: 46
        fontSize: 16
        icon: "search"
        placeholder: root.placeholder
        focus: true
        Keys.onDownPressed: event => { if (list.count > 0) { list.currentIndex = 0; list.forceActiveFocus(); } event.accepted = true; }
        onAccepted: { if (list.count > 0) root.chosen(root.rows[0].value); }
    }
    ListView {
        id: list
        anchors.top: field.bottom
        anchors.topMargin: Kiosk.px(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: -Kiosk.px(8)
        anchors.rightMargin: -Kiosk.px(8)
        anchors.bottom: parent.bottom
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        spacing: Kiosk.px(2)
        model: ScriptModel { values: root.rows }
        keyNavigationEnabled: true
        activeFocusOnTab: count > 0
        highlightFollowsCurrentItem: false
        Keys.onUpPressed: event => {
            if (currentIndex <= 0) field.forceActiveFocus();
            else decrementCurrentIndex();
            event.accepted = true;
        }
        Keys.onReturnPressed: event => { if (currentItem) root.chosen(root.rows[currentIndex].value); event.accepted = true; }
        Keys.onEnterPressed: event => { if (currentItem) root.chosen(root.rows[currentIndex].value); event.accepted = true; }
        delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool chosen: root.selected === modelData.value
            readonly property bool focused: list.activeFocus && list.currentIndex === index
            x: Kiosk.px(8)
            width: list.width - Kiosk.px(16)
            height: Kiosk.px(54)
            radius: Kiosk.px(12)
            color: chosen ? Kiosk.accentSoft : rowMouse.containsMouse || focused ? Kiosk.card2 : "transparent"
            border.width: chosen || focused ? Math.max(1, Kiosk.px(1)) : 0
            border.color: focused ? Kiosk.accent : Kiosk.accentLine
            Accessible.role: Accessible.ListItem
            Accessible.name: modelData.label
            Accessible.selected: chosen
            Accessible.onPressAction: root.chosen(modelData.value)
            Column {
                anchors.left: parent.left
                anchors.leftMargin: Kiosk.px(14)
                anchors.right: tick.left
                anchors.rightMargin: Kiosk.px(10)
                anchors.verticalCenter: parent.verticalCenter
                KioskText {
                    width: parent.width
                    text: row.modelData.label
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                KioskText {
                    width: parent.width
                    visible: !!row.modelData.detail
                    text: row.modelData.detail || ""
                    mono: true
                    size: 12.5
                    tone: "faint"
                    elide: Text.ElideRight
                }
            }
            KioskIcon {
                id: tick
                anchors.right: parent.right
                anchors.rightMargin: Kiosk.px(14)
                anchors.verticalCenter: parent.verticalCenter
                visible: root.current === row.modelData.value
                name: "check"
                color: Kiosk.accent
            }
            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { list.currentIndex = row.index; root.chosen(row.modelData.value); }
            }
        }
    }
}
