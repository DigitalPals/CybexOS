import QtQuick
import QtQuick.Shapes

// One inverted edge corner for the hug bar. The canonical path is the lower
// left corner of a top bar; transforms mirror it for the other edge/position.
Item {
    id: root

    property bool rightCorner: false
    property bool bottomCorner: false
    property real cornerSize: Theme.hugCornerSize
    property color fillColor: Theme.barSurface

    width: cornerSize
    height: cornerSize
    transform: [
        Scale {
            origin.x: root.width / 2
            xScale: root.rightCorner ? -1 : 1
        },
        Scale {
            origin.y: root.height / 2
            yScale: root.bottomCorner ? -1 : 1
        }
    ]

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: root.fillColor
            strokeWidth: -1
            startX: 0
            startY: 0
            PathLine { x: root.width; y: 0 }
            PathCubic {
                control1X: root.width * 0.46
                control1Y: 0
                control2X: 0
                control2Y: root.height * 0.46
                x: 0
                y: root.height
            }
            PathLine { x: 0; y: 0 }
        }

    }
}
