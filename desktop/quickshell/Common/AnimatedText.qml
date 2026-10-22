import QtQuick

// Text whose value change is a small spatial transition rather than a snap.
// It remains a Text, so callers keep the ordinary font, alignment, elision,
// accessibility and layout surface instead of wrapping every label by hand.
Text {
    id: root

    property bool animateChange: true
    property real changeOffset: 4

    transform: Translate {
        id: shift
    }

    // Reduced motion snaps the value in rather than running the transition
    // at zero duration through the animation driver.
    Behavior on text {
        enabled: root.animateChange && !Theme.reducedMotion

        SequentialAnimation {
            alwaysRunToEnd: true

            ParallelAnimation {
                NumberAnimation {
                    target: root
                    property: "opacity"
                    to: 0
                    duration: Theme.chipFadeDuration / 2
                    easing.type: Easing.InCubic
                }
                NumberAnimation {
                    target: shift
                    property: "y"
                    to: -root.changeOffset
                    duration: Theme.chipFadeDuration / 2
                    easing.type: Easing.InCubic
                }
            }

            // In a Behavior, an empty PropertyAction commits the pending
            // value here, between the old label leaving and the new one entering.
            PropertyAction {}
            PropertyAction { target: shift; property: "y"; value: root.changeOffset }

            ParallelAnimation {
                NumberAnimation {
                    target: root
                    property: "opacity"
                    to: 1
                    duration: Theme.chipFadeDuration
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: shift
                    property: "y"
                    to: 0
                    duration: Theme.expandDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.springCurve
                }
            }
        }
    }
}
