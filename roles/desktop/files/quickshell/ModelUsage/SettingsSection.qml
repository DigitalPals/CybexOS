pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

Column {
  id: root
  property string title: ""
  property string summary: ""
  property alias expanded: disclosure.checked
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  default property alias content: body.data
  signal revealRequested(var item)
  spacing: Style.spacing.md
  data: [
    UsageDisclosure {
      id: disclosure
      width: root.width
      text: root.title + (root.summary ? " · " + root.summary : "")
      foreground: root.foreground
      fontFamily: root.fontFamily
      onActiveFocusChanged: if (activeFocus) root.revealRequested(disclosure)
    },
    Column {
      id: body
      visible: disclosure.checked
      width: root.width
      spacing: Style.spacing.md
    }
  ]
}
