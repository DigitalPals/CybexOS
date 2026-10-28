pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "Common"
import "Common/WindowCommands.js" as WindowCommands

// The Mac-like desktop style's minimize animation (Common/Minimizer.qml).
// While a window is on its way to the dock, a click-through overlay on its
// output holds one captured frame of it exactly over the window. Once the
// frame is there the window is minimized underneath, and the frame narrows
// and falls into the dock's minimized slot. A frame that cannot be captured
// in time minimizes without the animation.
//
// The title bar's minimize button reaches the shell through the `window`
// IPC target below, so its windows animate too.
Scope {
    id: root

    IpcHandler {
        target: "window"

        // Answers "ok" once the shell has taken the window; the title bar
        // falls back to the compositor's own minimize on anything else.
        function minimize(address: string): string {
            return Minimizer.minimize(address) ? "ok" : "refused";
        }
    }

    LazyLoader {
        active: Minimizer.flight !== null

        PanelWindow {
            id: overlay

            readonly property var flight: Minimizer.flight
            readonly property var toplevel: flight
                ? Hyprland.toplevels.values.find(toplevel =>
                    WindowCommands.bareAddress(toplevel.address) === flight.address) ?? null
                : null
            property bool started: false

            screen: flight ? flight.screen : null
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            mask: Region {}
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "qs-minimize"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            function start() {
                if (started || !flight)
                    return;
                started = true;
                Minimizer.captured();
                flightAnimation.start();
            }

            // A frame that never arrives must not strand the window.
            Timer {
                running: true
                interval: 400
                onTriggered: {
                    if (!overlay.started) {
                        overlay.started = true;
                        Minimizer.captured();
                        Minimizer.finished();
                    }
                }
            }

            Item {
                id: frame

                x: overlay.flight ? overlay.flight.from.x : 0
                y: overlay.flight ? overlay.flight.from.y : 0
                width: overlay.flight ? overlay.flight.from.width : 0
                height: overlay.flight ? overlay.flight.from.height : 0
                visible: capture.hasContent
                // Narrows toward its bottom edge as it falls, the outline of a
                // Mac's genie effect.
                property real squeeze: 1
                transform: Scale {
                    origin.x: frame.width / 2
                    origin.y: frame.height
                    xScale: frame.squeeze
                }

                ScreencopyView {
                    id: capture
                    anchors.fill: parent
                    captureSource: overlay.toplevel ? overlay.toplevel.wayland : null
                    live: false
                    paintCursor: false
                    onHasContentChanged: {
                        if (hasContent)
                            overlay.start();
                    }
                }
            }

            ParallelAnimation {
                id: flightAnimation

                readonly property int duration: Theme.expandDuration * 2

                NumberAnimation {
                    target: frame
                    property: "x"
                    to: overlay.flight ? overlay.flight.to.x : 0
                    duration: flightAnimation.duration
                    easing.type: Easing.InOutCubic
                }
                NumberAnimation {
                    target: frame
                    property: "y"
                    to: overlay.flight ? overlay.flight.to.y : 0
                    duration: flightAnimation.duration
                    easing.type: Easing.InCubic
                }
                NumberAnimation {
                    target: frame
                    property: "width"
                    to: overlay.flight ? overlay.flight.to.width : 0
                    duration: flightAnimation.duration
                    easing.type: Easing.InOutCubic
                }
                NumberAnimation {
                    target: frame
                    property: "height"
                    to: overlay.flight ? overlay.flight.to.height : 0
                    duration: flightAnimation.duration
                    easing.type: Easing.InOutCubic
                }
                SequentialAnimation {
                    NumberAnimation {
                        target: frame
                        property: "squeeze"
                        to: 0.55
                        duration: flightAnimation.duration / 2
                        easing.type: Easing.OutQuad
                    }
                    NumberAnimation {
                        target: frame
                        property: "squeeze"
                        to: 1
                        duration: flightAnimation.duration / 2
                        easing.type: Easing.InQuad
                    }
                }
                NumberAnimation {
                    target: frame
                    property: "opacity"
                    to: 0.4
                    duration: flightAnimation.duration
                    easing.type: Easing.InQuad
                }

                onFinished: Minimizer.finished()
            }
        }
    }
}
