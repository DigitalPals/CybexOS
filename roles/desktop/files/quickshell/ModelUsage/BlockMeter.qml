pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// Omarchy-native segmented quota meter. Every segment is a single track item;
// only the boundary fragment is overlaid, so the strip is not rendered twice.
// Keep quota blocks square regardless of the theme's corner radius.
Item {
  id: root

  property real value: 0
  property color fillColor: Color.foreground
  property color trackColor: Qt.rgba(fillColor.r, fillColor.g, fillColor.b, 0.14)
  property int blockWidth: Math.max(2, Style.space(5))
  property int blockGap: Math.max(1, Style.space(2))
  property real animatedValue: Math.max(0, Math.min(1, value))

  readonly property int pitch: blockWidth + blockGap
  readonly property int blockCount: Math.max(1, Math.floor((width + blockGap) / pitch))
  readonly property real filledBlocks: animatedValue * blockCount
  readonly property int completeBlocks: Math.floor(filledBlocks)
  readonly property real boundaryFraction: filledBlocks - completeBlocks

  implicitHeight: Math.max(Style.space(8), Math.round(Style.spacing.controlHeight * 0.3))
  clip: true

  Behavior on animatedValue {
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  Repeater {
    model: root.blockCount

    Rectangle {
      required property int index
      x: index * root.pitch
      width: root.blockWidth
      height: root.height
      radius: 0
      color: index < root.completeBlocks ? root.fillColor : root.trackColor
    }
  }

  Rectangle {
    visible: root.completeBlocks < root.blockCount && root.boundaryFraction > 0.001
    x: root.completeBlocks * root.pitch
    width: Math.round(root.blockWidth * root.boundaryFraction)
    height: root.height
    radius: 0
    color: root.fillColor
  }
}
