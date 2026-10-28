pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// The views of a page that holds more than one (2026-10 redesign: Keyboard,
// Backup & storage). Underlined tabs switch what the page shows; a segmented
// control only ever changes a value, so the two never look alike. Left and
// Right move between tabs, as the rail's arrows move between pages.
Item {
    id: root

    property var tabs: []
    property string current: ""
    signal picked(string id)

    implicitHeight: Theme.scaled(38)
    Accessible.role: Accessible.PageTabList

    function step(delta) {
        const index = tabs.findIndex(entry => entry.id === current);
        const next = tabs[Math.max(0, Math.min(tabs.length - 1, index + delta))];
        if (!next || next.id === current)
            return;
        picked(next.id);
        Qt.callLater(() => {
            const item = tabRepeater.itemAt(tabs.indexOf(next));
            if (item)
                item.forceActiveFocus();
        });
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Theme.hairlineSoft
    }

    Row {
        id: tabRow
        x: Theme.settingsMarkInset
        height: parent.height
        spacing: Theme.scaled(22)

        Repeater {
            id: tabRepeater
            model: root.tabs

            delegate: Item {
                id: tab
                required property var modelData
                required property int index
                readonly property bool selected: modelData.id === root.current

                width: label.implicitWidth + 2
                height: tabRow.height
                activeFocusOnTab: selected
                Accessible.role: Accessible.PageTab
                Accessible.name: tab.modelData.label
                Accessible.selected: tab.selected
                Accessible.onPressAction: root.picked(tab.modelData.id)
                Keys.onPressed: event => {
                    // Alt+Left is Back, which the window handles.
                    if (event.modifiers & Qt.AltModifier) {
                        event.accepted = false;
                    } else if (event.key === Qt.Key_Left) {
                        root.step(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Right) {
                        root.step(1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        root.picked(tab.modelData.id);
                        event.accepted = true;
                    }
                }

                Text {
                    id: label
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: -1
                    text: tab.modelData.label
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.navigation
                    font.weight: tab.selected ? Theme.weightSemibold : Theme.weightMedium
                    color: tab.selected || tabMouse.containsMouse ? Theme.textHi : Theme.textLow
                }
                Rectangle {
                    visible: tab.selected || tab.activeFocus
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 2
                    radius: 1
                    color: tab.selected ? Theme.accent : Theme.accentText
                }
                MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        tab.forceActiveFocus();
                        root.picked(tab.modelData.id);
                    }
                }
            }
        }
    }
}
