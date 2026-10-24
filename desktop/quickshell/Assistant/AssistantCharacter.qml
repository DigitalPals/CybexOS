pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import "../Common"

// The Cybex X on a charcoal disc. The status ring shows activity, while
// the animated character can gently follow focus without changing the mark.
//
// Moods (AssistantHelpers.mood): idle, attentive, listening, thinking,
// alert, happy, sorry, asleep.
Item {
    id: root

    property string mood: "idle"
    property bool mascot: true
    // 0..1, the microphone's level while listening.
    property real level: 0
    property bool hovered: false
    property bool unread: false
    // Which side the box is on, so an attentive look goes to it.
    property bool boxAbove: false
    // Where the eyes should look, in -1..1 of their travel, while idle.
    property real lookX: 0
    property real lookY: 0

    readonly property color charcoal: "#1A1B1E"
    readonly property color offWhite: "#F3F2EC"
    readonly property color accent: "#60A5FA"

    readonly property bool working: mood === "thinking"
    readonly property bool ringShown: hovered || mood === "attentive" || mood === "listening"
        || mood === "alert" || (mood === "happy" && !mascot)

    implicitWidth: Theme.scaled(64)
    implicitHeight: implicitWidth

    // ---- the ring ------------------------------------------------------------
    Rectangle {
        id: ring
        anchors.centerIn: parent
        width: parent.width + 8
        height: width
        radius: width / 2
        color: "transparent"
        border.width: 2
        border.color: root.mood === "alert" ? Theme.amber
            : root.mood === "listening" ? root.accent : Qt.rgba(0.376, 0.647, 0.980, 0.55)
        opacity: root.ringShown ? 1 : 0
        scale: root.mood === "listening" ? 1 + 0.22 * root.level : 1

        Behavior on opacity {
            NumberAnimation { duration: Theme.chipFadeDuration }
        }
        Behavior on scale {
            enabled: !Theme.reducedMotion
            NumberAnimation { duration: 80 }
        }
    }

    // The working arc runs around the disc while a turn is in progress.
    Shape {
        id: arc
        anchors.centerIn: parent
        width: parent.width + 10
        height: width
        opacity: root.working ? 1 : 0
        visible: opacity > 0
        preferredRendererType: Shape.CurveRenderer

        Behavior on opacity {
            NumberAnimation { duration: Theme.chipFadeDuration }
        }

        ShapePath {
            strokeColor: root.accent
            strokeWidth: 3
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                centerX: arc.width / 2
                centerY: arc.height / 2
                radiusX: arc.width / 2 - 2
                radiusY: radiusX
                startAngle: -90
                sweepAngle: 100
            }
        }

        RotationAnimator on rotation {
            running: root.working && !Theme.reducedMotion
            from: 0
            to: 360
            duration: 1100
            loops: Animation.Infinite
        }
    }

    // ---- the disc --------------------------------------------------------------
    Rectangle {
        id: disc
        anchors.fill: parent
        radius: width / 2
        color: root.charcoal
        border.width: 1
        border.color: Qt.rgba(0.953, 0.949, 0.925, root.hovered ? 0.28 : 0.14)

        Behavior on border.color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }
    }

    Image {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: root.mascot ? root.lookX * 2 : 0
        anchors.verticalCenterOffset: root.mascot
            ? (root.mood === "attentive" ? (root.boxAbove ? -2 : 2) : root.lookY * 2) : 0
        width: root.width * 0.78
        height: width
        source: BrandIcons.source("cybexos")
        fillMode: Image.PreserveAspectFit
        sourceSize.width: Math.ceil(width * 2)
        sourceSize.height: Math.ceil(height * 2)
        opacity: root.mood === "asleep" ? 0.55 : 1
        scale: root.mascot && root.mood === "listening" ? 1 + 0.1 * root.level : 1

        Behavior on anchors.horizontalCenterOffset {
            enabled: !Theme.reducedMotion
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
        Behavior on anchors.verticalCenterOffset {
            enabled: !Theme.reducedMotion
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
        Behavior on opacity {
            NumberAnimation { duration: Theme.chipFadeDuration }
        }
        Behavior on scale {
            enabled: !Theme.reducedMotion
            NumberAnimation { duration: 80 }
        }
    }

    // A reply finished while the box was tucked away or the character hidden.
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: -1
        width: Theme.scaled(13)
        height: width
        radius: width / 2
        color: root.mood === "alert" ? Theme.amber : root.accent
        border.width: 2
        border.color: root.charcoal
        visible: root.unread || root.mood === "alert"
    }

}
