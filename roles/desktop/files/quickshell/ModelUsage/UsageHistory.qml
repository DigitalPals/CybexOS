pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

Item {
  id: root

  property var history: ({ h24: [], d7: [] })
  property string mode: "h24"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property var values: mode === "d7"
    ? (history ? UsageLogic.listOrEmpty(history.d7) : [])
    : (history ? UsageLogic.listOrEmpty(history.h24) : [])

  implicitHeight: content.implicitHeight

  Column {
    id: content
    width: parent.width
    spacing: Style.spacing.lg

    Item {
      width: parent.width
      implicitHeight: Math.max(title.implicitHeight, ranges.implicitHeight)

      Ui.PanelSectionHeader {
        id: title
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "USAGE HISTORY"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Ui.ButtonGroup {
        id: ranges
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        options: [
          { value: "h24", label: "24H" },
          { value: "d7", label: "7D" }
        ]
        value: root.mode
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        focusable: false
        onChanged: function(value) { root.mode = value }
      }
    }

    Row {
      id: chart
      width: parent.width
      height: Style.space(58)
      spacing: Style.spacing.xxs

      Repeater {
        model: root.values

        delegate: Item {
          id: bucket
          required property var modelData
          readonly property int segmentHeight: Math.max(2, Style.space(3))
          readonly property int segmentGap: Math.max(1, Style.space(2))
          readonly property int segmentPitch: segmentHeight + segmentGap
          readonly property int segmentCount: Math.max(1, Math.floor(height / segmentPitch))
          readonly property int filledSegments: Math.ceil(
            Math.max(0, Math.min(100, Number(modelData) || 0)) / 100 * segmentCount)

          width: root.values.length > 0
            ? (chart.width - chart.spacing * (root.values.length - 1)) / root.values.length
            : 0
          height: chart.height

          Repeater {
            model: bucket.filledSegments

            Rectangle {
              required property int index
              width: bucket.width
              height: bucket.segmentHeight
              y: bucket.height - (index + 1) * bucket.segmentPitch
              radius: Math.min(Style.cornerRadius, height / 3)
              color: index === bucket.filledSegments - 1
                ? root.foreground
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.62)
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.spacing.hairline
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          }
        }
      }
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(axisStart.implicitHeight, axisMiddle.implicitHeight, axisEnd.implicitHeight)

      Text {
        id: axisStart
        anchors.left: parent.left
        text: root.mode === "h24" ? "−24h" : "−7d"
        color: Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: axisMiddle
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.mode === "h24" ? "−12h" : "−3d"
        color: Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: axisEnd
        anchors.right: parent.right
        text: "now"
        color: Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
