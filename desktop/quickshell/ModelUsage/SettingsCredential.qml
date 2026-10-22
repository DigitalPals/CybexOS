pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui as Ui

Column {
  id: root
  property string label: "Credential"
  property bool saved: false
  property bool changing: false
  property alias text: field.text
  property string editorObjectName: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  signal edited(string value)
  signal revealRequested(var item)
  spacing: Style.spacing.sm

  function reset() { text = ""; changing = false }
  function focusEditor() {
    changing = true
    Qt.callLater(function() { field.forceActiveFocus(); root.revealRequested(field) })
  }

  Row {
    width: parent.width
    visible: root.saved && !root.changing && root.text === ""
    Text {
      width: parent.width - changeButton.width
      anchors.verticalCenter: parent.verticalCenter
      text: root.label + " saved"
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
    Ui.Button {
      id: changeButton
      text: "Change"
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      focusable: true
      onClicked: root.focusEditor()
      onActiveFocusChanged: if (activeFocus) root.revealRequested(changeButton)
    }
  }
  SettingsField {
    id: field
    objectName: root.editorObjectName
    width: parent.width
    visible: !root.saved || root.changing || root.text !== ""
    password: true
    maximumLength: 8191
    placeholderText: root.saved ? "New credential · blank keeps the saved value" : root.label
    foreground: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    Accessible.name: root.label
    onTextEdited: root.edited(text)
    onActiveFocusChanged: if (activeFocus) root.revealRequested(field)
  }
}
