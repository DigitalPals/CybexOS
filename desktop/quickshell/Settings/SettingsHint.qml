import QtQuick
import "../Common"

// The one explanatory line in the settings workspace. A row's description, a
// live status, a disabled row's reason and a group's footnote all read the
// same: secondary type, aligned with the row labels, in the ink its `tone`
// names. A warning or an error also hangs a glyph in the modified-mark
// gutter, so a problem is not told apart from ordinary copy by colour alone
// and the copy itself never shifts off the label lane.
Item {
    id: root

    property string text: ""
    // info | active | warning | error
    property string tone: "info"
    // Rows and groups align copy with their labels; a hint placed inside an
    // already-inset lane passes false.
    property bool inset: true
    property int maximumLines: 3

    readonly property bool flagged: tone === "warning" || tone === "error"
    readonly property color ink: tone === "error" ? Theme.redText
        : tone === "warning" ? Theme.amber
        : tone === "active" ? Theme.accentText
        : Theme.textFaint
    readonly property int textX: root.inset ? Theme.settingsMarkInset
        : root.flagged ? glyph.width + Theme.iconTextSpacing : 0

    visible: text !== ""
    implicitHeight: visible ? body.implicitHeight : 0
    height: implicitHeight
    Accessible.role: flagged ? Accessible.AlertMessage : Accessible.StaticText
    Accessible.name: text

    Sym {
        id: glyph
        visible: root.flagged
        x: root.inset ? Math.max(0, (Theme.settingsMarkInset - width) / 2 - 2) : 0
        y: Math.max(0, (body.lineHeightPx - height) / 2)
        name: root.tone === "error" ? "error" : "warning"
        size: Theme.iconSmall
        color: root.ink
    }

    Text {
        id: body
        // First-line height, so the gutter glyph centres on the first line
        // rather than on a wrapped paragraph.
        readonly property real lineHeightPx: lineCount > 0 ? implicitHeight / lineCount : implicitHeight
        x: root.textX
        width: Math.max(0, root.width - x)
        text: root.text
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: root.ink
        wrapMode: Text.Wrap
        maximumLineCount: root.maximumLines
        elide: Text.ElideRight
    }
}
