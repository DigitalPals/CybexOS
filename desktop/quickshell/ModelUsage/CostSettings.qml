pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

Column {
  id: root
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color surface: Color.popups.background
  property string fontFamily: Style.font.family
  property var sources: []
  property string errorText: ""
  property string loadError: ""
  property int draftGeneration: 0
  property var localProviders: ["claude", "codex"]
  property alias priceEditor: prices
  property alias remoteExpanded: serverSection.expanded
  property alias pricesExpanded: priceSection.expanded
  property alias diagnosticsExpanded: scanSection.expanded
  property var pendingValues: null
  property var pendingKeys: ({})
  property var previousPaths: ({})
  property bool keySaveDecided: false
  readonly property bool saving: keyWriter.running
  signal saveRequested(var values)
  signal cancelRequested()
  signal revealRequested(var item)
  spacing: Style.spacing.xxl
  enabled: !saving
  Keys.onEscapePressed: cancelRequested()

  function sourceDetail(source) {
    var labels = {ok: "Included", partial: "Partial history", stale: "Saved history · offline",
      missing: "No transcripts", failed: "Unavailable", unavailable: "Unavailable", duplicate: "Already included"}
    var text = source.name + " · " + (labels[source.status] || source.status)
    if (source.status === "stale" && source.updatedAt)
      text += " · " + Qt.formatDateTime(new Date(Number(source.updatedAt)), "MMM d, HH:mm")
    return text
  }

  function discardKey() {
    for (var i = 0; i < servers.count; i++) servers.setProperty(i, "token", "")
    pendingKeys = ({})
    pendingValues = null
    if (keyWriter.running && !keySaveDecided) keyWriter.running = false
  }
  function finishSave(saved) {
    if (keyWriter.running && !keySaveDecided) {
      keySaveDecided = true
      keyWriter.write(saved ? "commit\n" : "abort\n")
    }
    pendingValues = null
    if (saved) discardKey()
  }
  function begin(settings) {
    draftGeneration++
    discardKey()
    servers.clear()
    errorText = ""
    loadError = ""
    serverSection.expanded = false
    priceSection.expanded = false
    scanSection.expanded = false
    localProviders = settings.costLocalProviders === undefined ? ["claude", "codex"] : settings.costLocalProviders
    prices.begin(String(settings.costPriceOverrides || "{}"))
    try {
      var rows = JSON.parse(String(settings.costT3Servers || "[]"))
      if (!Array.isArray(rows) || rows.length > 4) throw new Error()
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i]
        if (!row || typeof row.id !== "string" || typeof row.url !== "string" || typeof row.name !== "string") throw new Error()
        servers.append({serverId: row.id, name: row.name, url: row.url,
          tokenFile: String(row.tokenFile || ""), token: "", included: row.enabled !== false})
      }
    } catch (e) { loadError = "Saved T3 settings are invalid. Remove them to configure servers again." }
    if (loadError) serverSection.expanded = true
    if (prices.loadError) priceSection.expanded = true
  }
  function focusFirst() { localCodex.forceActiveFocus() }
  function toggleLocal(id) {
    var next = []
    var allowed = ["claude", "codex"]
    for (var i = 0; i < allowed.length; i++)
      if (UsageLogic.contains(localProviders, allowed[i]) !== (allowed[i] === id)) next.push(allowed[i])
    localProviders = next
  }
  function addServer() {
    if (servers.count >= 4) return
    servers.append({serverId: "t3-" + Date.now() + "-" + Math.floor(Math.random() * 1000000),
      name: "T3 Code", url: "", tokenFile: "", token: "", included: true})
    focusServer(servers.count - 1, "t3Url-")
  }
  function setServer(index, key, value) { servers.setProperty(index, key, value); errorText = "" }
  function findItem(item, name) {
    if (item.objectName === name) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var result = findItem(children[i], name)
      if (result) return result
    }
    return null
  }
  function focusServer(index, prefix) {
    var generation = draftGeneration
    serverSection.expanded = true
    Qt.callLater(function() {
      if (!root.visible || generation !== root.draftGeneration) return
      var row = serverRepeater.itemAt(index)
      if (!row) return
      row.editorSection.expanded = true
      Qt.callLater(function() {
        if (!root.visible || generation !== root.draftGeneration) return
        var field = root.findItem(row, prefix + index)
        if (!field) return
        if (field.focusEditor) field.focusEditor()
        else { field.forceActiveFocus(); root.revealRequested(field) }
      })
    })
  }
  function submit() {
    if (saving) return false
    if (loadError !== "") { errorText = loadError; serverSection.expanded = true; return false }
    var values = {costLocalProviders: localProviders}
    try { values.costPriceOverrides = prices.serialize() }
    catch (e) { priceSection.expanded = true; errorText = String(e.message || e); return false }
    var rows = [], keys = ({}), previous = ({}), ids = ({})
    for (var i = 0; i < servers.count; i++) {
      var row = servers.get(i), url = row.url.trim(), name = row.name.trim(), token = row.token.trim()
      if (!/^[a-zA-Z0-9-]{1,64}$/.test(row.serverId) || ids[row.serverId]
          || name === "" || name.length > 80 || /[\x00-\x1f]/.test(name)
          || !/^https?:\/\/[^\s/?#@]+(?:\/[^\s?#]*)?$/.test(url)
          || /(?:^|\/)\.{1,2}(?:\/|$)/.test(url)) {
        errorText = "Give each T3 server a name and an HTTP(S) URL without credentials, query, or fragment."
        focusServer(i, name === "" || name.length > 80 || /[\x00-\x1f]/.test(name) ? "t3Name-" : "t3Url-")
        return false
      }
      ids[row.serverId] = true
      if (row.token !== "" && (token === "" || /[^\x21-\x7e]/.test(token))) {
        errorText = "Enter the connection token without spaces."
        focusServer(i, "t3Credential-")
        return false
      }
      rows.push({id: row.serverId, name: name, url: url, tokenFile: row.tokenFile, enabled: row.included})
      if (token !== "") {
        keys["t3Token_" + row.serverId] = token
        previous["t3Token_" + row.serverId] = row.tokenFile
      }
    }
    values.costT3Servers = JSON.stringify(rows)
    errorText = ""
    if (Object.keys(keys).length) {
      pendingValues = values; pendingKeys = keys; previousPaths = previous
      keySaveDecided = false; keyWriter.running = true
    } else saveRequested(values)
    return true
  }

  ListModel { id: servers }
  Process {
    id: keyWriter
    command: ["python3", "-u", decodeURIComponent(String(Qt.resolvedUrl("scripts/management-key.py")).replace(/^file:\/\//, ""))]
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify({keys: root.pendingKeys, previousPaths: root.previousPaths}) + "\n")
      root.pendingKeys = ({})
    }
    stdout: SplitParser {
      onRead: function(data) {
        if (!root.pendingValues || root.keySaveDecided) return
        var response
        try { response = JSON.parse(data) } catch (e) { return }
        if (!response.paths) return
        var values = Object.assign({}, root.pendingValues)
        var rows = JSON.parse(values.costT3Servers)
        for (var i = 0; i < rows.length; i++) {
          var path = response.paths["t3Token_" + rows[i].id]
          if (path) rows[i].tokenFile = path
        }
        values.costT3Servers = JSON.stringify(rows)
        root.saveRequested(values)
      }
    }
    stderr: SplitParser { splitMarker: "" }
    onRunningChanged: if (!running) {
      root.pendingKeys = ({})
      if (root.pendingValues && !root.keySaveDecided) root.errorText = "Could not save the private T3 token. Check your configuration directory and try again."
      root.pendingValues = null
    }
  }
  Timer { interval: 7000; running: keyWriter.running; onTriggered: keyWriter.running = false }

  SettingsHeader {
    width: parent.width
    title: "Costs settings"
    foreground: root.foreground
    fontFamily: root.fontFamily
    onCloseRequested: root.cancelRequested()
    onRevealRequested: function(item) { root.revealRequested(item) }
  }
  Column {
    width: parent.width
    spacing: Style.spacing.md
    Label { text: "Local history"; font.bold: true }
    Row {
      width: parent.width
      Label { width: parent.width - localCodex.width; text: "Codex CLI"; anchors.verticalCenter: parent.verticalCenter }
      Toggle { id: localCodex; objectName: "costLocalCodex"; checked: UsageLogic.contains(root.localProviders, "codex"); onToggled: root.toggleLocal("codex"); Accessible.name: "Include local Codex" }
    }
    Row {
      width: parent.width
      Label { width: parent.width - localClaude.width; text: "Claude Code"; anchors.verticalCenter: parent.verticalCenter }
      Toggle { id: localClaude; objectName: "costLocalClaude"; checked: UsageLogic.contains(root.localProviders, "claude"); onToggled: root.toggleLocal("claude"); Accessible.name: "Include local Claude Code" }
    }
    Hint { text: "Include sessions recorded on this computer." }
  }

  Section {
    id: serverSection
    objectName: "remoteServersSection"
    title: "Remote T3 servers"
    summary: servers.count ? servers.count + (servers.count === 1 ? " server" : " servers") : "Not configured"
    Hint { text: "Include history from other computers running T3 Code." }
    Label { visible: root.loadError !== ""; text: root.loadError; color: root.urgent }
    Ui.Button {
      visible: root.loadError !== ""
      text: "Remove invalid server settings"
      foreground: root.foreground
      fontFamily: root.fontFamily
      focusable: true
      onClicked: { servers.clear(); root.loadError = "" }
    }
    Repeater {
      id: serverRepeater
      model: servers
      Column {
        id: serverRow
        required property int index
        required property string name
        required property string url
        required property string token
        required property string tokenFile
        required property bool included
        property alias editorSection: serverDetails
        width: serverSection.width
        spacing: Style.spacing.sm
        Row {
          width: parent.width
          Label { width: parent.width - remoteToggle.width; text: serverRow.name || "New server"; anchors.verticalCenter: parent.verticalCenter }
          Toggle { id: remoteToggle; checked: serverRow.included; onToggled: root.setServer(serverRow.index, "included", !checked); Accessible.name: "Include T3 server " + (serverRow.index + 1) }
        }
        Section {
          id: serverDetails
          objectName: "t3Details-" + serverRow.index
          title: "Connection details"
          summary: serverRow.url ? "Configured" : "Setup"
          Label { text: "Server name" }
          Field { objectName: "t3Name-" + serverRow.index; text: serverRow.name; placeholderText: "Server name"; maximumLength: 80; onTextEdited: root.setServer(serverRow.index, "name", text); Accessible.name: "T3 server name" }
          Label { text: "Server URL" }
          Field { objectName: "t3Url-" + serverRow.index; text: serverRow.url; placeholderText: "https://t3.example.com"; maximumLength: 4096; onTextEdited: root.setServer(serverRow.index, "url", text); Accessible.name: "T3 server URL" }
          SettingsCredential {
            objectName: "t3Credential-" + serverRow.index
            editorObjectName: "t3Token-" + serverRow.index
            width: parent.width
            label: "Connection token"
            text: serverRow.token
            saved: serverRow.tokenFile !== ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            onEdited: function(value) { root.setServer(serverRow.index, "token", value) }
            onRevealRequested: function(item) { root.revealRequested(item) }
          }
          Ui.Button {
            text: "Remove server"
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: true
            onClicked: servers.remove(serverRow.index)
            onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
          }
        }
        Ui.PanelSeparator { foreground: root.foreground }
      }
    }
    Ui.Button {
      objectName: "addT3Server"
      text: "Add T3 server"
      enabled: servers.count < 4 && root.loadError === ""
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      focusable: true
      onClicked: root.addServer()
      onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
    }
    Section {
      title: "Learn more"
      Hint { text: "Use the server’s base URL and connection token. Credentials are saved privately on this device. T3 can include sessions started outside T3; matching transcript folders are counted once. Offline servers retain their last usable history with a timestamp." }
    }
  }

  Section {
    id: priceSection
    objectName: "customPricesSection"
    title: "Custom prices"
    summary: prices.priceCount ? prices.priceCount + (prices.priceCount === 1 ? " override" : " overrides") : "Automatic pricing"
    CostPriceEditor {
      id: prices
      width: parent.width
      foreground: root.foreground
      urgent: root.urgent
      fontFamily: root.fontFamily
      onRevealRequested: function(item) { priceSection.expanded = true; root.revealRequested(item) }
      onEdited: root.errorText = ""
    }
  }

  Section {
    id: scanSection
    objectName: "lastScanSection"
    title: "Last scan"
    summary: root.sources.length ? root.sources.length + (root.sources.length === 1 ? " source" : " sources") : "No scan yet"
    Repeater {
      model: root.sources
      Text {
        required property var modelData
        objectName: "costSource-" + modelData.id
        width: root.width
        text: root.sourceDetail(modelData)
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: modelData.status === "unavailable" || modelData.status === "failed" ? root.urgent : Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        HoverHandler { id: sourceHover }
        Controls.ToolTip.visible: sourceHover.hovered
        Controls.ToolTip.text: String(modelData.message || "")
      }
    }
    Hint { visible: root.sources.length === 0; text: "Open Costs to scan session history." }
  }

  component Section: SettingsSection {
    width: parent.width
    foreground: root.foreground
    fontFamily: root.fontFamily
    onRevealRequested: function(item) { root.revealRequested(item) }
  }
  component Label: Text { width: parent.width; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText; wrapMode: Text.WordWrap }
  component Hint: Label { opacity: 0.7; font.pixelSize: Style.font.caption }
  component Field: SettingsField { width: parent.width; foreground: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; selectByMouse: true; onActiveFocusChanged: if (activeFocus) root.revealRequested(this) }
  component Toggle: Ui.ToggleSwitch {
    width: Style.space(82)
    foreground: root.foreground
    activeFocusOnTab: true
    hasCursor: activeFocus
    Accessible.role: Accessible.CheckBox
    Accessible.checked: checked
    Accessible.onToggleAction: if (enabled) toggled()
    Keys.onSpacePressed: toggled()
    Keys.onReturnPressed: toggled()
    onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
  }
}
