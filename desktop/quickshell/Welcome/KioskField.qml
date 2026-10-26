import QtQuick

// The installer's text field: a deep well with a line edge that turns accent,
// with a soft glow, while it has focus. An icon, if any, sits inside on the left.
FocusScope {
    id: root
    property alias text: input.text
    property alias input: input
    property string placeholder: ""
    property string icon: ""
    property bool mono: false
    property real designHeight: 52
    property real fontSize: 18
    property int maximumLength: 200
    property string label: placeholder
    readonly property real textSize: mono ? fontSize - 1 : fontSize
    signal accepted()
    implicitHeight: Kiosk.px(designHeight)
    implicitWidth: Kiosk.px(320)
    activeFocusOnTab: enabled && visible
    Accessible.role: Accessible.EditableText
    Accessible.name: label
    Rectangle {
        anchors.fill: parent
        anchors.margins: -Kiosk.px(3)
        radius: well.radius + Kiosk.px(3)
        color: "transparent"
        border.width: Kiosk.px(3)
        border.color: Kiosk.accentGlow
        visible: input.activeFocus
    }
    Rectangle {
        id: well
        anchors.fill: parent
        radius: Kiosk.px(12)
        color: Kiosk.bgDeep
        border.width: Math.max(1, Kiosk.px(1))
        border.color: input.activeFocus ? Kiosk.accent : Kiosk.line2
    }
    KioskIcon {
        id: glyph
        visible: root.icon !== ""
        name: root.icon
        x: Kiosk.px(15)
        anchors.verticalCenter: parent.verticalCenter
        color: Kiosk.faint
    }
    TextInput {
        id: input
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.icon !== "" ? Kiosk.px(44) : Kiosk.px(16)
        anchors.rightMargin: Kiosk.px(16)
        anchors.verticalCenter: parent.verticalCenter
        focus: true
        clip: true
        maximumLength: root.maximumLength
        color: Kiosk.ink
        selectionColor: Kiosk.accentLine
        selectedTextColor: Kiosk.ink
        font.family: root.mono ? Kiosk.mono : Kiosk.sans
        font.pixelSize: Math.max(1, Math.round(Kiosk.px(root.textSize)))
        Accessible.role: Accessible.EditableText
        Accessible.name: root.label
        onAccepted: root.accepted()
        KioskText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            visible: input.text === "" && !input.preeditText
            text: root.placeholder
            size: root.fontSize
            tone: "faint"
            elide: Text.ElideRight
        }
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.IBeamCursor
        acceptedButtons: Qt.NoButton
    }
}
