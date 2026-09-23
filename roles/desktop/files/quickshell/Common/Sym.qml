import QtQuick
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
    implicitWidth: size
    implicitHeight: size

    Behavior on color {
        enabled: root.animateColor
        ColorAnimation { duration: Theme.chipFadeDuration }
    }

    Text {
        anchors.fill: parent
        visible: TablerIcons.ready
        text: root.glyph.outline
        font.family: TablerIcons.outline.name
        font.pixelSize: root.size
        font.weight: Font.Normal
        color: root.color
        horizontalAlignment: root.horizontalAlignment
        verticalAlignment: Text.AlignVCenter
        renderType: Text.QtRendering
        Accessible.ignored: true
    }
}
