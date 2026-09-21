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

    SettingsField {
        id: input
        x: root.narrow ? root.markInset : root.labelWidth
        y: root.narrow ? Theme.settingsStackOffset : (parent.height - height) / 2
        width: Math.max(0, root.contentRight - x - Theme.settingsRowSpacing)
        height: Theme.settingsControlHeight
        font.family: root.numeric ? Theme.fontMono : Theme.fontMenu
        placeholderText: root.placeholder
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
            // The store may normalize or reject the edit. Reflect what stuck.
            Qt.callLater(() => text = root.value);
        }
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                text = root.value;
                focus = false;
                event.accepted = true;
            }
        }
    }
}
