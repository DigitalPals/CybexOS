pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/ThemeHelpers.js" as ThemeHelpers

// Appearance's themes as a gallery (2026-10 redesign): each one drawn in its
// own colors as a desktop in miniature — its base, a bar, a raised panel, two
// lines of text and the accent — rather than named in a dropdown. Picking one
// is the same single undoable change the dropdown made (Themes.apply). The
// last tile saves the current look as a theme of its own.
Item {
    id: root

    property var entries: Themes.entries
    property string current: Themes.current.value
    // { dark|light: { background, surface, raised, text, dim } }
    property var references: ({})
    signal saveRequested()

    readonly property int gap: Theme.scaled(10)
    readonly property int minimumTile: Theme.scaled(104, Theme.typeScale)
    readonly property int columns: Math.max(2, Math.floor((width + gap) / (minimumTile + gap)))
    readonly property real tileWidth: (width - gap * (columns - 1)) / columns
    readonly property real thumbHeight: Math.round(tileWidth * 0.56)
    readonly property real tileHeight: thumbHeight + Theme.scaled(6) + nameMetrics.height
    readonly property int count: entries.length + 1

    implicitHeight: Math.ceil(count / columns) * (tileHeight + gap) - gap + Theme.scaled(8)

    TextMetrics {
        id: nameMetrics
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        text: "Theme" // i18n: untranslated (a line-height sample, never drawn)
    }

    Repeater {
        model: root.entries

        delegate: Item {
            id: tile
            required property var modelData
            required property int index
            readonly property var colors: ThemeHelpers.preview(modelData, root.references)
                || ({ background: Theme.chip, surface: Theme.chip, raised: Theme.chip,
                      accent: Theme.accent, text: Theme.textHi, dim: Theme.textLow })
            readonly property bool selected: modelData.id === root.current

            x: (index % root.columns) * (root.tileWidth + root.gap)
            y: Theme.scaled(4) + Math.floor(index / root.columns) * (root.tileHeight + root.gap)
            width: root.tileWidth
            height: root.tileHeight
            activeFocusOnTab: true
            Accessible.role: Accessible.RadioButton
            Accessible.name: tile.modelData.name
            Accessible.checked: tile.selected
            Accessible.onPressAction: Themes.apply(tile.modelData.id)
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    Themes.apply(tile.modelData.id);
                    event.accepted = true;
                }
            }

            Rectangle {
                id: thumb
                width: parent.width
                height: root.thumbHeight
                radius: Theme.chipRadius + 1
                color: tile.colors.background
                clip: true

                // The bar along the top, with the accent as its one mark.
                Rectangle {
                    width: parent.width
                    height: Math.round(parent.height * 0.15)
                    color: tile.colors.surface
                    Rectangle {
                        x: parent.height * 0.6
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.height * 1.4
                        height: Math.max(2, parent.height * 0.32)
                        radius: height / 2
                        color: tile.colors.accent
                    }
                }
                // A panel: two lines of copy and an accent control.
                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: parent.width * 0.07
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: parent.height * 0.12
                    width: parent.width * 0.56
                    height: parent.height * 0.6
                    radius: Theme.scaled(4)
                    color: tile.colors.raised
                    Column {
                        x: parent.width * 0.12
                        y: parent.height * 0.18
                        width: parent.width * 0.76
                        spacing: Math.max(2, parent.height * 0.11)
                        Rectangle { width: parent.width * 0.85; height: Math.max(2, thumb.height * 0.05); radius: height / 2; color: tile.colors.text }
                        Rectangle { width: parent.width * 0.55; height: Math.max(2, thumb.height * 0.05); radius: height / 2; color: tile.colors.dim }
                        Rectangle { width: parent.width * 0.38; height: Math.max(3, thumb.height * 0.1); radius: height / 2; color: tile.colors.accent }
                    }
                }

                StateLayer {
                    anchors.fill: parent
                    radius: parent.radius
                    hovered: tileMouse.containsMouse
                    pressed: tileMouse.pressed
                    focused: tile.activeFocus
                    tint: Theme.textHi
                    pressPoint: Qt.point(tileMouse.mouseX, tileMouse.mouseY)
                }
            }

            // The ring sits outside the picture, so the theme's own edge
            // colors stay readable; a hairline gives pale themes an edge.
            Rectangle {
                anchors.fill: thumb
                anchors.margins: tile.selected ? -3 : 0
                radius: thumb.radius + (tile.selected ? 3 : 0)
                color: "transparent"
                border.width: tile.selected ? 2 : 1
                border.color: tile.selected ? Theme.accent : tile.activeFocus ? Theme.accentText : Theme.hairline
            }

            Rectangle {
                visible: tile.selected
                x: Theme.scaled(6)
                y: thumb.height - height - Theme.scaled(6)
                width: Theme.scaled(18)
                height: width
                radius: width / 2
                color: Theme.accent
                Sym {
                    anchors.centerIn: parent
                    name: "check"
                    size: Theme.scaled(12)
                    color: Theme.textOnAccent
                }
            }

            Text {
                y: thumb.height + Theme.scaled(6)
                width: parent.width
                text: tile.selected && Themes.current.modified
                    ? tile.modelData.name + " " + I18n.tr("(modified)") : tile.modelData.name
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: tile.selected ? Theme.weightSemibold : Theme.weightMedium
                color: tile.selected ? Theme.textHi : Theme.textLow
            }

            MouseArea {
                id: tileMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    tile.forceActiveFocus();
                    Themes.apply(tile.modelData.id);
                }
            }
        }
    }

    // "Save current…": a dashed outline rather than a picture, since there
    // is no theme to draw yet.
    Item {
        id: saveTile
        readonly property int index: root.entries.length
        x: (index % root.columns) * (root.tileWidth + root.gap)
        y: Theme.scaled(4) + Math.floor(index / root.columns) * (root.tileHeight + root.gap)
        width: root.tileWidth
        height: root.tileHeight
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: I18n.tr("Save current as theme…")
        Accessible.onPressAction: root.saveRequested()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                root.saveRequested();
                event.accepted = true;
            }
        }

        Canvas {
            id: dashes
            width: parent.width
            height: root.thumbHeight
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            readonly property color stroke: saveTile.activeFocus ? Theme.accentText : Theme.hairline
            onStrokeChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                ctx.strokeStyle = stroke;
                ctx.lineWidth = 1;
                ctx.setLineDash([4, 3]);
                const r = Theme.chipRadius + 1;
                ctx.beginPath();
                ctx.roundedRect(0.5, 0.5, width - 1, height - 1, r, r);
                ctx.stroke();
            }
            Sym {
                anchors.centerIn: parent
                name: "add"
                size: Theme.iconMedium
                color: saveMouse.containsMouse ? Theme.textHi : Theme.textFaint
            }
        }
        Text {
            y: dashes.height + Theme.scaled(6)
            width: parent.width
            text: I18n.tr("Save current…")
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightMedium
            color: Theme.textLow
        }
        MouseArea {
            id: saveMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.saveRequested()
        }
    }
}
