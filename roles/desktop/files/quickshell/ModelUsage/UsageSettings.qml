pragma ComponentBehavior: Bound

import QtQuick
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
  property string accountDetails: ""
  property string errorText: ""
  property string refreshMinutes: "15"
  property alias connectionExpanded: connectionSection.expanded
  property alias activityExpanded: activitySection.expanded
  property alias alertsExpanded: alertsSection.expanded
  readonly property bool percentageDisplay: draft.barDisplayMode === "Percentages"
  onProxyModeChanged: if (proxyMode && !draft.cliproxyKeyFile) connectionSection.expanded = true
  property var draft: ({})
  property alias managementKey: managementCredential.text
  property alias keeperPassword: keeperCredential.text
  readonly property bool saving: keyWriter.running
  property var pendingValues: null
  property var pendingKeys: ({})
  property bool keySaveDecided: false
  property var proxyProviders: []
  readonly property var providerOptions: proxyMode ? UsageLogic.listOrEmpty(proxyProviders) : [
    { id: "claude", name: "Claude Code" },
    { id: "codex", name: "OpenAI Codex" },
    { id: "kimi", name: "Kimi Code" }
  ]
  readonly property var allProviderIds: {
    var ids = ["claude", "codex", "kimi"]
    for (var i = 0; i < proxyProviders.length; i++)
      if (!UsageLogic.contains(ids, proxyProviders[i].id)) ids.push(proxyProviders[i].id)
    return ids
  }
  readonly property bool proxyMode: draft.usageSource === "cliproxy"

  signal saveRequested(var values)
  signal cancelRequested()
  signal revealRequested(var item)

  spacing: Style.spacing.xxl
  enabled: !saving
  Keys.onEscapePressed: root.cancelRequested()

  function discardKey() {
    managementCredential.reset()
    keeperCredential.reset()
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
    if (saved) { managementKey = ""; keeperPassword = "" }
  }

  function begin(settings) {
    discardKey()
    function value(key, fallback) {
      return settings[key] === undefined || settings[key] === null ? fallback : settings[key]
    }
    draft = {
      usageSource: value("usageSource", "direct") === "cliproxy" ? "cliproxy" : "direct",
      cliproxyUrl: String(value("cliproxyUrl", "http://127.0.0.1:8317")),
      cliproxyKeyFile: String(value("cliproxyKeyFile", "")),
      costKeeperUrl: String(value("costKeeperUrl", "")),
      costKeeperPasswordFile: String(value("costKeeperPasswordFile", "")),
      enabledProviders: value("enabledProviders", ["claude", "codex", "kimi"]),
      barProviders: value("barProviders", ["claude", "codex", "kimi"]),
      hideAccountEmails: value("hideAccountEmails", true) !== false,
      squareUsageCards: value("squareUsageCards", true) === true,
      barDisplayMode: value("barDisplayMode", "Percentages"),
      refreshIntervalSec: String(value("refreshIntervalSec", 900)),
      warningThreshold: String(value("warningThreshold", 25)),
      criticalThreshold: String(value("criticalThreshold", 10))
    }
    refreshMinutes = String(Number(draft.refreshIntervalSec) / 60)
    connectionSection.expanded = proxyMode && !draft.cliproxyKeyFile
    activitySection.expanded = false
    alertsSection.expanded = false
    diagnosticsSection.expanded = false
    errorText = ""
  }

  function setValue(key, value) {
    var next = Object.assign({}, draft)
    next[key] = value
    draft = next
    if (key === "refreshIntervalSec") refreshMinutes = String(value).trim() === "" ? "" : String(Number(value) / 60)
    errorText = ""
  }

  function toggleProvider(key, id) {
    var selected = UsageLogic.listOrEmpty(draft[key])
    var result = []
    for (var i = 0; i < allProviderIds.length; i++) {
      var candidate = allProviderIds[i]
      if (UsageLogic.contains(selected, candidate) !== (candidate === id)) result.push(candidate)
    }
    setValue(key, result)
  }

  function focusFirst() { sourceControl.forceActiveFocus() }

  function fail(message, section, item) {
    errorText = message
    if (section) section.expanded = true
    Qt.callLater(function() {
      if (!root.visible || root.errorText !== message) return
      if (item.focusEditor) item.focusEditor()
      else { item.forceActiveFocus(); root.revealRequested(item) }
    })
    return false
  }

  function submit() {
    if (saving) return false
    var next = Object.assign({}, draft)
    var minutes = Number(refreshMinutes)
    if (refreshMinutes.trim() === "" || !isFinite(minutes) || minutes < 1 || minutes > 60)
      return fail("Enter a refresh interval from 1 to 60 minutes.", alertsSection, refreshField)
    next.refreshIntervalSec = Math.round(minutes * 60)
    var ranges = [
      ["refreshIntervalSec", "Refresh interval", 60, 3600],
      ["warningThreshold", "Warning threshold", 1, 100],
      ["criticalThreshold", "Critical threshold", 0, 100]
    ]
    for (var i = 0; i < ranges.length; i++) {
      var range = ranges[i]
      var raw = String(next[range[0]]).trim()
      var value = Number(raw)
      if (raw === "" || !isFinite(value) || Math.floor(value) !== value
          || value < range[2] || value > range[3]) {
        return fail(range[1] + " must be a whole number from " + range[2] + " to " + range[3] + ".",
          alertsSection, range[0] === "warningThreshold" ? warningField : range[0] === "criticalThreshold" ? criticalField : refreshField)
      }
      next[range[0]] = value
    }
    if (next.criticalThreshold > next.warningThreshold) {
      return fail("Critical threshold must be at or below the warning threshold.", alertsSection, criticalField)
    }
    next.cliproxyUrl = String(next.cliproxyUrl).trim()
    next.cliproxyKeyFile = String(next.cliproxyKeyFile).trim()
    if (proxyMode && !/^https?:\/\/[^\s/?#@]+(?::[0-9]+)?(?:\/[^\s?#]*)?$/.test(next.cliproxyUrl)) {
      return fail("Enter an HTTP or HTTPS server URL without credentials, query, or fragment.", connectionSection, proxyUrlField)
    }
    var key = managementKey.trim()
    if (proxyMode && managementKey !== "" && (key === "" || key.length > 8191 || /[^\x20-\x7e]/.test(key))) {
      return fail("Enter a nonempty management API key using ASCII characters.", connectionSection, managementCredential)
    }
    next.costKeeperUrl = String(next.costKeeperUrl).trim()
    var password = keeperPassword.trim()
    if ((proxyMode && (next.costKeeperUrl !== "" || password !== ""))
        && !/^https?:\/\/[^\s/?#@]+(?::[0-9]+)?(?:\/[^\s?#]*)?$/.test(next.costKeeperUrl)) {
      return fail("Enter the CPA Usage Keeper HTTP or HTTPS URL.", activitySection, keeperUrlField)
    }
    if (keeperPassword !== "" && (password === "" || password.length > 8191 || /[^\x20-\x7e]/.test(password))) {
      return fail("Enter a nonempty Keeper password using ASCII characters.", activitySection, keeperCredential)
    }
    var keys = ({})
    if (proxyMode && key !== "") keys.cliproxyKeyFile = key
    if (proxyMode && password !== "") keys.costKeeperPasswordFile = password
    errorText = ""
    if (Object.keys(keys).length > 0) {
      pendingValues = next
      pendingKeys = keys
      keySaveDecided = false
      keyWriter.running = true
    } else saveRequested(next)
    return true
  }

  Process {
    id: keyWriter
    command: ["python3", "-u", decodeURIComponent(String(Qt.resolvedUrl("scripts/management-key.py")).replace(/^file:\/\//, ""))]
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify({ keys: root.pendingKeys, previousPaths: {
        cliproxyKeyFile: root.draft.cliproxyKeyFile,
        costKeeperPasswordFile: root.draft.costKeeperPasswordFile
      } }) + "\n")
      root.pendingKeys = ({})
    }
    stdout: SplitParser {
      onRead: function(data) {
        if (!root.pendingValues || root.keySaveDecided) return
        var response = null
        try { response = JSON.parse(data) } catch (error) {}
        if (!response || !response.paths) return
        var values = Object.assign({}, root.pendingValues, response.paths)
        root.saveRequested(values)
      }
    }
    stderr: SplitParser { splitMarker: "" }
    onRunningChanged: if (!running) {
      root.pendingKeys = ({})
      if (root.pendingValues && !root.keySaveDecided)
        root.errorText = "Could not save credentials. Check that your configuration directory is writable and try again."
      root.pendingValues = null
    }
  }

  Timer {
    interval: 7000
    running: keyWriter.running
    onTriggered: keyWriter.running = false
  }

  SettingsHeader {
    width: parent.width
    title: "Limits settings"
    foreground: root.foreground
    fontFamily: root.fontFamily
    onCloseRequested: root.cancelRequested()
    onRevealRequested: function(item) { root.revealRequested(item) }
  }

  Row {
    width: parent.width
    Label {
      width: parent.width - sourceControl.width
      text: "Quota source"
      anchors.verticalCenter: parent.verticalCenter
    }
    UsageSelect {
      id: sourceControl
      objectName: "usageSourceControl"
      width: Math.min(implicitWidth, parent.width * 0.6)
      label: "Quota source"
      options: [{ value: "direct", label: "Local CLIs" }, { value: "cliproxy", label: "CLIProxyAPI" }]
      value: String(root.draft.usageSource || "direct")
      foreground: root.foreground
      surface: root.surface
      fontFamily: root.fontFamily
      alignPopupRight: true
      onChanged: function(value) { root.setValue("usageSource", value) }
      onMenuClosed: if (root.visible) sourceControl.forceActiveFocus()
      onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
    }
  }

  Section {
    id: connectionSection
    objectName: "quotaConnectionSection"
    visible: root.proxyMode
    title: "Connection details"
    summary: root.draft.cliproxyKeyFile ? "Configured" : "Setup"
    Label { text: "CLIProxyAPI server URL" }
    Field {
      id: proxyUrlField
      objectName: "cliproxyUrlField"
      settingKey: "cliproxyUrl"
      placeholderText: "http://127.0.0.1:8317"
      Accessible.name: "CLIProxyAPI server URL"
    }
    SettingsCredential {
      id: managementCredential
      width: parent.width
      label: "Management API key"
      editorObjectName: "managementKeyField"
      saved: !!root.draft.cliproxyKeyFile
      foreground: root.foreground
      fontFamily: root.fontFamily
      onEdited: root.errorText = ""
      onRevealRequested: function(item) { root.revealRequested(item) }
    }
    Hint { text: "Save to discover the proxy’s providers and accounts." }
    Section {
      title: "Learn more"
      Hint { text: "Use the key for the CLIProxyAPI management panel. It is saved privately on this device. Quota limits and estimated costs use separate data sources." }
    }
  }

  Column {
    width: parent.width
    spacing: Style.spacing.md
    Label { text: "Display"; font.bold: true }
    Row {
      width: parent.width
      Label { width: parent.width - barDisplay.width; text: "Menu bar"; anchors.verticalCenter: parent.verticalCenter }
      UsageSelect {
        id: barDisplay
        objectName: "barDisplayControl"
        width: Math.min(implicitWidth, parent.width * 0.7)
        label: "Menu bar display"
        options: [{ value: "Icon", label: "Widget icon" }, { value: "Percentages", label: "Provider percentages" }]
        value: String(root.draft.barDisplayMode || "Percentages")
        foreground: root.foreground
        surface: root.surface
        fontFamily: root.fontFamily
        alignPopupRight: true
        onChanged: function(value) { root.setValue("barDisplayMode", value) }
        onMenuClosed: if (root.visible) barDisplay.forceActiveFocus()
        onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
      }
    }
    Row {
      width: parent.width
      Label { width: parent.width - hideEmailSwitch.width; text: "Hide account emails"; anchors.verticalCenter: parent.verticalCenter }
      ProviderToggle {
        id: hideEmailSwitch
        objectName: "hideAccountEmailsToggle"
        width: Style.space(82)
        checked: root.draft.hideAccountEmails !== false
        Accessible.name: "Hide account emails"
        onToggled: root.setValue("hideAccountEmails", !checked)
      }
    }
    Hint { text: "Use Account 1, Account 2, … instead of account identities." }
    Row {
      width: parent.width
      Label { width: parent.width - squareCardsSwitch.width; text: "Square usage cards"; anchors.verticalCenter: parent.verticalCenter }
      ProviderToggle {
        id: squareCardsSwitch
        objectName: "squareUsageCardsToggle"
        width: Style.space(82)
        checked: root.draft.squareUsageCards === true
        Accessible.name: "Square usage cards"
        onToggled: root.setValue("squareUsageCards", !checked)
      }
    }
    Hint { text: "Override theme corners for cards in Limits. Turn off to follow the theme." }
  }

  Column {
    id: providerSection
    visible: !root.proxyMode || root.percentageDisplay
    width: parent.width
    spacing: Style.spacing.sm
    Row {
      width: parent.width
      Label { width: parent.width - monitorHeading.width - barHeading.width; text: root.proxyMode ? "Show in menu bar" : "Providers"; font.bold: true }
      Label { id: monitorHeading; visible: !root.proxyMode; width: visible ? Style.space(82) : 0; text: "Monitor"; horizontalAlignment: Text.AlignHCenter }
      Label { id: barHeading; visible: !root.proxyMode && root.percentageDisplay; width: visible ? Style.space(100) : 0; text: "Menu bar"; horizontalAlignment: Text.AlignHCenter }
    }
    Repeater {
      model: root.providerOptions
      delegate: Row {
        id: providerRow
        required property var modelData
        width: providerSection.width
        Label {
          width: parent.width - monitorSwitch.width - barSwitch.width
          anchors.verticalCenter: parent.verticalCenter
          text: providerRow.modelData.name
        }
        ProviderToggle {
          id: monitorSwitch
          visible: !root.proxyMode
          width: visible ? Style.space(82) : 0
          objectName: "monitor-" + providerRow.modelData.id
          Accessible.name: "Monitor " + providerRow.modelData.name
          enabled: !root.proxyMode
          checked: root.proxyMode || UsageLogic.contains(root.draft.enabledProviders, providerRow.modelData.id)
          onToggled: root.toggleProvider("enabledProviders", providerRow.modelData.id)
        }
        ProviderToggle {
          id: barSwitch
          visible: root.percentageDisplay
          width: visible ? (root.proxyMode ? Style.space(82) : Style.space(100)) : 0
          objectName: "bar-" + providerRow.modelData.id
          Accessible.name: "Show " + providerRow.modelData.id + " in menu bar"
          enabled: monitorSwitch.checked
          checked: monitorSwitch.checked && UsageLogic.contains(root.draft.barProviders, providerRow.modelData.id)
          opacity: enabled ? 1 : 0.4
          onToggled: root.toggleProvider("barProviders", providerRow.modelData.id)
        }
      }
    }
    Hint { text: root.proxyMode ? "All proxy providers are monitored automatically." : "Monitoring keeps a provider available in Limits." }
  }

  Section {
    id: activitySection
    objectName: "accountActivitySection"
    visible: root.proxyMode
    title: "Last-used account"
    summary: root.draft.costKeeperUrl ? "Configured" : "Optional"
    Label { text: "CPA Usage Keeper URL" }
    Field {
      id: keeperUrlField
      objectName: "costKeeperUrlField"
      settingKey: "costKeeperUrl"
      placeholderText: "https://proxy.example.com/keeper"
      Accessible.name: "CPA Usage Keeper URL"
    }
    SettingsCredential {
      id: keeperCredential
      width: parent.width
      label: "Keeper login password"
      editorObjectName: "keeperPasswordField"
      saved: !!root.draft.costKeeperPasswordFile
      foreground: root.foreground
      fontFamily: root.fontFamily
      onEdited: root.errorText = ""
      onRevealRequested: function(item) { root.revealRequested(item) }
    }
    Hint { text: "Show the last-used account in the percentage menu bar." }
    Section {
      title: "Learn more"
      Hint { text: "Use the Keeper connected to this proxy. Account activity updates every 15 seconds, independently of Costs. Leave the URL blank to disable this integration." }
    }
  }

  Section {
    id: alertsSection
    objectName: "refreshAlertsSection"
    title: "Refresh and alerts"
    summary: "Every " + (root.refreshMinutes || "—") + " min"
    Label { text: "Refresh interval (minutes)" }
    SettingsField {
      id: refreshField
      objectName: "refreshMinutesField"
      width: parent.width
      text: root.refreshMinutes
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      inputMethodHints: Qt.ImhFormattedNumbersOnly
      Accessible.name: "Refresh interval in minutes"
      onTextEdited: { root.refreshMinutes = text; root.errorText = "" }
      onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
    }
    Row {
      width: parent.width
      spacing: Style.spacing.lg
      Column {
        width: (parent.width - parent.spacing) / 2
        spacing: Style.spacing.sm
        Label { text: "Warn below (% remaining)" }
        Field { id: warningField; objectName: "warningThresholdField"; settingKey: "warningThreshold"; Accessible.name: "Warning percentage remaining"; inputMethodHints: Qt.ImhDigitsOnly }
      }
      Column {
        width: (parent.width - parent.spacing) / 2
        spacing: Style.spacing.sm
        Label { text: "Critical (% remaining)" }
        Field { id: criticalField; objectName: "criticalThresholdField"; settingKey: "criticalThreshold"; Accessible.name: "Critical percentage remaining"; inputMethodHints: Qt.ImhDigitsOnly }
      }
    }
  }

  Section {
    id: diagnosticsSection
    title: "Diagnostics"
    Hint { text: root.draft.hideAccountEmails !== false ? root.accountDetails.replace(/^Account:.*(?:\n|$)/m, "") : root.accountDetails }
    Hint { text: "The widget uses an icon on vertical bars or when selected providers have no quota data." }
  }

  component Section: SettingsSection {
    width: parent.width
    foreground: root.foreground
    fontFamily: root.fontFamily
    onRevealRequested: function(item) { root.revealRequested(item) }
  }

  component Label: Text {
    width: parent.width
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
  }

  component Hint: Label {
    color: Qt.darker(root.foreground, 1.5)
    font.pixelSize: Style.font.caption
  }

  component Field: SettingsField {
    required property string settingKey
    width: parent.width
    text: String(root.draft[settingKey] === undefined ? "" : root.draft[settingKey])
    foreground: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    selectByMouse: true
    onTextEdited: root.setValue(settingKey, text)
    onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
  }

  component ProviderToggle: Ui.ToggleSwitch {
    foreground: root.foreground
    activeFocusOnTab: true
    hasCursor: activeFocus
    Accessible.role: Accessible.CheckBox
    Accessible.checked: checked
    Accessible.onToggleAction: if (enabled) toggled()
    Keys.onSpacePressed: toggled()
    Keys.onReturnPressed: toggled()
    Keys.onEnterPressed: toggled()
    onActiveFocusChanged: if (activeFocus) root.revealRequested(this)
  }
}
