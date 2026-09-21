import QtQuick
import "../Common"

// [label 90][framed text input][undo 18] (design v2 value rows). Commits on
// Enter or focus loss; the caller normalizes and the display snaps back to
// whatever the store kept. Escape restores the stored value locally without
// reaching the panel's escape chain.
SettingsRow {
    id: root

    property string value: root.stored !== undefined ? String(root.stored) : ""
    property string placeholder: ""
    property bool numeric: false
    property bool secret: false
    signal committed(string text)

    onValueChanged: {
        if (!input.activeFocus)
            input.text = value;
    }

    Rectangle {
        id: frame
        x: root.narrow ? 0 : root.labelWidth
        y: root.narrow ? Theme.scaled(23) : (parent.height - height) / 2
        width: root.narrow ? parent.width - root.undoWidth - 2
            : root.contentRight - x - 2
        height: Theme.settingsControlHeight
        radius: Theme.chipRadius
        color: input.activeFocus ? Theme.hoverFillStrong : Theme.cardFill
        border.width: input.activeFocus ? 1 : 0
        border.color: Theme.accent

        TextInput {
            id: input
            anchors.left: parent.left
            anchors.leftMargin: 9
            anchors.right: parent.right
            anchors.rightMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            font.family: root.numeric ? Theme.fontMono : Theme.fontMenu
            font.pixelSize: Theme.fontCaption
            color: Theme.textHi
            selectionColor: Theme.accentBg
            selectedTextColor: Theme.textHi
            clip: true
            activeFocusOnTab: true
            echoMode: root.secret ? TextInput.Password : TextInput.Normal
            passwordCharacter: "•"
            inputMethodHints: root.numeric ? Qt.ImhFormattedNumbersOnly
                : root.secret ? Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                : Qt.ImhNone
            Accessible.role: Accessible.EditableText
            Accessible.name: root.label
            Component.onCompleted: text = root.value
            onEditingFinished: {
                if (text !== root.value) {
                    root.commit(text);
                    root.committed(text);
                }
                // The store may have normalized the commit into a different
                // value (or rejected it); reflect what actually stuck.
                Qt.callLater(() => text = root.value);
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    text = root.value;
                    focus = false;
                    event.accepted = true;
                }
            }

            Text {
                visible: input.text === ""
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: root.placeholder
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontCaption
                color: Theme.textFaint
                elide: Text.ElideRight
            }
        }

        MouseArea {
            anchors.fill: parent
            visible: !input.activeFocus
            cursorShape: Qt.IBeamCursor
            onClicked: input.forceActiveFocus()
        }
    }
}
