pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

// One approved identity mark. BrandIcons owns name-to-file resolution; this
// component owns sampling and optional contextual tinting/highlighting.
//
// Leave colorized false where product identity is content. BarBrandIcon owns
// the menubar's monochrome presentation; other surrounding surfaces may set
// it when they need the identity rendered as contextual ink.
// Interactive white uses a source SVG with identical geometry: a mask or
// effect can alter antialiased edges and make small marks look heavier.
Item {
    id: root

    property string name: ""
    property bool colorized: false
    property color tint: Theme.icon
    // MultiEffect colourization preserves the source paint's luminance. Use
    // the geometry-matched white variant when the requested tint must be the
    // literal rendered colour rather than a luminance-scaled version of it.
    property bool normalizeTintSource: false
    property real tintAmount: colorized ? 1 : 0
    property bool highlighted: false
    property real highlightAmount: highlighted ? 1 : 0
    readonly property bool available: BrandIcons.has(name)
    readonly property int status: sourceImage.status

    implicitWidth: Theme.iconMedium
    implicitHeight: Theme.iconMedium
    // Every use sits beside copy or inside a named control; exposing the image
    // as a second accessibility node would announce the same identity twice.
    Accessible.ignored: true

    Behavior on tintAmount {
        NumberAnimation { duration: Theme.chipFadeDuration }
    }

    Behavior on highlightAmount {
        NumberAnimation { duration: Theme.chipFadeDuration }
    }

    Image {
        id: sourceImage
        anchors.fill: parent
        source: root.normalizeTintSource
            ? BrandIcons.highlightSource(root.name)
            : BrandIcons.source(root.name)
        sourceSize: Qt.size(Math.max(1, Math.round(root.width * 2)),
            Math.max(1, Math.round(root.height * 2)))
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        opacity: 1 - root.highlightAmount
        Accessible.ignored: true

        // Keep the layer alive until a dynamic tint has faded all the way
        // out, then return static product marks to the cheaper image path.
        layer.enabled: root.available && root.tintAmount > 0.001
        layer.effect: MultiEffect {
            colorization: root.tintAmount
            colorizationColor: root.tint
        }
    }

    Image {
        anchors.fill: parent
        source: BrandIcons.highlightSource(root.name)
        sourceSize: Qt.size(Math.max(1, Math.round(root.width * 2)),
            Math.max(1, Math.round(root.height * 2)))
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        opacity: root.highlightAmount
        Accessible.ignored: true
    }
}
