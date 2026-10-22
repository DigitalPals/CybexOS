import QtQuick
import "../Common"

// Rows that belong to one thing — a plugin and its inline forms, an account
// and its calendar switch — kept together under one divider. A row rules
// itself off only when it is not the first in its column, so the first row
// in here draws nothing and the cluster draws that rule above itself, where
// the row would have. Later rows set `divider: false`, which keeps them
// attached to the first.
Item {
    id: root

    default property alias content: body.data

    implicitHeight: body.implicitHeight
    height: implicitHeight

    Rectangle {
        visible: root.y > 0 && root.width >= Theme.settingsNarrowWidth
        x: Theme.settingsMarkInset
        y: -Math.ceil(Theme.settingsRowSpacing / 2) - 1
        width: Math.max(0, root.width - Theme.settingsMarkInset)
        height: 1
        color: Theme.hairlineSoft
    }

    Column {
        id: body
        width: root.width
        spacing: Theme.settingsRowSpacing
    }
}
