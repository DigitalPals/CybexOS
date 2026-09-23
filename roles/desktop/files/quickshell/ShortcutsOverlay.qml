pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "Common"

// The keyboard cheatsheet, from the Control Panel or Super+K.
//
// The bindings themselves live in Common/Session.qml, next to the actions they
// document — a cheatsheet that drifts from what the keys actually do is worse
// than none, and keeping the list beside the shell's own handlers is the
// closest this can get to them being the same thing.
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
            width: Math.min(680, root.width - 48)
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
                        text: "hyprland.conf · press Esc to close"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.section
                        font.weight: Theme.weightBold
                        color: Theme.textFaint
                    }
                }

                Grid {
                    id: shortcutGrid
                    width: parent.width
                    columns: width < Theme.settingsNarrowWidth ? 1 : 2
                    columnSpacing: Theme.panelSectionSpacing
                    rowSpacing: Theme.panelSectionSpacing

                    // A few hundred rows and key caps: build them while the
                    // sheet is on screen (including its fade-out) and release
                    // them once it is gone, rather than holding them for the
                    // shell's whole lifetime behind an unmapped surface.
                    Repeater {
                        model: root.visible ? Session.shortcutGroups : []

                        delegate: Column {
                            id: group

                            required property var modelData
                            required property int index
                            // Starts false and binds after construction so
                            // the fade-in still runs for groups built on open.
                            property bool shown: false

                            width: (shortcutGrid.width - shortcutGrid.columnSpacing * (shortcutGrid.columns - 1)) / shortcutGrid.columns
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
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.section
                                font.weight: Theme.weightMedium
                                font.letterSpacing: 1.2
                                color: Theme.accentText
                            }

                            Column {
                                width: parent.width
                                spacing: Theme.iconTextSpacing

                                Repeater {
                                    model: group.modelData.rows

                                    delegate: Item {
                                        id: shortcut

                                        required property var modelData

                                        width: parent.width
                                        height: Math.max(Theme.settingsControlHeight, label.implicitHeight)

                                        Text {
                                            id: label
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Math.max(0, parent.width - keys.width - Theme.controlSpacing)
                                            text: shortcut.modelData.label
                                            font.family: Theme.fontMenu
                                            font.pixelSize: Theme.typography.primary
                                            font.weight: Theme.weightSemibold
                                            color: Theme.textMid
                                            elide: Text.ElideRight
                                        }

                                        Row {
                                            id: keys
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 4

                                            Repeater {
                                                model: shortcut.modelData.keys

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
            ScrollChrome { anchors.fill: scroll; target: scroll }
        }
    }
}
