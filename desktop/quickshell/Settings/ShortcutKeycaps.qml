pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/KeybindEditor.js" as Editor

// Key caps for canonical key strings ("SUPER + SHIFT + B"), drawn as the
// Super+K sheet draws them. Alternatives are separated by "or"; an empty
// list reads `emptyText`. Combinations in `lockedKeys` (a protected action's
// reserved defaults) are drawn dimmed with a lock: they cannot be removed.
Row {
    id: root

    property var keys: []
    property var lockedKeys: []
    property string emptyText: ""
    property bool large: false
    // Prepared cap labels, one array per combination, instead of `keys`.
    property var caps: null
    readonly property var combos: caps !== null ? caps
        : (keys || []).map(key => Editor.display(key)).filter(labels => labels.length > 0)
    readonly property var locked: caps !== null ? [] : (keys || []).filter(key => Editor.display(key).length > 0)
        .map(key => (lockedKeys || []).some(other => Editor.same(key, other)))

    spacing: Theme.iconTextSpacing
    Accessible.role: Accessible.StaticText
    Accessible.name: combos.length ? combos.map((labels, index) => root.locked[index]
        ? I18n.format("%1 (always kept)", [labels.join(" + ")]) : labels.join(" + ")).join(", ") : emptyText

    Text {
        visible: root.combos.length === 0 && root.emptyText !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: root.emptyText
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textFaint
    }

    Repeater {
        model: root.combos

        delegate: Row {
            id: combo
            required property var modelData
            required property int index
            spacing: Theme.scaled(3)

            Text {
                visible: combo.index > 0
                anchors.verticalCenter: parent.verticalCenter
                rightPadding: Theme.scaled(3)
                text: I18n.tr("or")
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
            }

            Repeater {
                model: combo.modelData

                delegate: Rectangle {
                    id: cap
                    required property string modelData
                    readonly property bool locked: !!root.locked[combo.index]
                    width: Math.max(height * 0.8, capLabel.implicitWidth + Theme.scaled(root.large ? 20 : 12))
                    height: root.large ? Theme.settingsControlHeight + Theme.scaled(14) : Theme.chipInnerHeight
                    radius: Theme.scaled(5)
                    color: locked ? "transparent" : Theme.chip
                    border.width: 1
                    border.color: Theme.stroke

                    Text {
                        id: capLabel
                        anchors.centerIn: parent
                        text: cap.modelData
                        font.family: Theme.fontMono
                        font.pixelSize: root.large ? Theme.typography.title : Theme.typography.secondary
                        font.weight: Theme.weightBold
                        color: cap.locked ? Theme.textMid : Theme.textHi
                    }
                }
            }
            Sym {
                visible: !!root.locked[combo.index]
                anchors.verticalCenter: parent.verticalCenter
                name: "lock"
                size: Theme.iconSmall
                color: Theme.textFaint
            }
        }
    }
}
