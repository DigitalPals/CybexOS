pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"
import "../Common/WallhavenHelpers.js" as WallhavenHelpers

// Wallhaven's fixed colour palette as one compact control, framed like the
// SettingsSelect dropdowns beside it: it shows the chosen colour (or "Any
// colour") and opens a grid of the 29 swatches. The grid is one tab stop;
// the arrows move between swatches, Enter or Space picks, Escape closes.
// Twenty-nine swatches in a line wrapped into an orphaned second row at
// every width the picker supports; the grid fits them all.
Item {
    id: root

    property string current: ""
    signal picked(string value)

    // Sized for the longer label, so choosing a colour does not move the row.
    implicitWidth: Math.ceil(Math.max(anyLabel.advanceWidth, colourLabel.advanceWidth)) + Theme.scaled(14, Theme.typeScale)
        + Theme.controlSpacing * 2 + Theme.scaled(3) + Theme.settingsControlHeight
    implicitHeight: Theme.settingsControlHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.ComboBox
    Accessible.name: I18n.tr("Filter by colour")
    Accessible.description: label.text
    Accessible.onPressAction: open()
    Keys.onPressed: event => {
        if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space, Qt.Key_Down].includes(event.key)) {
            open();
            event.accepted = true;
        }
    }

    function open() {
        popup.open();
    }
    function choose(value) {
        popup.close();
        root.forceActiveFocus();
        if (value !== current)
            picked(value);
    }

    TextMetrics { id: anyLabel; text: I18n.tr("Any colour"); font: label.font }
    TextMetrics { id: colourLabel; text: I18n.tr("Colour"); font: label.font }
    Rectangle {
        anchors.fill: parent
        radius: Theme.chipRadius
        color: mouse.containsMouse || popup.visible ? Theme.hoverFillStrong : Theme.cardFill
        border.width: 1
        border.color: root.activeFocus ? Theme.accentText : Theme.stroke
    }
    Rectangle {
        id: chosen
        x: Theme.controlSpacing + Theme.scaled(3)
        anchors.verticalCenter: parent.verticalCenter
        width: Theme.scaled(14, Theme.typeScale)
        height: width
        radius: width / 2
        color: root.current ? "#" + root.current : "transparent"
        border.width: 1
        border.color: Theme.textMid
        // "Any colour": an empty ring with a slash.
        Rectangle {
            visible: root.current === ""
            anchors.centerIn: parent
            width: parent.width * 1.2
            height: 1
            rotation: -45
            color: Theme.textMid
        }
    }
    Text {
        id: label
        anchors.left: chosen.right
        anchors.leftMargin: Theme.controlSpacing
        anchors.right: chevron.left
        anchors.rightMargin: Theme.iconTextSpacing
        anchors.verticalCenter: parent.verticalCenter
        text: root.current ? I18n.tr("Colour") : I18n.tr("Any colour")
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Theme.textHi
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
    }
    Sym {
        id: chevron
        anchors.right: parent.right
        anchors.rightMargin: Theme.controlSpacing
        anchors.verticalCenter: parent.verticalCenter
        name: "expand_more"
        size: Theme.iconSmall
        color: Theme.textDim
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.forceActiveFocus(); root.open(); }
    }

    Controls.Popup {
        id: popup
        readonly property int columns: 6
        readonly property int swatch: Theme.scaled(26, Theme.typeScale)
        readonly property int gap: Theme.scaled(6)
        popupType: Controls.Popup.Item
        focus: true
        padding: Theme.scaled(10)
        y: root.height + 4
        x: Math.min(0, root.width - width)
        closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
        onOpened: grid.focusAt(Math.max(0, WallhavenHelpers.COLORS.indexOf(root.current) + 1))
        onClosed: if (!root.activeFocus) root.forceActiveFocus()
        background: Rectangle {
            color: Theme.popBg
            radius: Theme.chipRadius + 2
            border.width: 1
            border.color: Theme.stroke
        }
        contentItem: Grid {
            id: grid
            columns: popup.columns
            spacing: popup.gap
            // Index 0 is "Any colour", then the palette in Wallhaven's order.
            readonly property var values: [""].concat(WallhavenHelpers.COLORS)
            property int focusIndex: 0
            function focusAt(index) {
                focusIndex = Math.max(0, Math.min(values.length - 1, index));
                const item = cells.itemAt(focusIndex);
                if (item)
                    item.forceActiveFocus();
            }

            Repeater {
                id: cells
                model: grid.values
                delegate: Rectangle {
                    id: cell
                    required property string modelData
                    required property int index
                    readonly property bool selected: root.current === modelData
                    width: popup.swatch
                    height: popup.swatch
                    radius: Theme.scaled(6)
                    color: modelData ? "#" + modelData : "transparent"
                    border.width: activeFocus || selected ? 2 : 1
                    border.color: activeFocus ? Theme.accentText : selected ? Theme.textHi : Theme.stroke
                    activeFocusOnTab: index === grid.focusIndex
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: modelData ? I18n.format("Filter by colour %1", [modelData]) : I18n.tr("Any colour")
                    Accessible.checked: selected
                    Accessible.onPressAction: root.choose(modelData)
                    Keys.onPressed: event => {
                        const moves = { [Qt.Key_Left]: -1, [Qt.Key_Right]: 1, [Qt.Key_Up]: -popup.columns,
                            [Qt.Key_Down]: popup.columns, [Qt.Key_Home]: -index, [Qt.Key_End]: grid.values.length };
                        if (moves[event.key] !== undefined) {
                            grid.focusAt(index + moves[event.key]);
                            event.accepted = true;
                        } else if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
                            root.choose(modelData);
                            event.accepted = true;
                        }
                    }
                    Sym {
                        anchors.centerIn: parent
                        visible: cell.selected || cell.modelData === ""
                        name: cell.modelData === "" ? "close" : "check"
                        size: Theme.iconSmall
                        // Dark ink on the light swatches, light ink on the rest.
                        color: cell.modelData === "" ? Theme.textMid
                            : cell.color.r * 0.299 + cell.color.g * 0.587 + cell.color.b * 0.114 > 0.6 ? "#000000" : "#ffffff"
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.choose(cell.modelData)
                    }
                }
            }
        }
    }
}
