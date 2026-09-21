import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import "Common"

// Full-screen overlay hosting the launcher: a centred glass card that
// springs in over an undimmed desktop — the compositor blurs only the card
// itself — and any click outside it closes it.
PanelWindow {
    id: root

    // Kept mapped through the fade-out so the exit animation is visible.
    visible: Launcher.open || panel.opacity > 0.001
    screen: Launcher.screen
    anchors { top: true; left: true; right: true; bottom: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-launcher"
    // This is a keyboard-first modal surface. Exclusive focus asks the
    // compositor for the keyboard as soon as the window maps; the view also
    // has an early-key fallback below for the frame before its TextInput
    // becomes the active focus item.
    WlrLayershell.keyboardFocus: Launcher.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    HyprlandFocusGrab {
        active: Launcher.open
        windows: [root]
        onCleared: Launcher.close()
    }

    IpcHandler {
        target: "launcher"

        function toggle(): void {
            Launcher.toggle();
        }

        function close(): void {
            Launcher.close();
        }
    }

    MouseArea {
        anchors.fill: parent
        onPressed: Launcher.close()
    }

    FocusScope {
        id: stage
        anchors.fill: parent
        focus: Launcher.open

        Keys.onPressed: event => {
            if (Launcher.open && !launcherView.inputActiveFocus)
                event.accepted = launcherView.handleEarlyKey(event);
        }

        // The card's top edge stays put while the result list grows and
        // shrinks; it sits where the fully populated compact launcher would
        // centre (tabs, search tile and eight single-line rows).
        readonly property real anchorY: Math.max(24,
            Math.round((root.height - launcherView.fullHeight) / 2))

        ClippingRectangle {
            id: panel

            x: Math.round((root.width - width) / 2)
            y: stage.anchorY
            width: launcherView.implicitWidth
            height: launcherView.implicitHeight
            radius: Theme.popRadius
            color: Theme.panelSurface

            // These animations never gate input: the warm view and selected
            // first row are actionable before the first visible frame.
            opacity: Launcher.open ? 1 : 0
            scale: Launcher.open ? 1 : Theme.launcherInitialScale

            Behavior on opacity {
                NumberAnimation {
                    duration: Launcher.open ? Theme.launcherFadeInDuration : Theme.launcherFadeOutDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Launcher.open ? Theme.launcherEnterCurve : Theme.launcherExitCurve
                }
            }

            Behavior on scale {
                NumberAnimation {
                    duration: Launcher.open ? Theme.launcherOpenDuration : Theme.launcherCloseDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Launcher.open ? Theme.launcherEnterCurve : Theme.launcherExitCurve
                }
            }

            // Results arriving or leaving roll the card open or closed. No
            // spring here: an overshoot past the content shows bare glass.
            Behavior on height {
                enabled: Launcher.open
                NumberAnimation {
                    duration: Theme.launcherResizeDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.easeOutCurve
                }
            }

            transform: Translate {
                y: Launcher.open ? 0 : -Theme.launcherTravel

                Behavior on y {
                    NumberAnimation {
                        duration: Launcher.open ? Theme.launcherOpenDuration : Theme.launcherCloseDuration
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Launcher.open ? Theme.launcherEnterCurve : Theme.launcherExitCurve
                    }
                }
            }

            // Construct the launcher with the shell instead of on the first
            // shortcut press. App sorting and the first viewport of delegates
            // are therefore already warm when the compositor maps this window.
            LauncherView {
                id: launcherView
                width: implicitWidth
                height: implicitHeight
                availableWidth: Math.max(1, root.width - Theme.panelPadding * 2)
                availableHeight: Math.max(1, root.height - Theme.panelPadding * 2)
                drawBackground: false
                focus: Launcher.open
            }

            Rectangle {
                anchors.fill: parent
                radius: panel.radius
                color: "transparent"
                border.width: Theme.surfaceBorderWidth
                border.color: Theme.surfaceBorderColor
            }
        }
    }
}
