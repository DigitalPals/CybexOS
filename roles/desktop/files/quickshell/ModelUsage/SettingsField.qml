pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui as Ui

Ui.TextField {
  id: root
  selectByMouse: true
  background: Ui.BorderSurface {
    color: Style.controlFill(root.activeFocus, root.hovered, root.foreground, root.accent)
    borderSpec: Border.controlSpec(root.activeFocus ? "focus" : root.hovered ? "hover-cursor" : "normal", root.foreground, root.accent)
    radius: Style.space(6)
  }
}
