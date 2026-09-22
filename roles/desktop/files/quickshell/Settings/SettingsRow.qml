import QtQuick
import "../Common"

// The skeleton every settings row shares: the modified-mark gutter on the
// left, the fixed label column beside it, and the reset column on the right
// that reveals itself on hover. A concrete row — SwitchRow, PickerRow,
// SliderRow, SettingsTextRow — declares only its control, laid out between
// `labelWidth` and `contentRight`.
//
// A changed row wears a 6px accent mark in its gutter and brightens its
// label (turn-3 settings design); the reset chip appears while the pointer
// is over the row or the chip itself holds keyboard focus, so the always-on
// undo column of the previous design is gone without losing keyboard access.
//
// `settingKey` names a key in Settings, and a row that sets one needs nothing
// else: `stored` reads the value, `dirty` compares it against the default,
// `commit()` writes it, and the reset chip restores it and announces itself as
// `resetLabel` — the row's own label unless the announcement has to be more
// specific than the label ("Duration" reads as nothing on its own; "Toast
// duration" reads as something).
//
// A row whose value does not live in Settings leaves `settingKey` empty and
// wires `dirty` and `onResetRequested` itself. That is every row in
// ModuleDetailView, which stores per-module options rather than settings.
//
// Every row shares one explanatory line, `hint`, drawn by SettingsHint under
// the control line: a switch's description, a picker's note, a live status.
// A row that cannot apply right now names why in `disabledReason`; the row
// then stops taking input, dims its control, and shows the reason in place
// of the hint, so a greyed-out control never has to be guessed at.
Item {
    id: root

    property string label
    property color labelColor: Theme.textMid
    property string settingKey: ""
    property string resetLabel: label
    property bool dirty: settingKey !== ""
        && Settings[settingKey] !== Settings.defaults[settingKey]
    // What the reset chip restores — the argument to Settings.resetKeys().
    // Usually just this row's key, but a mode picker whose companion values
    // only make sense under one mode restores them together.
    property var resetKeys: settingKey === "" ? [] : [settingKey]
    property string hint: ""
    // info | active | warning | error — see SettingsHint.
    property string hintTone: "info"
    property string disabledReason: ""
    readonly property bool unavailable: disabledReason !== ""
    // Subclasses fade their control, never the reason beside it.
    readonly property real controlOpacity: unavailable ? 0.45 : 1

    // Reflow metrics. Each row reserves a different slice of the narrow line
    // for its own control, and the switch row's label sits 2px lower because
    // its control is taller than the text beside it.
    property real narrowHeight: Theme.settingsStackOffset + Theme.settingsControlHeight
    property int narrowLabelY: 0
    property int narrowLabelInset: 100
    // Most rows use the theme's compact label column. A page can reserve more
    // room for a longer label without changing every settings page or losing
    // alignment between the rows in that page.
    property int minimumLabelWidth: 0

    signal resetRequested()

    readonly property bool narrow: width < Theme.settingsNarrowWidth
    readonly property int markInset: Theme.settingsMarkInset
    // Where a row's control starts: the mark gutter plus the label column.
    readonly property int labelWidth: markInset
        + (Theme.settingsLabelWidth >= root.minimumLabelWidth
            ? Theme.settingsLabelWidth : root.minimumLabelWidth)
    readonly property int undoWidth: Theme.chipHeight
    // The reset column is always reserved, so the chip appearing never shifts
    // the row's control. Controls stop here rather than at the row's edge.
    readonly property real contentRight: width - undoWidth
    readonly property real labelTextWidth: labelText.width
    readonly property real labelTextHeight: labelText.implicitHeight
    readonly property var stored: settingKey === "" ? undefined : Settings[settingKey]
    readonly property bool highlighted: settingKey !== ""
        && Settings.highlightKey === settingKey

    property real wideHeight: Theme.panelRowHeight
    // The control line. Controls centre on it rather than on the row, which
    // grows by the hint below.
    readonly property real lineHeight: narrow ? narrowHeight : wideHeight
    height: lineHeight + (hintLine.visible ? hintLine.height + Theme.scaled(2) : 0)
    enabled: !unavailable

    function commit(value) {
        if (root.settingKey !== "")
            Settings.set(root.settingKey, value);
    }

    function requestReset() {
        if (root.resetKeys.length > 0)
            Settings.resetKeys(root.resetKeys, root.resetLabel);
        root.resetRequested();
    }

    // Search landed here: a short accent wash over the whole row, so the eye
    // finds it before the highlight clears.
    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -6
        anchors.rightMargin: -6
        radius: Theme.rowRadius
        color: Theme.accentAlpha(0.12)
        opacity: root.highlighted ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.chipFadeDuration } }
    }

    HoverHandler {
        id: rowHover
    }

    Rectangle {
        anchors.left: parent.left
        y: root.narrow ? root.narrowLabelY + 5 : (root.lineHeight - height) / 2
        width: 6
        height: 6
        radius: 3
        color: Theme.accent
        visible: root.dirty
    }

    Text {
        id: labelText
        anchors.left: parent.left
        anchors.leftMargin: root.markInset
        y: root.narrow ? root.narrowLabelY : (root.lineHeight - height) / 2
        width: (root.narrow ? parent.width - root.narrowLabelInset
            : root.labelWidth) - root.markInset
        text: root.label
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
        color: root.unavailable ? Theme.textDim
            : root.dirty ? Theme.textHi : root.labelColor
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
    }

    SettingsHint {
        id: hintLine
        // Tucked under the control line: the hint belongs to this row, not
        // to the gap before the next one.
        y: root.lineHeight - Theme.scaled(2)
        width: root.contentRight
        text: root.unavailable ? root.disabledReason : root.hint
        tone: root.unavailable ? "info" : root.hintTone
    }

    Item {
        anchors.right: parent.right
        y: (root.lineHeight - height) / 2
        width: root.undoWidth
        height: root.undoWidth

        UndoChip {
            id: undoChip
            visible: root.dirty
            Accessible.name: "Reset " + root.resetLabel + " to default"
            // Revealed by the pointer or by keyboard focus; kept in the tab
            // order the whole time it is visible so it stays reachable.
            opacity: rowHover.hovered || activeFocus ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.chipFadeDuration } }
            onClicked: root.requestReset()
        }
    }
}
