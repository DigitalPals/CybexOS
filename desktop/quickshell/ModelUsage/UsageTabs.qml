pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

Controls.TabBar {
  id: root

  property var options: []
  property string value: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall
  signal changed(string value)

  implicitHeight: Style.spacing.controlHeight + Style.spacing.sm
  spacing: Style.spacing.md
  currentIndex: {
    for (var i = 0; i < options.length; i++)
      if (options[i].value === value) return i
    return -1
  }
  background: Item {}
  onCurrentIndexChanged: {
    if (currentIndex >= 0 && currentIndex < options.length
        && options.some(function(option) { return option.value === root.value })
        && options[currentIndex].value !== value)
      changed(options[currentIndex].value)
  }

  Repeater {
    model: root.options

    Controls.TabButton {
      id: viewTab
      required property var modelData
      text: modelData.label
      width: implicitWidth
      height: root.height
      implicitHeight: root.height
      leftPadding: Style.spacing.md
      rightPadding: Style.spacing.md
      topPadding: Style.spacing.sm
      bottomPadding: Style.spacing.md
      Accessible.name: text

      contentItem: Text {
        text: viewTab.text
        color: viewTab.checked ? Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        // Reserve bold label widths so changing tabs doesn't move controls.
        font.weight: Font.DemiBold
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }

      background: Rectangle {
        color: viewTab.hovered || viewTab.visualFocus
          ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
        border.width: viewTab.visualFocus ? Style.spacing.hairline : 0
        border.color: Color.accent

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.space(2)
          visible: viewTab.checked
          color: Color.accent
        }
      }
    }
  }
}
