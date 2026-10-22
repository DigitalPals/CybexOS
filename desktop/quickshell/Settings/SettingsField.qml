import QtQuick
import QtQuick.Controls as Controls
import "../Common"

// Native text field chrome shared by setting rows and standalone forms.
// Qt owns selection, editing and accessibility; the shell owns its appearance.
Controls.TextField {
    id: root
    // Outlines the field in the error ink; the owner explains why.
    property bool invalid: false
    implicitHeight: Theme.settingsControlHeight
    leftPadding: Theme.controlSpacing
    rightPadding: Theme.controlSpacing
    topPadding: Theme.settingsRowSpacing
    bottomPadding: Theme.settingsRowSpacing
    font.family: Theme.fontMenu
    font.pixelSize: Theme.typography.control
    color: Theme.textHi
    placeholderTextColor: Theme.textFaint
    selectionColor: Theme.accentBg
    selectedTextColor: Theme.textHi
    Accessible.role: Accessible.EditableText
    Accessible.name: placeholderText
    activeFocusOnTab: enabled && visible
    hoverEnabled: true
    clip: true
    background: Rectangle {
        radius: Theme.chipRadius
        color: root.activeFocus ? Theme.hoverFillStrong : Theme.cardFill
        border.width: root.invalid || root.activeFocus || Settings.highContrast ? 1 : 0
        border.color: root.invalid ? Theme.redText
            : root.activeFocus ? Theme.accentText : Theme.stroke
        Behavior on color { ColorAnimation { duration: Theme.chipFadeDuration } }
    }
}
