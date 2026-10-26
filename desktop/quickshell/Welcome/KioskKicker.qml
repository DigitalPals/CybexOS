import QtQuick

// The uppercase mono kicker above headings, cards and fields.
KioskText {
    mono: true
    size: 12
    tone: "fog"
    font.weight: Font.Medium
    font.letterSpacing: Kiosk.px(1.4)
    font.capitalization: Font.AllUppercase
}
