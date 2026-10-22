import QtQuick

// One-child size-and-opacity revealer. The child stays alive through the exit
// animation, so conditional content does not disappear a frame before the
// surrounding card has finished closing around it.
Item {
    id: root

    default property alias content: contentRoot.data
    property bool reveal: false
    property int orientation: Qt.Vertical

    readonly property real naturalWidth: contentRoot.childrenRect.width
    readonly property real naturalHeight: contentRoot.childrenRect.height
    // Lets a container avoid putting a second width animation around this
    // one. Two nested spring curves chase different intermediate widths and
    // make pinned content visibly rebound even though both endpoints agree.
    readonly property bool widthAnimating: root.orientation === Qt.Horizontal
        && horizontalWidthAnimation.running

    implicitWidth: orientation === Qt.Horizontal
        ? (reveal ? naturalWidth : 0) : naturalWidth
    implicitHeight: orientation === Qt.Vertical
        ? (reveal ? naturalHeight : 0) : naturalHeight
    visible: reveal || implicitWidth > 0.5 || implicitHeight > 0.5
    opacity: reveal ? 1 : 0
    clip: true

    Behavior on implicitWidth {
        enabled: root.orientation === Qt.Horizontal
        NumberAnimation {
            id: horizontalWidthAnimation
            duration: Theme.expandDuration
            easing.type: Easing.BezierSpline
            // Keep the lively overshoot when content arrives. On exit that
            // same curve drives width briefly below zero, which makes a Row's
            // following content cross its pinned endpoint and rebound.
            easing.bezierCurve: root.reveal
                ? Theme.springCurve : Theme.easeInCurve
        }
    }

    Behavior on implicitHeight {
        enabled: root.orientation === Qt.Vertical
        NumberAnimation {
            duration: Theme.expandDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.springCurve
        }
    }

    Behavior on opacity {
        NumberAnimation {
            duration: Theme.chipFadeDuration
            easing.type: Easing.OutCubic
        }
    }

    Item {
        id: contentRoot
        width: childrenRect.width
        height: childrenRect.height
        // Keep the child alive for the closing animation, but remove all of
        // its controls from keyboard and accessibility traversal as soon as
        // the controlling mode is switched off.
        enabled: root.reveal
        Accessible.ignored: !root.reveal
    }
}
