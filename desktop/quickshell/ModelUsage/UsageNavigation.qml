pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

Item {
  id: root

  property string viewMode: "limits"
  property var viewOptions: []
  property var providerOptions: []
  property string providerId: ""
  property color foreground: Color.foreground
  property color surface: Color.popups.background
  property string fontFamily: Style.font.family
  readonly property bool menuOpen: providerMenu.popup.visible
  readonly property bool providerVisible: viewMode === "limits" && providerOptions.length > 1

  signal viewRequested(string value)
  signal providerRequested(string value)
  signal menuClosed()

  function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity) }

  function openProviderMenu() {
    if (providerVisible) providerMenu.popup.open()
  }
  function closeProviderMenu() { providerMenu.popup.close() }

  onProviderVisibleChanged: if (!providerVisible) closeProviderMenu()
  onVisibleChanged: if (!visible) closeProviderMenu()

  implicitHeight: Style.spacing.controlHeight + Style.spacing.sm

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.spacing.hairline
    color: root.alpha(root.foreground, 0.14)
  }

  UsageTabs {
    id: tabs
    objectName: "usageViewTabs"
    anchors.left: parent.left
    height: parent.height
    width: Math.min(implicitWidth, root.width * 0.55)
    options: root.viewOptions
    value: root.viewMode
    foreground: root.foreground
    fontFamily: root.fontFamily
    onChanged: function(value) { root.viewRequested(value) }
  }

  UsageSelect {
    id: providerMenu
    objectName: "usageProviderMenu"
    visible: root.providerVisible
    anchors.right: parent.right
    width: Math.min(implicitWidth, Math.max(0, root.width - tabs.width - Style.spacing.md))
    options: root.providerOptions
    value: root.providerId
    label: "Provider"
    compactLabel: root.providerId === "codex" ? "Codex" : root.providerId === "claude" ? "Claude" : ""
    foreground: root.foreground
    surface: root.surface
    fontFamily: root.fontFamily
    alignPopupRight: true
    onChanged: function(value) { root.providerRequested(value) }
    onMenuClosed: root.menuClosed()
  }
}
