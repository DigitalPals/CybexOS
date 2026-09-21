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

        Rectangle {
            id: card

            anchors.centerIn: parent
            width: Math.min(680, root.width - 48)
            height: body.implicitHeight + 46
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

            Column {
                id: body
                x: 26
                y: 23
                width: parent.width - 52
                spacing: 18

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
                            color: Theme.accent
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 32 - hint.implicitWidth - parent.spacing * 2
                        text: "Keyboard shortcuts"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                    }

                    Text {
                        id: hint
                        anchors.verticalCenter: parent.verticalCenter
                        text: "hyprland.conf · press Esc to close"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.section
                        font.weight: Theme.weightBold
                        color: Theme.textFaint
                    }
                }

                Grid {
                    width: parent.width
                    columns: 2
                    columnSpacing: 30
                    rowSpacing: 20

                    Repeater {
                        model: Session.shortcutGroups

                        delegate: Column {
                            id: group

                            required property var modelData
                            required property int index

                            width: (parent.width - 30) / 2
                            spacing: 8
                            opacity: Session.keysOpen ? 1 : 0

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
                                color: Theme.accent
                            }

                            Column {
                                width: parent.width
                                spacing: 6

                                Repeater {
                                    model: group.modelData.rows

                                    delegate: Item {
                                        id: shortcut

                                        required property var modelData

                                        width: parent.width
                                        height: Math.max(21, label.implicitHeight)

                                        Text {
                                            id: label
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - keys.width - 10
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
                                                    height: 21
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
