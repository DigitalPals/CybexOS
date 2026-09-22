pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"
import "../Common/WidgetEditor.js" as Editor

Item {
    id: root
    required property var entries
    required property string sectionName
    property bool busy: false
    property string selectedKey: ""
    readonly property var available: Editor.search(entries, "", "available")
    readonly property var selected: available.find(entry => entry.key === selectedKey) || null
    readonly property real choiceHeight: Math.max(48, (Theme.typography.control + Theme.typography.secondary) * 1.3 + 16)
    signal addRequested(string key)
    height: Theme.settingsControlHeight
    function focusPicker() { chooser.forceActiveFocus(); }
    onAvailableChanged: { if (!selected) selectedKey = ""; }

    Controls.Button {
        id: chooser
        anchors.left: parent.left
        anchors.right: addAction.left
        anchors.rightMargin: 8
        height: root.height
        enabled: !root.busy && root.available.length > 0
        text: root.selected ? root.selected.name : root.available.length ? "Select a widget…" : "All widgets added"
        Accessible.name: "Select a widget for " + root.sectionName
        onClicked: picker.open()
        contentItem: Text {
            text: chooser.text
            font.family: Theme.fontUi
            font.pixelSize: Theme.typography.control
            color: chooser.enabled ? Theme.textHi : Theme.textDim
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            rightPadding: 24
        }
        background: Rectangle {
            radius: Theme.chipRadius
            color: chooser.hovered ? Theme.hoverFillStrong : Theme.popBg
            border.width: 1
            border.color: chooser.activeFocus ? Theme.accentText : Theme.stroke
        }
        Sym {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            name: "expand_more"
            size: Theme.iconSmall
            color: Theme.textMid
        }
    }
    SettingsAction {
        id: addAction
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Add widget to " + root.sectionName
        glyph: "add"
        compact: true
        color: Theme.chip
        enabled: !root.busy && root.selected !== null
        onTriggered: {
            const key = root.selectedKey;
            root.selectedKey = "";
            root.addRequested(key);
        }
    }
    Controls.Popup {
        id: picker
        parent: chooser
        x: chooser.width - width
        y: chooser.height + 6
        width: Math.min(Theme.scaled(360, Theme.typeScale), Controls.Overlay.overlay ? Controls.Overlay.overlay.width - 32 : 360)
        height: Math.min(360, Controls.Overlay.overlay ? Controls.Overlay.overlay.height - 32 : 360,
            pickerHeader.height + search.height + 44 + Math.max(1, choices.count) * root.choiceHeight)
        margins: 16
        padding: 12
        modal: false
        focus: true
        popupType: Controls.Popup.Item
        closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
        onOpened: { search.text = ""; search.forceActiveFocus(); }
        onClosed: chooser.forceActiveFocus()
        background: Rectangle {
            color: Theme.popBg
            radius: Theme.panelRadius
            border.width: 1
            border.color: Theme.stroke
        }
        contentItem: Column {
            spacing: 10
            Row {
                id: pickerHeader
                width: parent.width
                Text {
                    width: parent.width - closeAction.width
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Add to " + root.sectionName
                    font.family: Theme.fontUi
                    font.pixelSize: Theme.typography.primary
                    color: Theme.textHi
                }
                SettingsAction {
                    id: closeAction
                    text: "Close widget picker"
                    glyph: "close"
                    compact: true
                    onTriggered: picker.close()
                }
            }
            SettingsField {
                id: search
                width: parent.width
                placeholderText: "Search widgets"
                onTextChanged: choices.currentIndex = 0
                Keys.onDownPressed: { choices.forceActiveFocus(); choices.currentIndex = 0; }
                onAccepted: choices.choose(choices.currentIndex)
            }
            ListView {
                id: choices
                width: parent.width
                height: Math.max(0, picker.availableHeight - y)
                clip: true
                model: Editor.search(root.entries, search.text, "available")
                currentIndex: 0
                boundsBehavior: Flickable.StopAtBounds
                function choose(index) {
                    if (index < 0 || index >= count || root.busy) return;
                    root.selectedKey = model[index].key;
                    picker.close();
                }
                Keys.onReturnPressed: choose(currentIndex)
                Keys.onEnterPressed: choose(currentIndex)
                Keys.onSpacePressed: choose(currentIndex)
                delegate: Controls.ItemDelegate {
                    id: choice
                    required property var modelData
                    required property int index
                    width: choices.width
                    height: root.choiceHeight
                    highlighted: choices.currentIndex === index
                    enabled: !root.busy
                    Accessible.name: modelData.name
                    onClicked: choices.choose(index)
                    contentItem: Column {
                        id: labels
                        Text {
                            width: parent.width
                            text: choice.modelData.name
                            font.family: Theme.fontUi
                            font.pixelSize: Theme.typography.control
                            color: Theme.textHi
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            text: choice.modelData.plugin ? choice.modelData.origin : choice.modelData.description
                            font.family: Theme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            color: Theme.textDim
                            elide: Text.ElideRight
                        }
                    }
                    background: Rectangle {
                        radius: Theme.rowRadius
                        color: choice.highlighted || choice.hovered ? Theme.hoverFillStrong : "transparent"
                    }
                }
                Text {
                    width: parent.width
                    visible: choices.count === 0
                    text: "No widgets match your search."
                    font.family: Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textDim
                    wrapMode: Text.Wrap
                }
                Controls.ScrollBar.vertical: Controls.ScrollBar {}
            }
        }
    }
}
