pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "Common"
import "Common/KeybindHelpers.js" as KeybindHelpers

// The keyboard cheatsheet, from the Control Panel or Super+K.
//
// Its rows are Hyprland's live bindings: Common/Session.qml runs
// `hyprctl binds -j` each time the sheet opens, and Common/KeybindHelpers.js
// groups every binding that carries a "Group: Label" description. A
// cheatsheet that drifts from what the keys actually do is worse than none,
// so there is no hand-written list to drift.
//
// The sheet takes most of a wide screen: up to three columns, each holding
// whole groups in reading order, split so the columns end at about the same
// height (KeybindHelpers.columnsFor).
PanelWindow {
    id: root

    visible: Session.keysOpen || scrim.opacity > 0.01
    screen: Session.screen ?? Screens.focused
    anchors { top: true; left: true; right: true; bottom: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-shortcuts"
    WlrLayershell.keyboardFocus: Session.keysOpen
        ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    HyprlandFocusGrab {
        active: Session.keysOpen
        windows: [root]
        onCleared: Session.closeKeys()
    }

    Rectangle {
        id: scrim
        anchors.fill: parent
        color: Theme.scrim
        opacity: Session.keysOpen ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: Theme.panelFadeDuration + 80; easing.type: Easing.OutCubic }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: Session.closeKeys()
        }
    }

    FocusScope {
        anchors.fill: parent
        focus: Session.keysOpen

        Keys.onEscapePressed: Session.closeKeys()
        Keys.onPressed: event => {
            let next = scroll.contentY;
            if (event.key === Qt.Key_Down) next += Theme.listRowHeight;
            else if (event.key === Qt.Key_Up) next -= Theme.listRowHeight;
            else if (event.key === Qt.Key_PageDown) next += scroll.height;
            else if (event.key === Qt.Key_PageUp) next -= scroll.height;
            else if (event.key === Qt.Key_Home) next = 0;
            else if (event.key === Qt.Key_End) next = scroll.contentHeight;
            else return;
            scroll.contentY = Math.max(0, Math.min(next, scroll.contentHeight - scroll.height));
            event.accepted = true;
        }

        Rectangle {
            id: card

            anchors.centerIn: parent
            width: Math.min(Theme.scaled(1180), root.width - 96)
            height: Math.min(root.height - Theme.surfacePadding * 2, body.implicitHeight + Theme.surfacePadding * 2)
            radius: Theme.popRadius
            color: Theme.panelSurface
            border.width: 1
            border.color: Theme.stroke
            opacity: scrim.opacity
            scale: Session.keysOpen ? 1 : 0.96

            Behavior on scale {
                NumberAnimation {
                    duration: Theme.panelMotionDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.springCurve
                }
            }

            // anchors.centerIn owns x/y, so entry motion has to be a
            // transform. Animating y directly is silently overridden by the
            // anchor and leaves only the scale animation visible.
            transform: Translate {
                y: Session.keysOpen ? 0 : 16

                Behavior on y {
                    NumberAnimation {
                        duration: Theme.panelMotionDuration
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Theme.springCurve
                    }
                }
            }

            // Clicks inside the sheet must not reach the dismissing scrim.
            MouseArea {
                anchors.fill: parent
            }

            Flickable {
                id: scroll
                anchors.fill: parent
                anchors.margins: Theme.surfacePadding
                contentWidth: width
                contentHeight: body.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

            Column {
                id: body
                width: scroll.width - Theme.controlSpacing
                spacing: Theme.panelSectionSpacing

                Row {
                    width: parent.width
                    spacing: 10

                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Theme.iconLarge
                        height: Theme.iconLarge

                        Sym {
                            anchors.centerIn: parent
                            name: "keyboard"
                            size: Theme.iconLarge
                            color: Theme.accentText
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, parent.width - Theme.iconLarge - (hint.visible ? hint.width + parent.spacing : 0) - parent.spacing)
                        elide: Text.ElideRight
                        text: "Keyboard shortcuts"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                    }

                    Text {
                        id: hint
                        visible: body.width >= Theme.settingsNarrowWidth
                        width: Math.min(implicitWidth, body.width * 0.45)
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Live from Hyprland · press Esc to close"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.section
                        font.weight: Theme.weightBold
                        color: Theme.textFaint
                    }
                }

                Text {
                    id: sheetStatus
                    width: parent.width
                    visible: text !== ""
                    wrapMode: Text.Wrap
                    text: Session.shortcutsError !== ""
                        ? "Could not read the keybindings: " + Session.shortcutsError
                        : Session.shortcutGroups.length > 0 ? ""
                        : Session.shortcutsLoading ? "Reading keybindings…"
                        : "No keybindings have a description yet."
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    color: Session.shortcutsError !== "" ? Theme.redText : Theme.textMid
                }

                Row {
                    id: shortcutColumns

                    // Columns at least this wide keep a label and its keys on
                    // one line for all but the longest alternatives.
                    readonly property real minimumColumnWidth: Theme.scaled(330)
                    readonly property int count: Math.max(1, Math.min(3,
                        Math.floor((width + spacing) / (minimumColumnWidth + spacing))))
                    readonly property real columnWidth: (width - spacing * (count - 1)) / count

                    width: parent.width
                    spacing: Theme.panelSectionSpacing * 2

                    // A few hundred rows and key caps: build them while the
                    // sheet is on screen (including its fade-out) and release
                    // them once it is gone, rather than holding them for the
                    // shell's whole lifetime behind an unmapped surface.
                    Repeater {
                        model: root.visible
                            ? KeybindHelpers.columnsFor(Session.shortcutGroups, shortcutColumns.count) : []

                        delegate: Column {
                            id: column

                            required property var modelData

                            width: shortcutColumns.columnWidth
                            spacing: Theme.panelSectionSpacing

                            Repeater {
                                model: column.modelData

                                delegate: Column {
                                    id: group

                                    required property var modelData
                                    // Starts false and binds after construction so
                                    // the fade-in still runs for groups built on open.
                                    property bool shown: false

                                    width: column.width
                                    spacing: Theme.controlSpacing
                                    opacity: shown ? 1 : 0
                                    Component.onCompleted: shown = Qt.binding(() => Session.keysOpen)

                                    Behavior on opacity {
                                        NumberAnimation {
                                            duration: Theme.panelFadeDuration
                                            easing.type: Easing.OutCubic
                                        }
                                    }

                                    Text {
                                        text: group.modelData.title
                                        font.capitalization: Font.AllUppercase
                                        font.family: Theme.fontMenu
                                        font.pixelSize: Theme.typography.section
                                        font.weight: Theme.weightMedium
                                        font.letterSpacing: 1.2
                                        color: Theme.accentText
                                    }

                                    Column {
                                        id: rows

                                        width: parent.width
                                        spacing: Theme.iconTextSpacing

                                        Repeater {
                                            model: group.modelData.rows

                                            delegate: Item {
                                                id: shortcut

                                                required property var modelData
                                                // Keys that do not fit beside the label
                                                // move onto their own lines beneath it,
                                                // wrapping between alternatives.
                                                readonly property bool stacked: label.implicitWidth + keys.naturalWidth
                                                    + Theme.controlSpacing > width

                                                // Named, not `parent`: closing the sheet
                                                // clears the outer model, and each row is
                                                // unparented before its bindings go.
                                                width: rows.width
                                                height: stacked
                                                    ? label.implicitHeight + Theme.iconTextSpacing + keys.height
                                                    : Math.max(Theme.settingsControlHeight, label.implicitHeight)

                                                Text {
                                                    id: label
                                                    anchors.left: parent.left
                                                    y: shortcut.stacked ? 0 : (parent.height - implicitHeight) / 2
                                                    width: shortcut.stacked ? parent.width
                                                        : Math.max(0, parent.width - keys.width - Theme.controlSpacing)
                                                    text: shortcut.modelData.label
                                                    font.family: Theme.fontMenu
                                                    font.pixelSize: Theme.typography.primary
                                                    font.weight: Theme.weightSemibold
                                                    color: Theme.textMid
                                                    elide: Text.ElideRight
                                                }

                                                // Each combination is one key-cap row;
                                                // alternatives for the same action are
                                                // separated by "or". Beside the label the
                                                // keys sit on one line at the right edge;
                                                // stacked, they wrap under it instead of
                                                // running past the column's left edge.
                                                Flow {
                                                    id: keys

                                                    readonly property real naturalWidth: {
                                                        let total = 0;
                                                        let count = 0;
                                                        for (const child of children) {
                                                            if (child.implicitWidth > 0) {
                                                                total += child.implicitWidth;
                                                                count++;
                                                            }
                                                        }
                                                        return total + Math.max(0, count - 1) * spacing;
                                                    }

                                                    x: shortcut.stacked ? 0 : parent.width - width
                                                    y: shortcut.stacked ? label.implicitHeight + Theme.iconTextSpacing
                                                        : (parent.height - height) / 2
                                                    width: shortcut.stacked ? parent.width
                                                        : Math.min(parent.width, naturalWidth)
                                                    spacing: Theme.iconTextSpacing

                                                    Repeater {
                                                        model: shortcut.modelData.combos

                                                        delegate: Row {
                                                            id: combo

                                                            required property var modelData
                                                            required property int index

                                                            spacing: 4

                                                            Text {
                                                                visible: combo.index > 0
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                rightPadding: Theme.iconTextSpacing - combo.spacing
                                                                text: "or"
                                                                font.family: Theme.fontMenu
                                                                font.pixelSize: Theme.typography.secondary
                                                                color: Theme.textFaint
                                                            }

                                                            Repeater {
                                                                model: combo.modelData

                                                                delegate: Rectangle {
                                                                    id: cap

                                                                    required property string modelData

                                                                    width: capLabel.implicitWidth + 14
                                                                    height: Theme.settingsControlHeight
                                                                    radius: 6
                                                                    color: Theme.chip
                                                                    border.width: 1
                                                                    border.color: Theme.stroke

                                                                    Text {
                                                                        id: capLabel
                                                                        anchors.centerIn: parent
                                                                        text: cap.modelData
                                                                        font.family: Theme.fontMono
                                                                        font.pixelSize: Theme.typography.control
                                                                        font.weight: Theme.weightBold
                                                                        color: Theme.textHi
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    visible: Session.shortcutGroups.length > 0
                    wrapMode: Text.Wrap
                    text: "Bindings you add in ~/.config/cybexos/hypr/user.lua appear here when they have a description."
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textFaint
                }
            }
            }
            ScrollChrome { anchors.fill: scroll; target: scroll }
        }
    }
}
