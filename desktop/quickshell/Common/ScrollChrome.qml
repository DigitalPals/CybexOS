import QtQuick
import "Format.js" as Format

// Viewport chrome for an existing Flickable: edge fades disclose clipped
// content and one quiet thumb becomes legible while the view is moving. It
// owns no pointer handlers, so it cannot steal scrolling, clicks or focus.
Item {
    id: root

    required property Flickable target
    property int orientation: Qt.Vertical
    property real fadeSize: 24
    property color edgeColor: Theme.panelSurface
    property color thumbColor: Theme.accent

    readonly property bool vertical: orientation === Qt.Vertical
    readonly property bool overflow: vertical
        ? target.contentHeight > target.height + 1
        : target.contentWidth > target.width + 1
    readonly property bool atStart: vertical ? target.atYBeginning : target.atXBeginning
    readonly property bool atEnd: vertical ? target.atYEnd : target.atXEnd
    readonly property real viewportPosition: vertical
        ? target.visibleArea.yPosition : target.visibleArea.xPosition
    readonly property real viewportRatio: vertical
        ? target.visibleArea.heightRatio : target.visibleArea.widthRatio
    readonly property real scrollProgress: Format.clamp01(
        viewportPosition / Math.max(0.0001, 1 - viewportRatio))

    z: 99
    visible: overflow

    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        width: root.vertical ? parent.width : root.fadeSize
        height: root.vertical ? root.fadeSize : parent.height
        opacity: root.atStart ? 0 : 1
        gradient: Gradient {
            orientation: root.vertical ? Gradient.Vertical : Gradient.Horizontal
            GradientStop { position: 0; color: root.edgeColor }
            GradientStop { position: 1; color: "transparent" }
        }

        Behavior on opacity {
            NumberAnimation { duration: Theme.chipFadeDuration; easing.type: Easing.OutCubic }
        }
    }

    Rectangle {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: root.vertical ? parent.width : root.fadeSize
        height: root.vertical ? root.fadeSize : parent.height
        opacity: root.atEnd ? 0 : 1
        rotation: 180
        gradient: Gradient {
            orientation: root.vertical ? Gradient.Vertical : Gradient.Horizontal
            GradientStop { position: 0; color: root.edgeColor }
            GradientStop { position: 1; color: "transparent" }
        }

        Behavior on opacity {
            NumberAnimation { duration: Theme.chipFadeDuration; easing.type: Easing.OutCubic }
        }
    }

    Rectangle {
        id: thumb

        anchors.right: root.vertical ? parent.right : undefined
        anchors.rightMargin: root.vertical ? 2 : 0
        anchors.bottom: root.vertical ? undefined : parent.bottom
        anchors.bottomMargin: root.vertical ? 0 : 2
        x: root.vertical ? 0
            : root.scrollProgress * Math.max(0, root.width - width)
        y: root.vertical
            ? root.scrollProgress * Math.max(0, root.height - height) : 0
        width: root.vertical
            ? (root.target.moving ? 4 : 3)
            : Math.max(22, root.target.visibleArea.widthRatio * root.width)
        height: root.vertical
            ? Math.max(22, root.target.visibleArea.heightRatio * root.height)
            : (root.target.moving ? 4 : 3)
        radius: 2
        color: root.thumbColor
        opacity: root.target.moving ? 0.78 : 0.22

        Behavior on width { NumberAnimation { duration: Theme.chipFadeDuration / 2 } }
        Behavior on height { NumberAnimation { duration: Theme.chipFadeDuration / 2 } }
        Behavior on opacity { NumberAnimation { duration: Theme.chipFadeDuration } }
    }
}
