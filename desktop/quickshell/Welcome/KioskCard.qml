import QtQuick

// The installer's card: an 18 px rounded panel on the page.
Rectangle {
    color: Kiosk.card
    border.width: Math.max(1, Kiosk.px(1))
    border.color: Kiosk.line
    radius: Kiosk.px(18)
}
