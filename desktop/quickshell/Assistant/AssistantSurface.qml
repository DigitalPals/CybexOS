import QtQuick
import "../Common"

// The card the composer, the working pill and the reply share. Opaque on
// purpose: the assistant's layer is not blurred (a full-output surface would
// pay for blurring every pixel), so glass here would only lower contrast
// over whatever window happens to be underneath.
Rectangle {
    id: root

    default property alias content: column.data
    property real padding: Theme.scaled(12)
    property alias spacing: column.spacing

    implicitHeight: column.implicitHeight + padding * 2
    radius: Theme.surfaceRadius
    color: Theme.popBg
    border.width: 1
    border.color: Theme.popBorder

    Column {
        id: column
        x: root.padding
        y: root.padding
        width: root.width - root.padding * 2
        spacing: Theme.scaled(10)
    }
}
