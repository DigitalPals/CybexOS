import QtQuick
import "../Common"

// [label][framed text input][undo gutter] for a page that drafts its values
// and applies them together (Network). SettingsTextRow commits a shell
// setting on Enter or focus loss; a draft instead needs every keystroke, so
// the Apply bar appears while the address is still being typed rather than
// only after focus leaves the field.
//
// The value is the draft's, not a shell setting, so the row has no default
// to return to and never wears the modified mark. `invalid` outlines the
// field; the row's hint says why.
SettingsRow {
    id: root

    property string value: ""
    property string placeholder: ""
    property bool mono: true
    property bool invalid: false
    property int fieldWidth: Theme.scaled(280, Theme.typeScale)
    signal edited(string text)

    readonly property real fieldLeft: root.narrow ? root.markInset
        : Math.max(root.labelWidth, root.contentRight - Theme.settingsRowSpacing - root.fieldWidth)

    dirty: false
    resetKeys: []
    hintTone: invalid ? "error" : "info"
    narrowHeight: Theme.settingsStackOffset + Theme.settingsControlHeight
    controlLeft: fieldLeft

    SettingsField {
        x: root.fieldLeft
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        width: Math.max(0, root.contentRight - x - Theme.settingsRowSpacing)
        height: Theme.settingsControlHeight
        opacity: root.controlOpacity
        font.family: root.mono ? Theme.fontMono : Theme.fontMenu
        text: root.value
        placeholderText: root.placeholder
        invalid: root.invalid
        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
        Accessible.role: Accessible.EditableText
        Accessible.name: root.label
        Accessible.description: root.hint
        onTextEdited: root.edited(text)
    }
}
