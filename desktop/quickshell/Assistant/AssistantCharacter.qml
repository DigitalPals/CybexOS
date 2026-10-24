pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import "../Common"

// The assistant itself: the NerdOS glasses on a charcoal disc. As the mascot
// (Settings → Assistant → Character) a pair of eyes sits behind the lenses
// and shows what it is doing; as the mark the logo is drawn unchanged and
// only the ring around the disc speaks. The glasses come from the master
// symbol's own geometry (assets/brand/symbol/svg/nerdos-symbol-on-dark.svg)
// in the brand colours, which belong to the identity rather than the theme.
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
    readonly property color lime: "#C8FF1F"

    readonly property string framesPath: "M277.98 69.28 300.08 31C303.63 24.85 301.98 17.12 296.5 12.91C303.09 8.11 311.22 5.28 320 5.28H444C457.96 5.28 470.26 12.43 477.41 23.28H493C499.08 23.28 504 28.2 504 34.28V48.28C504 54.35 499.08 59.28 493 59.28H484V93.28C484 128.62 455.35 157.28 420 157.28H344C308.65 157.28 280 128.62 280 93.28V69.28H277.98ZM60 5.28H184C199.62 5.28 213.14 14.23 219.73 27.28H226.02L203.92 65.55C200.06 72.25 202.35 80.81 209.05 84.68L224 93.31C223.98 128.64 195.34 157.28 160 157.28H84C48.65 157.28 20 128.62 20 93.28V59.28H11C4.92 59.28 0 54.35 0 48.28V34.28C0 28.2 4.92 23.28 11 23.28H26.59C33.74 12.43 46.04 5.28 60 5.28ZM336 45.28C327.16 45.28 320 52.44 320 61.28V81.28C320 101.16 336.12 117.28 356 117.28H408C427.88 117.28 444 101.16 444 81.28V61.28C444 52.44 436.84 45.28 428 45.28ZM76 45.28C67.16 45.28 60 52.44 60 61.28V81.28C60 101.16 76.12 117.28 96 117.28H148C167.88 117.28 184 101.16 184 81.28V61.28C184 52.44 176.84 45.28 168 45.28Z"
    readonly property string tapePath: "M257.55 0.67 290.45 19.67C292.85 21.05 293.67 24.11 292.28 26.5L253.28 94.05C251.9 96.44 248.85 97.26 246.45 95.88L213.55 76.88C211.15 75.5 210.33 72.44 211.72 70.05L250.72 2.5C252.1 0.11 255.15 -0.71 257.55 0.67Z"

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
            : root.mood === "listening" ? root.lime : Qt.rgba(0.784, 1, 0.122, 0.55)
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
            strokeColor: root.lime
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

    // The glasses, in the symbol's own 504 × 157.28 units.
    Item {
        id: glasses
        readonly property real unit: width / 504
        anchors.centerIn: parent
        anchors.verticalCenterOffset: root.mascot ? -1 : 0
        width: root.width * 0.82
        height: width * 157.28 / 504
        opacity: root.mood === "asleep" ? 0.55 : 1

        Behavior on opacity {
            NumberAnimation { duration: Theme.chipFadeDuration }
        }

        // Eyes go behind the frames, so the lens openings crop them.
        Repeater {
            model: root.mascot ? [122, 382] : []

            delegate: Item {
                id: eye
                required property int modelData
                readonly property real u: glasses.unit
                // Travel inside the lens opening (124 × 72 units), in symbol
                // units; the eye is 30 × 44, so a gap of dark lens always
                // shows around it at the small sizes the character is drawn.
                readonly property real dx: root.mood === "thinking" ? scanX
                    : root.mood === "attentive" ? 0
                    : root.mood === "listening" ? 0 : root.lookX * 34
                readonly property real dy: root.mood === "attentive" ? (root.boxAbove ? -10 : 10)
                    : root.mood === "listening" ? -9
                    : root.mood === "sorry" ? 10 : root.lookY * 9
                property real scanX: 0

                x: (modelData - 15 + dx) * u
                y: (81 - 22 + dy) * u
                width: 30 * u
                height: 44 * u

                Behavior on x {
                    enabled: !Theme.reducedMotion
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }
                Behavior on y {
                    enabled: !Theme.reducedMotion
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }

                SequentialAnimation on scanX {
                    running: root.mood === "thinking" && !Theme.reducedMotion
                    loops: Animation.Infinite
                    NumberAnimation { to: 34; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { to: -34; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0; duration: 500; easing.type: Easing.InOutSine }
                }

                // Open eyes: a soft upright pill that blinks.
                Rectangle {
                    id: open
                    anchors.centerIn: parent
                    width: parent.width * (root.mood === "alert" || root.mood === "listening" ? 1.12 : 1)
                    height: parent.height * blink.amount
                        * (root.mood === "sorry" ? 0.55 : root.mood === "alert" ? 1.1 : 1)
                    radius: width / 2
                    color: root.offWhite
                    visible: root.mood !== "happy" && root.mood !== "asleep"
                }

                // Happy and asleep: a stroke instead of an eye.
                Shape {
                    anchors.fill: parent
                    visible: root.mood === "happy" || root.mood === "asleep"
                    preferredRendererType: Shape.CurveRenderer

                    ShapePath {
                        strokeColor: root.offWhite
                        strokeWidth: Math.max(1.5, 9 * eye.u)
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        startX: 0
                        startY: root.mood === "happy" ? eye.height * 0.62 : eye.height * 0.55

                        PathQuad {
                            x: eye.width
                            y: root.mood === "happy" ? eye.height * 0.62 : eye.height * 0.55
                            controlX: eye.width / 2
                            controlY: root.mood === "happy" ? eye.height * 0.1 : eye.height * 0.6
                        }
                    }
                }
            }
        }

        Shape {
            width: 504
            height: 157.28
            scale: glasses.unit
            transformOrigin: Item.TopLeft
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                fillColor: root.offWhite
                strokeColor: "transparent"
                strokeWidth: 0
                fillRule: ShapePath.OddEvenFill
                PathSvg { path: root.framesPath }
            }

            ShapePath {
                fillColor: root.lime
                strokeColor: "transparent"
                strokeWidth: 0
                PathSvg { path: root.tapePath }
            }
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
        color: root.mood === "alert" ? Theme.amber : root.lime
        border.width: 2
        border.color: root.charcoal
        visible: root.unread || root.mood === "alert"
    }

    // Blinks every few seconds; never while a stroke stands in for the eyes.
    QtObject {
        id: blink
        property real amount: 1
    }

    SequentialAnimation {
        id: blinkOnce
        NumberAnimation { target: blink; property: "amount"; to: 0.12; duration: 70 }
        NumberAnimation { target: blink; property: "amount"; to: 1; duration: 110 }
    }

    Timer {
        interval: 3200 + Math.round(Math.random() * 2600)
        repeat: true
        running: root.mascot && root.visible && !Theme.reducedMotion
            && ["idle", "attentive", "thinking", "listening"].indexOf(root.mood) !== -1
        onTriggered: {
            blinkOnce.restart();
            interval = 3200 + Math.round(Math.random() * 2600);
        }
    }
}
