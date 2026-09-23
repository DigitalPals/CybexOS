import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import "Common"

// The launcher: a centred glass card that springs in over an undimmed
// desktop, and any click outside it closes it.
//
// The layer surface is the card's full-height envelope plus its entry travel,
// not the whole output. The compositor blurs every pixel of a blurred layer
// surface, transparent or not, so a full-output overlay paid for ~8 MP of
// blur on a 4K output — every open frame, keystroke and cursor blink — to
// show a ~460 px card. Clicks outside the surface reach whatever is under
// them and clear the focus grab, which closes the launcher.
PanelWindow {
    id: root

    // Kept mapped through the fade-out so the exit animation is visible.
    visible: Launcher.open || panel.opacity > 0.001
    onVisibleChanged: {
        if (!visible)
            launcherView.resetForClose();
    }
    screen: Launcher.screen
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    // Logical output size. The card's envelope derives from it, never from
    // the window's own size, which is now derived from the card.
    readonly property real outputWidth: root.screen ? root.screen.width : 0
    readonly property real outputHeight: root.screen ? root.screen.height : 0
    readonly property int travel: Theme.launcherTravel
    // The card's top edge stays put while the result list grows and
    // shrinks; it sits where the fully populated compact launcher would
    // centre (tabs, search tile and eight single-line rows).
    readonly property real cardTop: Math.max(24,
        Math.round((root.outputHeight - launcherView.fullHeight) / 2))

    // Placed from the output's top-left corner rather than centred by the
    // compositor, so the card lands exactly where the full-output overlay
    // drew it. With ExclusionMode.Ignore the margins count from the output's
    // edges, not from the bar's reserved zone. None of this follows the
    // card's animating height, so the surface never reconfigures while
    // mapped.
    anchors {
        top: true
        left: true
    }
    // PanelWindow.margins is a Quickshell group qmllint cannot resolve.
    // qmllint disable unqualified
    margins {
        top: root.cardTop - root.travel
        left: Math.round((root.outputWidth - launcherView.implicitWidth) / 2)
    }
    // qmllint enable unqualified
    implicitWidth: launcherView.implicitWidth
    implicitHeight: root.travel + launcherView.fullHeight

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

    // The travel strip above the card, and the card's own gaps, still close
    // on a press; everything beyond the surface is the focus grab's.
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

        ClippingRectangle {
            id: panel

            // The entry travel slides the card down into place from `-travel`,
            // which is what the strip above it is reserved for.
            x: 0
            y: root.travel
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
                // From the output, not the window: the window is sized from
                // this view, so reading it back here would shrink the card by
                // the padding on every pass.
                availableWidth: root.outputWidth > 0
                    ? Math.max(1, root.outputWidth - Theme.panelPadding * 2) : 0
                availableHeight: root.outputHeight > 0
                    ? Math.max(1, root.outputHeight - Theme.panelPadding * 2) : 0
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
