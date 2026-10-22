pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui as Ui

Controls.ComboBox {
  id: root

  property var options: []
  property string value: ""
  property string label: ""
  property string compactLabel: ""
  property color foreground: Color.foreground
  property color surface: Color.popups.background
  property string fontFamily: Style.font.family
  property real popupMaximumWidth: parent ? parent.width : implicitWidth
  property bool alignPopupRight: false
  readonly property bool menuOpen: popup.visible

  signal changed(string value)
  signal menuClosed()

  function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity) }
  function openMenu() { if (visible && enabled && options.length > 0) popup.open() }
  function closeMenu() { popup.close() }
  onVisibleChanged: if (!visible) closeMenu()

  implicitHeight: Style.spacing.controlHeight
  implicitWidth: selectedLabel.implicitWidth + leftPadding + rightPadding
  leftPadding: Style.spacing.md
  rightPadding: chevron.width + Style.spacing.lg
  model: options
  textRole: "label"
  valueRole: "value"
  currentIndex: {
    for (var i = 0; i < options.length; i++)
      if (options[i].value === value) return i
    return -1
  }
  displayText: compactLabel || currentText
  Accessible.name: label + ": " + currentText
  onActivated: changed(String(currentValue))

  contentItem: Text {
    id: selectedLabel
    text: root.displayText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  indicator: Text {
    id: chevron
    x: root.width - width - Style.spacing.sm
    anchors.verticalCenter: parent.verticalCenter
    text: root.popup.visible ? "▴" : "▾"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  background: Rectangle {
    radius: Style.space(4)
    color: root.hovered || root.visualFocus || root.menuOpen
      ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
    border.width: root.visualFocus ? Style.spacing.hairline : 0
    border.color: Color.accent
  }

  popup: Controls.Popup {
    x: root.alignPopupRight ? root.width - width : 0
    y: root.height + Style.spacing.sm
    width: Math.min(root.popupMaximumWidth, Math.max(root.width, Style.space(200)))
    implicitHeight: Math.min(contentItem.implicitHeight + padding * 2,
      Style.spacing.popupRowHeight * 6 + padding * 2)
    padding: Style.spacing.sm
    focus: true
    closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutsideParent
    onOpened: {
      optionList.currentIndex = Math.max(0, root.currentIndex)
      optionList.forceActiveFocus()
    }
    onClosed: root.menuClosed()

    background: Ui.BorderSurface {
      color: root.surface
      borderSpec: Border.flat(root.alpha(root.foreground, 0.25), Style.spacing.hairline)
      radius: Style.space(6)
    }

    contentItem: ListView {
      id: optionList
      clip: true
      implicitHeight: contentHeight
      model: root.popup.visible ? root.delegateModel : null
      boundsBehavior: Flickable.StopAtBounds
      Controls.ScrollBar.vertical: Controls.ScrollBar {}

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Down || event.text === "j") {
          currentIndex = Math.min(count - 1, currentIndex + 1)
        } else if (event.key === Qt.Key_Up || event.text === "k") {
          currentIndex = Math.max(0, currentIndex - 1)
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space) {
          if (currentIndex >= 0 && currentIndex < root.options.length)
            root.changed(root.options[currentIndex].value)
          root.popup.close()
        } else if (event.key === Qt.Key_Escape) {
          root.popup.close()
        } else {
          return
        }
        event.accepted = true
      }
    }
  }

  delegate: Controls.ItemDelegate {
    id: optionDelegate
    required property var modelData
    required property int index
    width: root.popup.availableWidth
    height: Style.spacing.popupRowHeight
    highlighted: optionList.currentIndex === index
    onHoveredChanged: if (hovered) optionList.currentIndex = index
    text: modelData.label
    Accessible.name: text
    contentItem: Text {
      text: optionDelegate.text
      color: optionDelegate.modelData.value === root.value ? Color.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: optionDelegate.modelData.value === root.value
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
    background: Rectangle {
      radius: Style.space(4)
      color: optionDelegate.highlighted
        ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
    }
  }
}
