pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

Controls.AbstractButton {
  id: root

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  checkable: true
  implicitHeight: Math.max(Style.spacing.controlHeight, implicitContentHeight + topPadding + bottomPadding)
  implicitWidth: implicitContentWidth + leftPadding + rightPadding
  leftPadding: Style.spacing.sm
  rightPadding: Style.spacing.sm
  topPadding: Style.spacing.sm
  bottomPadding: Style.spacing.sm
  Accessible.name: text
  Accessible.description: checked ? "Expanded" : "Collapsed"

  contentItem: Text {
    text: (root.checked ? "▾ " : "▸ ") + root.text
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  background: Rectangle {
    radius: Style.space(4)
    color: root.hovered || root.visualFocus
      ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
    border.width: root.visualFocus ? Style.spacing.hairline : 0
    border.color: Color.accent
  }
}
