pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import "Common"
import "Common/CaptureHelpers.js" as CaptureHelpers

// The camera bubble of a `screen-record --webcam` recording: a round,
// mirrored preview in a corner of the recorded area, on the overlay layer so
// the recording itself includes it. shell.qml creates it only while
// Recorder.webcamWanted, so the camera is open exactly as long as the
// recording runs and is released when it stops.
//
// The window covers the recorded area but takes input only on the bubble;
// dragging the bubble moves it, and releasing it snaps it to the nearest
// corner. Without a usable camera nothing is shown, and the user is told once.
PanelWindow {
    id: root

    readonly property var region: CaptureHelpers.parseGeometry(Recorder.webcamGeometry)
    readonly property var placement: {
        const screens = Quickshell.screens.map(screen => ({
            x: screen.x, y: screen.y, width: screen.width, height: screen.height
        }));
        return CaptureHelpers.webcamPlacement(root.region, screens);
    }
    readonly property ShellScreen targetScreen: root.placement !== null
        ? Quickshell.screens[root.placement.screen] ?? null : null

    readonly property var cameraDevice: {
        const inputs = mediaDevices.videoInputs;
        const index = CaptureHelpers.pickCamera(inputs.map(input => ({
            description: input.description, isDefault: input.isDefault
        })));
        return index >= 0 ? inputs[index] : null;
    }
    property bool failed: false
    property bool told: false
    property bool formatChosen: false
    // The first placement is immediate; only a snap after dragging animates.
    property bool placed: false
    // The camera runs only while there is somewhere to show it.
    readonly property bool cameraWanted: root.formatChosen && root.cameraDevice !== null
        && root.placement !== null && !root.failed

    function tell(message: string): void {
        if (root.told)
            return;
        root.told = true;
        Quickshell.execDetached(["notify-send", "--app-name=Screen Recording",
            "Screen Recording", message]);
    }

    // Prefer a light format: the bubble is a few hundred pixels across.
    function chooseFormat(): void {
        root.formatChosen = false;
        if (root.cameraDevice === null)
            return;
        const formats = root.cameraDevice.videoFormats;
        const index = CaptureHelpers.pickCameraFormat(formats.map(format => ({
            width: format.resolution.width, height: format.resolution.height,
            maxFps: format.maxFrameRate
        })));
        if (index >= 0)
            camera.cameraFormat = formats[index];
        root.formatChosen = true;
    }

    function place(): void {
        if (root.placement === null)
            return;
        const position = CaptureHelpers.cornerPosition(Recorder.webcamCorner,
            root.placement.width, root.placement.height,
            root.placement.size, root.placement.margin);
        bubble.x = position.x;
        bubble.y = position.y;
        root.placed = true;
    }

    visible: root.targetScreen !== null && root.cameraDevice !== null && !root.failed
    screen: root.targetScreen
    anchors {
        top: true
        left: true
    }
    // PanelWindow.margins is a Quickshell group qmllint cannot resolve.
    // qmllint disable unqualified
    margins {
        top: root.placement !== null ? root.placement.y : 0
        left: root.placement !== null ? root.placement.x : 0
    }
    // qmllint enable unqualified
    implicitWidth: root.placement !== null ? root.placement.width : 1
    implicitHeight: root.placement !== null ? root.placement.height : 1
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-webcam"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Pointer input only on the bubble; the recorded area stays usable.
    mask: Region {
        item: bubble
    }

    onPlacementChanged: root.place()
    // After the camera's own device binding has followed.
    onCameraDeviceChanged: Qt.callLater(root.chooseFormat)
    Component.onCompleted: {
        root.place();
        Qt.callLater(root.chooseFormat);
    }

    // Device enumeration can settle shortly after start; judge "no camera"
    // once it has had the chance to.
    Timer {
        interval: 1500
        running: true
        onTriggered: {
            if (root.cameraDevice === null)
                root.tell("No camera found. Recording without the webcam.");
        }
    }

    MediaDevices {
        id: mediaDevices
    }

    CaptureSession {
        camera: Camera {
            id: camera

            // A null device cannot be assigned; the default stands in, and
            // cameraWanted keeps it closed.
            cameraDevice: root.cameraDevice !== null ? root.cameraDevice
                : mediaDevices.defaultVideoInput
            active: root.cameraWanted
            onErrorOccurred: {
                root.failed = true;
                root.tell("The camera could not be opened. Recording without the webcam.");
            }
        }
        videoOutput: preview
    }

    Item {
        id: bubble

        width: root.placement !== null ? root.placement.size : 0
        height: width

        Behavior on x {
            enabled: root.placed && !dragArea.drag.active && !Theme.reducedMotion
            NumberAnimation {
                duration: Theme.expandDuration
                easing.type: Easing.OutCubic
            }
        }
        Behavior on y {
            enabled: root.placed && !dragArea.drag.active && !Theme.reducedMotion
            NumberAnimation {
                duration: Theme.expandDuration
                easing.type: Easing.OutCubic
            }
        }

        // VideoOutput has no radius of its own; round it with the shell's
        // masking idiom (see Popovers/MediaPopover.qml).
        Item {
            anchors.fill: parent
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: bubbleMask
            }

            Rectangle {
                anchors.fill: parent
                color: Theme.panelSurface
            }

            VideoOutput {
                id: preview
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectCrop
                // Mirrored, as people expect to see themselves.
                transform: Scale {
                    origin.x: preview.width / 2
                    xScale: -1
                }
            }
        }

        Rectangle {
            id: bubbleMask
            anchors.fill: parent
            radius: width / 2
            color: "white"
            visible: false
            layer.enabled: true
        }

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: 2
            border.color: Qt.rgba(1, 1, 1, 0.35)
        }

        MouseArea {
            id: dragArea
            anchors.fill: parent
            cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            drag.target: bubble
            drag.minimumX: 0
            drag.minimumY: 0
            drag.maximumX: root.width - bubble.width
            drag.maximumY: root.height - bubble.height
            onReleased: {
                if (root.placement === null)
                    return;
                Recorder.webcamCorner = CaptureHelpers.nearestCorner(bubble.x, bubble.y,
                    root.placement.width, root.placement.height, root.placement.size);
                root.place();
            }
        }
    }
}
