import QtQuick
import "../Common"

// A shell outline icon sized in design pixels.
Sym {
    property real designSize: 18
    size: Kiosk.px(designSize)
    color: Kiosk.fog
    animateColor: false
}
