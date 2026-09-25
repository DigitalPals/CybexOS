pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

Column {
  id: root
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property string loadError: ""
  property int draftGeneration: 0
  readonly property int priceCount: prices.count
  signal revealRequested(var item)
  signal edited()
  spacing: Style.spacing.lg

  function begin(raw) {
    draftGeneration++
    prices.clear()
    loadError = ""
    try {
      var rows = UsageLogic.decodeCostPrices(raw)
      for (var i = 0; i < rows.length; i++) {
        var row = Object.assign({}, rows[i], { modelId: rows[i].model })
        delete row.model
        prices.append(row)
      }
    } catch (error) { loadError = String(error.message || error) }
  }

  function serialize() {
    if (loadError !== "") {
      revealRequested(invalidPricesButton)
      Qt.callLater(function() { invalidPricesButton.forceActiveFocus() })
      throw new Error(loadError)
    }
    var rows = []
    for (var i = 0; i < prices.count; i++) {
      var row = prices.get(i)
      rows.push(Object.assign({}, row, { model: row.modelId }))
    }
    try { return UsageLogic.encodeCostPrices(rows) }
    catch (error) {
      focusField(error.rowIndex === undefined ? 0 : error.rowIndex, error.fieldKey || "modelId")
      throw error
    }
  }

  function findItem(item, name) {
    if (item.objectName === name) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var result = findItem(children[i], name)
      if (result) return result
    }
    return null
  }
  function focusField(index, key) {
    var generation = draftGeneration
    Qt.callLater(function() {
      if (generation !== root.draftGeneration) return
      var field = root.findItem(root, key === "modelId" ? "costModel-" + index : "costRate-" + index + "-" + key)
      if (!field) return
      root.revealRequested(field)
      Qt.callLater(function() { field.forceActiveFocus() })
    })
  }

  function addPrice() {
    if (prices.count >= 128 || loadError !== "") return
    prices.append({ modelId: "", inputCostPerMillionTokens: "", outputCostPerMillionTokens: "",
      cacheReadCostPerMillionTokens: "", cacheWriteCostPerMillionTokens: "" })
    edited()
    focusField(prices.count - 1, "modelId")
  }

  ListModel { id: prices }

  Label {
    text: "Prices are USD per million tokens and override automatic rates."
    opacity: 0.7
    font.pixelSize: Style.font.caption
  }
  SettingsSection {
    width: parent.width
    title: "Learn more"
    foreground: root.foreground
    fontFamily: root.fontFamily
    onRevealRequested: function(item) { root.revealRequested(item) }
    Label {
      text: "Copy the exact model ID from Costs, including its provider and any [variant]. Overrides apply across all sources. Remove a row to restore automatic pricing. Blank cache prices use the input price; enter 0 for free tokens."
      font.pixelSize: Style.font.caption
      opacity: 0.7
    }
  }
  Label { visible: root.loadError !== ""; text: root.loadError; color: root.urgent }
  Ui.Button {
    id: invalidPricesButton
    visible: root.loadError !== ""
    text: "Remove invalid custom prices"
    foreground: root.foreground
    fontFamily: root.fontFamily
    bordered: true
    focusable: true
    onClicked: { root.begin("{}"); root.edited() }
    onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
  }

  Repeater {
    model: prices
    delegate: Column {
      id: priceRow
      required property int index
      required property string modelId
      required property string inputCostPerMillionTokens
      required property string outputCostPerMillionTokens
      required property string cacheReadCostPerMillionTokens
      required property string cacheWriteCostPerMillionTokens
      width: root.width
      spacing: Style.spacing.md

      Label { text: "Model ID" }
      SettingsField {
        objectName: "costModel-" + priceRow.index
        width: parent.width
        text: priceRow.modelId
        maximumLength: 256
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        selectByMouse: true
        Accessible.name: "Custom price model ID"
        onTextEdited: { prices.setProperty(priceRow.index, "modelId", text); root.edited() }
        onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
      }
      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.spacing.lg
        rowSpacing: Style.spacing.md
        Repeater {
          model: [
            { key: "inputCostPerMillionTokens", label: "Input" },
            { key: "outputCostPerMillionTokens", label: "Output" },
            { key: "cacheReadCostPerMillionTokens", label: "Cache read (optional)" },
            { key: "cacheWriteCostPerMillionTokens", label: "Cache write (optional)" }
          ]
          delegate: Column {
            id: rateField
            required property var modelData
            width: (priceRow.width - Style.spacing.lg) / 2
            spacing: Style.spacing.sm
            Label { text: rateField.modelData.label }
            SettingsField {
              objectName: "costRate-" + priceRow.index + "-" + rateField.modelData.key
              width: parent.width
              text: priceRow[rateField.modelData.key]
              maximumLength: 32
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              selectByMouse: true
              inputMethodHints: Qt.ImhFormattedNumbersOnly
              Accessible.name: rateField.modelData.label + " USD per million tokens"
              onTextEdited: { prices.setProperty(priceRow.index, rateField.modelData.key, text); root.edited() }
              onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
            }
          }
        }
      }
      Ui.Button {
        text: "Remove price"
        foreground: root.foreground
        fontFamily: root.fontFamily
        focusable: true
        onClicked: { prices.remove(priceRow.index); root.edited() }
        onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
      }
    }
  }
  Label {
    text: prices.count === 0 ? "Automatic prices are in use. Unknown models remain unpriced."
      : "Blank cache prices use the input price. Enter 0 explicitly for free tokens."
    opacity: 0.7
    font.pixelSize: Style.font.caption
  }
  Ui.Button {
    objectName: "addCostPriceButton"
    text: "Add model price"
    enabled: prices.count < 128 && root.loadError === ""
    foreground: root.foreground
    fontFamily: root.fontFamily
    bordered: true
    focusable: true
    onClicked: root.addPrice()
    onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
  }

  component Label: Text {
    width: parent.width
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
