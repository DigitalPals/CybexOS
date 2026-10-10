pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import "TablerGlyphs.js" as Tabler

// One Tabler icon in a stable square slot. Keep the semantic name API so
// built-ins and user plugins migrate together. Unknown names draw help-circle;
// empty names draw nothing. The registry is checked against the bundled outline TTF.
Item {
    id: root

    property string name: ""
    property real size: 16
    property color color: Theme.icon
    property bool animateColor: true
    property int horizontalAlignment: Text.AlignHCenter
    // Legacy plugin properties are accepted but intentionally have no visual
    // effect. All interface icons use outlines with one consistent stroke.
    property real fill: 0
    property bool animateFill: false
    property real symWeight: 500
    property real grade: 0

    readonly property var glyph: Tabler.resolve(name)
    readonly property bool isSpinner: glyph.outline === Tabler.GLYPHS["loader-2"].outline
    implicitWidth: size
    implicitHeight: size

    Behavior on color {
        enabled: root.animateColor
        ColorAnimation { duration: Theme.chipFadeDuration }
    }

    // Tabler's font starts every glyph at the left edge of a full-width box, so
    // a narrow icon (×, dots, minus) would sit left of the slot's centre by up to
    // a fifth of its size. Centre the drawn ink instead; vertically the glyphs
    // are already centred. An explicit alignment is honoured as it was.
    readonly property bool centreInk: root.horizontalAlignment === Text.AlignHCenter
    TextMetrics {
        id: ink
        font.family: TablerIcons.outline.name
        font.pixelSize: root.size
        font.weight: Font.Normal
        text: root.glyph.outline
    }

    Text {
        x: root.centreInk ? (root.width - ink.tightBoundingRect.width) / 2 - ink.tightBoundingRect.x : 0
        width: root.centreInk ? Math.max(implicitWidth, root.width) : root.width
        height: root.height
        visible: TablerIcons.ready && !root.isSpinner
        text: root.glyph.outline
        font.family: TablerIcons.outline.name
        font.pixelSize: root.size
        font.weight: Font.Normal
        color: root.color
        horizontalAlignment: root.centreInk ? Text.AlignLeft : root.horizontalAlignment
        verticalAlignment: Text.AlignVCenter
        renderType: Text.QtRendering
        Accessible.ignored: true
    }

    // Tabler loader-2's 24px path is M12 3a9 9 0 1 0 9 9. Draw that
    // arc around the slot's exact center: font baseline rounding can offset
    // the glyph and make it orbit when the enclosing Sym rotates.
    Loader {
        anchors.fill: parent
        active: root.isSpinner
        sourceComponent: Shape {
            preferredRendererType: Shape.CurveRenderer
            Accessible.ignored: true

            ShapePath {
                strokeColor: root.color
                strokeWidth: root.size / 12
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap

                PathAngleArc {
                    centerX: root.width / 2
                    centerY: root.height / 2
                    radiusX: root.size * 3 / 8
                    radiusY: radiusX
                    startAngle: -90
                    sweepAngle: -270
                }
            }
        }
    }
}
