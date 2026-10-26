import QtQuick

// Text in the installer's faces: Space Grotesk for copy, JetBrains Mono for
// labels and technical values (installer/kiosk/ui/widgets.slint, Label).
// `size` is in design pixels.
Text {
    property real size: 16
    property bool mono: false
    // ink, fog, faint, accent, red, amber or onAccent.
    property string tone: "ink"
    font.family: mono ? Kiosk.mono : Kiosk.sans
    font.pixelSize: Math.max(1, Math.round(Kiosk.px(size)))
    color: tone === "fog" ? Kiosk.fog : tone === "faint" ? Kiosk.faint : tone === "accent" ? Kiosk.accent
        : tone === "red" ? Kiosk.red : tone === "amber" ? Kiosk.amber : tone === "onAccent" ? Kiosk.accentInk : Kiosk.ink
    textFormat: Text.PlainText
    Accessible.role: Accessible.StaticText
    Accessible.name: text
}
