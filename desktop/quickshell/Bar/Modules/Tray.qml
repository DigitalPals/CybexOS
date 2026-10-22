pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Services.SystemTray
import ".."
import "../../Common"

// The system tray, collapsed to a chevron until it is wanted.
//
// Tray icons are the least designed pixels on any desktop — every application
// ships its own, at its own weight, in its own palette — so the redesign keeps
// them behind a disclosure rather than letting them set the tone of the bar.
// The strip slides out of zero width; nothing pops.
BarModule {
    id: root

    moduleId: "tray"

    // Session state, seeded from the module's setting. Deliberately not
    // written back on every toggle: this is a glance, not a preference, and
    // persisting it would rewrite settings.json on a chevron click.
    property bool expanded: Settings.modOpts.tray.expanded

    Rectangle {
        id: pill

        implicitWidth: layout.implicitWidth + 8
        implicitHeight: Theme.chipHeight
        radius: Theme.chipRadius
        color: "transparent"
        anchors.verticalCenter: parent.verticalCenter

        Behavior on color {
            ColorAnimation { duration: Theme.surfaceDuration }
        }

        Row {
            id: layout
            anchors.verticalCenter: parent.verticalCenter
            x: 4
            spacing: 0

            Item {
                id: chevron

                width: 24
                height: 24
                anchors.verticalCenter: parent.verticalCenter

                BarHover {
                    id: chevronHover
                    anchors.fill: parent
                    host: root.host
                    target: chevron
                    radius: Theme.chipRadius
                    pressed: chevronMouse.pressed
                    tint: Theme.barTextHi
                    pressPoint: Qt.point(chevronMouse.mouseX, chevronMouse.mouseY)
                }

                Sym {
                    anchors.centerIn: parent
                    name: "chevron_left"
                    size: Theme.iconMedium
                    symWeight: 600
                    color: chevronHover.over || root.expanded
                        ? Theme.barTextHi : Theme.barIcon
                    rotation: root.expanded ? 180 : 0

                    Behavior on rotation {
                        NumberAnimation {
                            duration: Theme.expandDuration
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Theme.springCurve
                        }
                    }
                }

                MouseArea {
                    id: chevronMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.expanded = !root.expanded
                }

                BarTooltip {
                    check: chevronHover.check
                    text: root.expanded ? "Hide tray"
                        : SystemTray.items.values.length
                            + (SystemTray.items.values.length === 1
                                ? " tray icon" : " tray icons")
                    y: 32
                    x: (24 - width) / 2
                }
            }

            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: root.expanded ? icons.implicitWidth : 0
                height: 26
                clip: true
                opacity: root.expanded ? 1 : 0
                // Hidden once collapsed so the icons behind the zero-width
                // clip stop answering the bar-wide hover check.
                visible: root.expanded || width > 0.5

                Behavior on width {
                    NumberAnimation {
                        duration: Theme.expandDuration + 50
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Theme.springCurve
                    }
                }

                Behavior on opacity {
                    NumberAnimation { duration: Theme.chipFadeDuration + 150 }
                }

                Row {
                    id: icons
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Repeater {
                        model: SystemTray.items

                        delegate: Rectangle {
                            id: trayItem

                            required property SystemTrayItem modelData

                            width: 26
                            height: 26
                            radius: Theme.chipRadius
                            color: "transparent"
                            scale: itemMouse.pressed ? 0.88 : 1

                            BarHover {
                                id: itemHover
                                anchors.fill: parent
                                host: root.host
                                target: trayItem
                                radius: trayItem.radius
                                pressed: itemMouse.pressed
                                tint: Theme.barTextHi
                                pressPoint: Qt.point(itemMouse.mouseX, itemMouse.mouseY)
                            }

                            Behavior on scale {
                                NumberAnimation {
                                    duration: Theme.pressDuration
                                    easing.type: Easing.BezierSpline
                                    easing.bezierCurve: Theme.springCurve
                                }
                            }

                            Image {
                                id: trayIcon
                                anchors.centerIn: parent
                                width: 15
                                height: 15
                                sourceSize: Qt.size(30, 30)
                                fillMode: Image.PreserveAspectFit
                                source: trayItem.modelData.icon
                                smooth: true
                                // The tint animates here rather than inside
                                // the effect so the offscreen layer can exist
                                // only while it is non-zero, as in BrandIcon.
                                property real tintAmount: itemHover.over ? 1 : 0
                                Behavior on tintAmount {
                                    NumberAnimation { duration: Theme.chipFadeDuration }
                                }
                                layer.enabled: tintAmount > 0.001
                                layer.effect: MultiEffect {
                                    colorization: trayIcon.tintAmount
                                    colorizationColor: Theme.barTextHi
                                }
                            }

                            QsMenuAnchor {
                                id: itemMenu
                                menu: trayItem.modelData.menu
                                anchor.item: trayItem
                                anchor.rect.y: trayItem.height + 8
                            }

                            MouseArea {
                                id: itemMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: mouse => {
                                    // An item that only offers a menu has
                                    // nothing to activate; opening the menu is
                                    // the primary action for it.
                                    if (mouse.button === Qt.RightButton
                                            || trayItem.modelData.onlyMenu) {
                                        if (trayItem.modelData.hasMenu)
                                            itemMenu.open();
                                        return;
                                    }
                                    if (mouse.button === Qt.MiddleButton) {
                                        trayItem.modelData.secondaryActivate();
                                        return;
                                    }
                                    trayItem.modelData.activate();
                                }
                                onWheel: wheel => {
                                    const delta = wheel.angleDelta.y !== 0
                                        ? wheel.angleDelta.y : wheel.angleDelta.x;
                                    if (delta !== 0)
                                        trayItem.modelData.scroll(delta, false);
                                    wheel.accepted = true;
                                }
                            }

                            BarTooltip {
                                check: itemHover.check
                                text: trayItem.modelData.tooltipTitle !== ""
                                    ? trayItem.modelData.tooltipTitle
                                    : trayItem.modelData.title
                                y: trayItem.height + 11
                                x: (trayItem.width - width) / 2
                            }
                        }
                    }
                }
            }
        }
    }
}
