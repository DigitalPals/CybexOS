pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

// Material state overlay shared by shell controls. It is intentionally visual
// only: the owning control keeps its MouseArea, focus semantics, and press
// scale while this component makes hover/focus/pressed strength consistent.
Item {
    id: root

    property bool hovered: false
    property bool pressed: false
    property bool focused: false
    property color tint: Theme.textHi
    property real radius: 0
    property bool rippleEnabled: true
    property point pressPoint: Qt.point(width / 2, height / 2)
    readonly property Item rippleMaskItem: rippleMask

    function pulseAt(x, y) {
        if (!rippleEnabled || width <= 0 || height <= 0)
            return;
        const px = Math.max(0, Math.min(width, x));
        const py = Math.max(0, Math.min(height, y));
        const dx = Math.max(px, width - px);
        const dy = Math.max(py, height - py);
        ripple.centerX = px;
        ripple.centerY = py;
        ripple.targetDiameter = Math.sqrt(dx * dx + dy * dy) * 2;
        rippleAnimation.restart();
    }

    function pulseCenter() {
        pulseAt(width / 2, height / 2);
    }

    onPressedChanged: {
        if (pressed)
            pulseAt(pressPoint.x, pressPoint.y);
    }

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: root.tint
        opacity: root.pressed || root.focused ? Theme.statePressedOpacity
            : root.hovered ? Theme.stateHoverOpacity : 0

        Behavior on opacity {
            NumberAnimation { duration: Theme.chipFadeDuration / 2 }
        }
    }

    // The effect is enabled only for the lifetime of a pulse. MultiEffect is
    // already part of this shell's QtQuick stack; its rounded mask lets the
    // circle originate under the pointer without leaking through pill corners.
    Item {
        id: rippleLayer
        anchors.fill: parent
        visible: ripple.opacity > 0.001
        layer.enabled: visible
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: root.rippleMaskItem
        }

        Rectangle {
            id: ripple

            property real centerX: root.width / 2
            property real centerY: root.height / 2
            property real diameter: 0
            property real targetDiameter: 0

            x: centerX - diameter / 2
            y: centerY - diameter / 2
            width: diameter
            height: diameter
            radius: diameter / 2
            color: root.tint
            opacity: 0
        }
    }

    Rectangle {
        id: rippleMask
        anchors.fill: parent
        radius: root.radius
        color: "white"
        visible: false
        // Only the ripple samples this mask, so it holds an offscreen
        // texture for the pulse's lifetime rather than for every control's.
        // A pulse starts at zero diameter, so the frame the texture is built
        // in has nothing to show yet.
        layer.enabled: rippleLayer.visible
    }

    SequentialAnimation {
        id: rippleAnimation

        PropertyAction { target: ripple; property: "diameter"; value: 0 }
        PropertyAction { target: ripple; property: "opacity"; value: 0.16 }
        ParallelAnimation {
            NumberAnimation {
                target: ripple
                property: "diameter"
                to: ripple.targetDiameter
                duration: Theme.expandDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
            SequentialAnimation {
                PauseAnimation { duration: Theme.chipFadeDuration / 2 }
                NumberAnimation {
                    target: ripple
                    property: "opacity"
                    to: 0
                    duration: Theme.expandDuration - Theme.chipFadeDuration / 2
                    easing.type: Easing.OutCubic
                }
            }
        }
    }
}
