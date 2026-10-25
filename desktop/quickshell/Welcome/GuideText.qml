import QtQuick
import "../Common"
Text {
    property string tone: "normal"
    color: tone === "muted" ? Theme.textMid : tone === "accent" ? Theme.accentText : Theme.textHi
    font.family: Theme.fontMenu
    font.pixelSize: Theme.typography.primary
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    Accessible.role: Accessible.StaticText
    Accessible.name: text
}
