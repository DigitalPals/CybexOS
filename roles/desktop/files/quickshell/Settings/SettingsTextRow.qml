import QtQuick
import "../Common"

// [label][framed text input][undo] (design v2 value rows). Commits on Enter
// or focus loss; the caller normalizes and the display snaps back to
// whatever the store kept. Escape restores the stored value locally without
// reaching the panel's escape chain.
//
// A `hexColor` row validates as it is typed: a swatch previews the colour
// the text names, and text that names none outlines the field and says what
// is expected, instead of being silently dropped when focus leaves.
SettingsRow {
    id: root

    property string value: root.stored !== undefined ? String(root.stored) : ""
    property string placeholder: ""
    property bool numeric: false
    property bool secret: false
    property bool hexColor: false
    signal committed(string text)

    readonly property bool inputValid: !hexColor || /^#[0-9a-fA-F]{6}$/.test(input.text.trim())
    readonly property int swatchSize: hexColor ? Theme.settingsControlHeight - 8 : 0

    hint: hexColor && !inputValid && input.activeFocus
        ? "Enter a six-digit hex color, such as #9ecbeb" : ""
    hintTone: hexColor && !inputValid ? "error" : "info"

    onValueChanged: {
        if (!input.activeFocus)
            input.text = value;
    }

    Rectangle {
        visible: root.hexColor
        x: root.narrow ? root.markInset : root.labelWidth
        y: (root.narrow ? Theme.settingsStackOffset : (root.lineHeight - Theme.settingsControlHeight) / 2) + 4
        width: root.swatchSize
        height: root.swatchSize
        radius: Theme.scaled(4)
        opacity: root.controlOpacity
        color: root.inputValid ? input.text.trim() : "transparent"
        border.width: 1
        border.color: root.inputValid ? Theme.stroke : Theme.redText
        Accessible.ignored: true
    }

    SettingsField {
        id: input
        x: (root.narrow ? root.markInset : root.labelWidth)
            + (root.hexColor ? root.swatchSize + Theme.controlSpacing : 0)
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        width: Math.max(0, root.contentRight - x - Theme.settingsRowSpacing)
        height: Theme.settingsControlHeight
        opacity: root.controlOpacity
        font.family: root.numeric || root.hexColor ? Theme.fontMono : Theme.fontMenu
        placeholderText: root.placeholder
        echoMode: root.secret ? TextInput.Password : TextInput.Normal
        passwordCharacter: "•"
        inputMethodHints: root.numeric ? Qt.ImhFormattedNumbersOnly
            : root.secret ? Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
            : Qt.ImhNone
        invalid: !root.inputValid
        Accessible.role: Accessible.EditableText
        Accessible.name: root.label
        Accessible.description: root.hint
        Component.onCompleted: text = root.value
        onEditingFinished: {
            // An invalid colour never reaches the store; the field falls
            // back to the stored value below.
            if (text !== root.value && root.inputValid) {
                const next = root.hexColor ? text.trim().toLowerCase() : text;
                root.commit(next);
                root.committed(next);
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
