pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "UsageLogic.js" as UsageLogic

Ui.Panel {
  id: root
  moduleName: "digitalpals.model-usage"
  ipcTarget: "digitalpals.model-usage"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool proxyMode: backend.usageSource === "cliproxy"
  readonly property var providers: UsageLogic.availableProviders(proxyMode
    ? backend.providers : UsageLogic.selectedProviders(backend.providers, backend.enabledProviderIds))
  property string selectedProviderId: ""
  property bool expandedAccountLimits: false
  property string historyMode: "h24"
  property string viewMode: "limits"
  property string settingsReturnView: "limits"
  readonly property bool configuring: viewMode === "settings" || viewMode === "cost-settings"
  readonly property var activeSettingsForm: viewMode === "cost-settings" ? costConfigForm : configForm
  property alias costSettingsForm: costConfigForm
  property alias settingsForm: configForm
  property alias resetAction: resetBackend
  property double nowMs: Date.now()

  readonly property var viewOptions: [
    { value: "limits", label: "Limits" },
    { value: "costs", label: "Costs" }
  ]
  readonly property bool hideAccountEmails: setting("hideAccountEmails", true) !== false
  readonly property real usageCardRadius: setting("squareUsageCards", true) === true ? 0 : Style.cornerRadius

  function accountDisplayName(account, index) {
    return hideAccountEmails ? "Account " + index : String(account.account || "Account " + index)
  }

  readonly property int criticalThreshold: UsageLogic.clamp(
    setting("criticalThreshold", 10), 0, 100)
  readonly property int warningThreshold: Math.max(criticalThreshold, UsageLogic.clamp(
    setting("warningThreshold", 25), 0, 100))
  readonly property string displayMode: String(setting("barDisplayMode", "Percentages"))
  readonly property var percentageProviders: UsageLogic.meaningfulProviders(
    UsageLogic.selectedProviders(providers, setting("barProviders", ["claude", "codex", "kimi"])))
  property alias accountActivity: activityBackend
  readonly property bool percentageMode: displayMode === "Percentages"
    && !(bar && bar.vertical) && percentageProviders.length > 0
  readonly property bool alarming: anyProviderAlarming()
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].id === selectedProviderId) return i
    return 0
  }
  readonly property var providerSummary: providers.length > 0 ? providers[providerIndex] : null
  readonly property var provider: providerSummary
  readonly property var proxyAccounts: UsageLogic.listOrEmpty(providerSummary && providerSummary.accounts)
  readonly property bool accountOverview: proxyMode && proxyAccounts.length > 0
  property alias accountCards: accountRepeater
  readonly property var providerOptions: {
    var result = []
    for (var i = 0; i < providers.length; i++)
      result.push({ value: String(providers[i].id), label: String(providers[i].name || providers[i].id) })
    return result
  }

  function alpha(color, opacity) {
    return Qt.rgba(color.r, color.g, color.b, opacity)
  }

  function clamp(value, low, high) { return Math.max(low, Math.min(high, value)) }

  function anyProviderAlarming() {
    for (var i = 0; i < providers.length; i++) {
      var severity = UsageLogic.severity(providers[i], warningThreshold, criticalThreshold)
      if (severity === "warning" || severity === "critical") return true
    }
    return false
  }

  function ensureSelection() {
    if (providers.length === 0) {
      selectedProviderId = ""
      return
    }
    for (var i = 0; i < providers.length; i++)
      if (providers[i].id === selectedProviderId) return
    selectedProviderId = providers[0].id
  }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = String(providers[wrapped].id)
    if (panelFlick) panelFlick.contentY = 0
  }

  function selectProviderId(providerId) {
    for (var i = 0; i < providers.length; i++) {
      if (providers[i].id === providerId) {
        selectProvider(i)
        return
      }
    }
  }

  function nextProvider() {
    selectProvider(providerIndex + 1)
  }

  function refreshNow() {
    if (viewMode === "costs") costBackend.refresh()
    else backend.refresh()
  }

  function showLimits() {
    viewMode = "limits"
    open()
  }

  function showCosts() {
    viewMode = "costs"
    costBackend.ensureLoaded()
    open()
  }

  function showSettings() {
    if (!configuring) settingsReturnView = viewMode
    configForm.begin(settings)
    viewMode = "settings"
    open()
    Qt.callLater(function() { configForm.focusFirst() })
  }

  function showCostSettings() {
    settingsReturnView = "costs"
    costConfigForm.begin(settings)
    viewMode = "cost-settings"
    open()
    Qt.callLater(function() { costConfigForm.focusFirst() })
  }

  function leaveSettings() {
    activeSettingsForm.discardKey()
    viewMode = settingsReturnView
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function saveSettings(values) {
    var entry = Object.assign({}, settings, values)
    var changed = false
    for (var key in values) {
      if (JSON.stringify(settings[key]) !== JSON.stringify(values[key])) changed = true
    }
    if (changed) {
      if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function"
          || !bar.shell.updateEntryInline(moduleName, entry)) {
        activeSettingsForm.errorText = "Could not save settings. Make sure Model Usage is enabled in the bar, then try again."
        activeSettingsForm.finishSave(false)
        return false
      }
      settings = entry
    }
    activeSettingsForm.finishSave(true)
    leaveSettings()
    return true
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.MiddleButton) nextProvider()
    else if (buttonCode === Qt.LeftButton) toggle()
  }

  function handleProviderChipPress(providerId, buttonCode) {
    if (buttonCode === Qt.MiddleButton) {
      nextProvider()
      return
    }
    if (buttonCode !== Qt.LeftButton) return
    var sameProvider = viewMode === "limits" && selectedProviderId === providerId
    viewMode = "limits"
    selectProviderId(providerId)
    if (opened && sameProvider) close()
    else open()
  }

  function windowSeverity(window) {
    if (!window || window.remaining === null || window.remaining === undefined) return "none"
    var remaining = Number(window.remaining)
    if (!isFinite(remaining)) return "none"
    if (remaining <= criticalThreshold) return "critical"
    if (remaining <= warningThreshold) return "warning"
    return "ok"
  }

  function durationUntil(epochSeconds) {
    var seconds = Number(epochSeconds)
    if (!isFinite(seconds) || seconds <= 0) return ""
    var remaining = Math.floor(seconds - nowMs / 1000)
    if (remaining <= 0) return "now"
    var days = Math.floor(remaining / 86400)
    var hours = Math.floor((remaining % 86400) / 3600)
    var minutes = Math.floor((remaining % 3600) / 60)
    var secs = remaining % 60
    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + minutes + "m"
    if (minutes > 0) return minutes + "m " + secs + "s"
    return Math.max(1, secs) + "s"
  }

  function absoluteReset(epochSeconds) {
    var seconds = Number(epochSeconds)
    if (!isFinite(seconds) || seconds <= 0) return ""
    var date = new Date(seconds * 1000)
    return seconds * 1000 - nowMs < 86400000
      ? Qt.formatTime(date, "HH:mm")
      : Qt.formatDateTime(date, "MMM d, HH:mm")
  }

  function resetText(window) {
    if (!window || !window.resetsAt) return ""
    var relative = durationUntil(window.resetsAt)
    var absolute = absoluteReset(window.resetsAt)
    if (relative === "") return ""
    return "Resets in " + relative + (absolute !== "" ? " · " + absolute : "")
  }

  function heroMeta(provider) {
    return provider && provider.plan ? String(provider.plan) : ""
  }

  function accountTooltip(provider) {
    if (!provider) return ""
    var lines = []
    if (!hideAccountEmails && provider.account) lines.push("Account: " + String(provider.account))
    if (provider.source) lines.push("Source: " + String(provider.source))
    return lines.join("\n")
  }

  function lastAccount(provider) {
    return UsageLogic.lastUsedAccount(provider, activityBackend.providers, hideAccountEmails)
  }

  function lastAccountTooltip(account) {
    var text = "Last used: " + account.label
    if (account.lastUsedAt > 0)
      text += " · " + Qt.formatDateTime(new Date(account.lastUsedAt * 1000), "MMM d, HH:mm:ss")
    if (activityBackend.notice !== "") text += "\n" + activityBackend.notice
    else if (!account.reading) text += "\nNo unique last-used account is available in recorded requests."
    if (account.reading && account.reading.status === "disabled") text += "\nThis account is now paused."
    if (account.reading && account.reading.stale) text += "\nQuota is a last-known reading."
    if (activityBackend.fetchError !== "" && account.reading) text += "\nShowing last-known account activity."
    return text
  }

  function iconUrl(provider) {
    if (!provider) return ""
    if (!UsageLogic.contains(["claude", "codex", "kimi"], provider.id)) return ""
    if (provider.id === "codex") {
      return Qt.resolvedUrl(colorLuminance(surface) >= 0.5
        ? "assets/codex-light.svg" : "assets/codex.svg")
    }
    return Qt.resolvedUrl("assets/" + provider.id + ".svg")
  }

  function barIconUrl(provider) {
    if (!provider) return ""
    if (!UsageLogic.contains(["claude", "codex", "kimi"], provider.id)) return ""
    return Qt.resolvedUrl("assets/" + provider.id + "-bar.svg")
  }

  function colorLuminance(color) {
    function channel(value) {
      return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
  }

  function currencyPrefix(currency) {
    var value = String(currency || "").toUpperCase()
    if (value === "USD") return "$"
    if (value === "EUR") return "€"
    if (value === "GBP") return "£"
    if (value === "CNY") return "¥"
    return value === "" ? "" : value + " "
  }

  function formatAmount(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) return "—"
    var digits = Math.abs(amount - Math.round(amount)) < 0.001 ? 0 : 2
    return currencyPrefix(currency) + amount.toFixed(digits)
  }

  function creditsPrimary(credits) {
    if (!credits) return ""
    if (credits.remaining !== null && credits.remaining !== undefined)
      return formatAmount(credits.remaining, credits.currency) + " remaining"
    if (credits.unlimited) return "Unlimited"
    if (credits.used !== null && credits.used !== undefined)
      return formatAmount(credits.used, credits.currency) + " used"
    if (credits.resetCreditsAvailable !== null && credits.resetCreditsAvailable !== undefined)
      return credits.resetCreditsAvailable + " reset credit" + (credits.resetCreditsAvailable === 1 ? "" : "s")
    return "Available"
  }

  function creditsDetail(credits) {
    if (!credits) return ""
    var parts = []
    if (credits.used !== null && credits.used !== undefined) {
      if (credits.limit !== null && credits.limit !== undefined)
        parts.push(formatAmount(credits.used, credits.currency) + " used of " + formatAmount(credits.limit, credits.currency))
      else parts.push(formatAmount(credits.used, credits.currency) + " used this month")
    }
    if (credits.unlimited && credits.remaining !== null && credits.remaining !== undefined)
      parts.push("No monthly spending cap")
    if (credits.total !== null && credits.total !== undefined)
      parts.push(formatAmount(credits.total, credits.currency) + " funded")
    if (credits.resetCreditsAvailable !== null && credits.resetCreditsAvailable !== undefined)
      parts.push(credits.resetCreditsAvailable + " rate-limit reset credit" + (credits.resetCreditsAvailable === 1 ? "" : "s"))
    return parts.join(" · ")
  }

  function errorBody(provider) {
    if (!provider) return ""
    var message = String(provider.message || "Usage data is unavailable.")
    if (provider.authCommand && (provider.errorKind === "no_credentials" || provider.errorKind === "expired"))
      message += " Run “" + provider.authCommand + "” in a terminal, then refresh."
    return message
  }

  function footerLeft() {
    if (viewMode === "costs") {
      if (costBackend.fetchError !== "") return costBackend.fetchError
      if (costBackend.lastSuccessAt > 0)
        return "Updated " + Qt.formatTime(new Date(costBackend.lastSuccessAt), "HH:mm")
      return costBackend.loading ? "Loading session history…" : "Open Costs to load session history"
    }
    if (backend.fetchError !== "") return backend.fetchError
    if (backend.lastSuccessAt > 0) return "Updated " + Qt.formatTime(new Date(backend.lastSuccessAt), "HH:mm:ss")
    return backend.loading ? "Refreshing…" : "Waiting for first refresh"
  }

  function footerRight() {
    if (viewMode === "costs") return ""
    if (backend.nextRefreshAt <= 0) return ""
    var seconds = Math.max(0, Math.floor((backend.nextRefreshAt - nowMs) / 1000))
    var minutes = Math.floor(seconds / 60)
    var remainder = String(seconds % 60).padStart(2, "0")
    return "Next refresh " + minutes + ":" + remainder
  }

  visible: true
  implicitWidth: percentageMode ? percentageGroup.implicitWidth : iconButton.implicitWidth
  implicitHeight: percentageMode ? percentageGroup.implicitHeight : iconButton.implicitHeight

  onProvidersChanged: ensureSelection()
  onSelectedProviderIdChanged: expandedAccountLimits = false
  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    if (viewMode === "costs") costBackend.ensureLoaded()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() {
      if (resetBackend.active) resetForm.focusFirst()
      else if (root.configuring) activeSettingsForm.focusFirst()
      else keyCatcher.forceActiveFocus()
    })
  } else {
    navigation.closeProviderMenu()
    if (costsView) costsView.closeMenu()
    if (configuring) viewMode = settingsReturnView
  }

  onViewModeChanged: {
    navigation.closeProviderMenu()
    if (costsView) costsView.closeMenu()
    if (viewMode !== "settings") configForm.discardKey()
    if (viewMode !== "cost-settings") costConfigForm.discardKey()
    if (viewMode === "costs") costBackend.ensureLoaded()
    if (panelFlick) panelFlick.contentY = 0
  }

  UsageBackend {
    id: backend
    settings: root.settings
    onRefreshed: activityBackend.refresh()
  }

  UsageActivityBackend {
    id: activityBackend
    usageBackend: backend
    settings: root.settings
  }

  ResetBackend {
    id: resetBackend
    usageBackend: backend
    onFinished: backend.refresh()
    onStateChanged: {
      if (panelFlick) panelFlick.contentY = 0
      Qt.callLater(function() {
        if (resetBackend.active) resetForm.focusFirst()
        else keyCatcher.forceActiveFocus()
      })
    }
  }

  CostBackend {
    id: costBackend
    settings: root.settings
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.nextProvider(); return "ok" }
    function limits(): string { root.showLimits(); return "ok" }
    function costs(): string { root.showCosts(); return "ok" }
    function configureCosts(): string { root.showCostSettings(); return "ok" }
    function configure(): string { root.showSettings(); return "ok" }
  }

  Ui.BarIconButton {
    id: iconButton
    anchors.fill: parent
    visible: !root.percentageMode
    bar: root.bar
    text: "󱚣"
    active: root.alarming
    tooltipText: root.provider ? "Model usage · " + root.provider.name
      + (root.proxyMode ? "\n" + root.lastAccountTooltip(root.lastAccount(root.provider)) : "") : "Model usage"
    onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
  }

  Item {
    id: percentageGroup
    anchors.fill: parent
    visible: root.percentageMode
    implicitWidth: percentageRow.implicitWidth
    implicitHeight: percentageRow.implicitHeight

    Row {
      id: percentageRow
      anchors.centerIn: parent
      spacing: 0

      Repeater {
        model: root.percentageProviders

        delegate: Ui.WidgetButton {
          id: providerChip
          required property var modelData

          readonly property var lastAccount: root.lastAccount(modelData)
          readonly property bool usingPoolQuota: root.proxyMode && !lastAccount.reading
          readonly property var reading: root.proxyMode && lastAccount.reading ? lastAccount.reading : modelData
          readonly property var remainingValue: UsageLogic.minRemaining(reading)
          readonly property string remainingText: remainingValue === null
            ? (root.proxyMode ? "—" : "") : Math.round(remainingValue) + "%"
          readonly property string severity: UsageLogic.severity(
            reading, root.warningThreshold, root.criticalThreshold)
          readonly property bool stressed: severity === "warning" || severity === "critical"
          readonly property color contentColor: active && useActiveColor
            ? activeColor : foreground

          bar: root.bar
          text: ""
          labelVisible: false
          hasVisualContent: true
          fixedWidth: providerChipContent.implicitWidth + Style.space(10)
          active: stressed
          horizontalMargin: 0
          tooltipText: String(modelData.name || modelData.id)
            + (remainingValue === null ? " usage unavailable"
              : " usage · " + Math.round(remainingValue) + "% remaining")
            + (root.proxyMode ? "\n" + root.lastAccountTooltip(lastAccount) : "")
            + (usingPoolQuota ? "\nQuota shown: account with the most remaining capacity." : "")
          onPressed: function(buttonCode) {
            root.handleProviderChipPress(String(providerChip.modelData.id), buttonCode)
          }

          Row {
            id: providerChipContent
            anchors.centerIn: parent
            spacing: Style.spacing.sm

            Item {
              id: providerMark
              y: Math.round((parent.height - height) / 2)
              width: Style.space(providerChip.modelData.id === "codex" ? 13 : 12)
              height: width

              Image {
                id: providerMarkImage
                anchors.fill: parent
                source: root.barIconUrl(providerChip.modelData)
                sourceSize.width: providerMark.width * 2
                sourceSize.height: providerMark.height * 2
                fillMode: Image.PreserveAspectFit
                visible: false
                layer.enabled: true
              }

              MultiEffect {
                anchors.fill: providerMarkImage
                source: providerMarkImage
                visible: providerMarkImage.status === Image.Ready
                colorization: 1.0
                colorizationColor: providerChip.contentColor
              }

              Text {
                anchors.centerIn: parent
                visible: providerMarkImage.status !== Image.Ready
                text: UsageLogic.providerMark(String(providerChip.modelData.id))
                color: providerChip.contentColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Text {
              objectName: "barAccountRemaining"
              y: Math.round((parent.height - height) / 2)
              text: providerChip.remainingText
              color: providerChip.contentColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.weight: Font.Medium
            }
          }
        }
      }
    }
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: root.percentageMode ? percentageGroup : iconButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: resetBackend.active ? resetForm : root.configuring ? root.activeSettingsForm : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(resetBackend.active ? resetForm.implicitHeight
      : contentColumn.implicitHeight + (root.configuring ? settingsActions.implicitHeight + Style.spacing.lg : 0))

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.configuring || resetBackend.active || navigation.menuOpen || costsView.menuOpen

      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.viewMode === "limits" && root.providers.length > 1) {
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0) {
          var target = panelFlick.contentY + dy * Style.space(56)
          panelFlick.contentY = root.clamp(target, 0,
            Math.max(0, panelFlick.contentHeight - panelFlick.height))
        }
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refreshNow()
        else if (text === "c" || text === "C") root.showCosts()
        else if (text === "u" || text === "U") root.showLimits()
        else if (text === "p" || text === "P") navigation.openProviderMenu()
        else if (root.viewMode === "costs" && (text === "m" || text === "M")) costsView.openMetricMenu()
        else if (root.viewMode === "costs" && (text === "d" || text === "D")) costsView.tokenDetailsExpanded = !costsView.tokenDetailsExpanded
        else if (root.viewMode === "costs" && (text === "b" || text === "B")) costsView.modelsExpanded = !costsView.modelsExpanded
        else if (text === "s" || text === "S") root.showSettings()
      }

      SettingsActions {
        id: settingsActions
        objectName: "settingsActions"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.configuring && !resetBackend.active
        foreground: root.foreground
        urgent: root.urgent
        fontFamily: root.fontFamily
        errorText: root.configuring ? root.activeSettingsForm.errorText : ""
        saving: root.configuring && root.activeSettingsForm.saving
        onSaveRequested: root.activeSettingsForm.submit()
        onCancelRequested: root.leaveSettings()
      }

      // Expanded sections and new delegates must be laid out before their
      // coordinates can be used to scroll the focused field into view.
      Timer {
        id: settingsRevealTimer
        property var item: null
        interval: 0
        onTriggered: {
          if (!root.configuring || !root.opened || !item || !item.visible) return
          for (var ancestor = item.parent; ancestor && ancestor !== panelFlick; ancestor = ancestor.parent)
            if (ancestor.forceLayout) ancestor.forceLayout()
          var point = item.mapToItem(panelFlick.contentItem, 0, 0)
          var bottom = point.y + item.height + Style.spacing.md
          var target = panelFlick.contentY
          if (point.y < target) target = point.y
          else if (bottom > target + panelFlick.height) target = bottom - panelFlick.height
          panelFlick.contentY = root.clamp(target, 0, Math.max(0, panelFlick.contentHeight - panelFlick.height))
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        anchors.bottomMargin: settingsActions.visible ? settingsActions.implicitHeight + Style.spacing.lg : 0
        contentWidth: width
        contentHeight: resetBackend.active ? resetForm.implicitHeight : contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ResetConfirmation {
          id: resetForm
          width: panelFlick.width
          visible: resetBackend.active
          backend: resetBackend
          foreground: root.foreground
          background: root.surface
          fontFamily: root.fontFamily
          onCloseRequested: {
            if (resetBackend.state === "sending" || resetBackend.state === "uncertain") root.close()
            else resetBackend.cancel()
          }
        }

        Column {
          id: contentColumn
          visible: !resetBackend.active
          width: panelFlick.width
          spacing: Style.spacing.xxl

          Column {
            visible: !root.configuring
            width: parent.width
            spacing: Style.spacing.md

            Item {
              width: parent.width
              implicitHeight: Math.max(panelTitle.implicitHeight, headerActions.implicitHeight)

              Text {
                id: panelTitle
                anchors.left: parent.left
                anchors.right: headerActions.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                text: "Model Usage"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Row {
                id: headerActions
                anchors.right: parent.right
                spacing: Style.spacing.xs

                Ui.PanelActionButton {
                  objectName: root.viewMode === "costs" ? "costSettingsButton" : "usageSettingsButton"
                  iconText: "󰒓"
                  tooltipText: root.viewMode === "costs" ? "Cost sources and prices" : "Model Usage settings"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  onClicked: root.viewMode === "costs" ? root.showCostSettings() : root.showSettings()
                }

                Ui.PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: root.viewMode === "costs" ? "Refresh estimated costs" : "Refresh usage"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  enabled: !(root.viewMode === "costs" ? costBackend.loading : backend.loading)
                  onClicked: root.refreshNow()
                }
              }
            }

            UsageNavigation {
              id: navigation
              width: parent.width
              viewMode: root.viewMode
              viewOptions: root.viewOptions
              providerOptions: root.providerOptions
              providerId: root.selectedProviderId
              foreground: root.foreground
              surface: root.surface
              fontFamily: root.fontFamily
              onViewRequested: function(value) { root.viewMode = value }
              onProviderRequested: function(value) { root.selectProviderId(value) }
              onMenuClosed: Qt.callLater(function() {
                if (root.opened && !root.configuring && !resetBackend.active)
                  keyCatcher.forceActiveFocus()
              })
            }

            Text {
              width: parent.width
              text: {
                if (root.viewMode === "costs")
                  return costBackend.loading ? "Loading session history…" : ""
                var context = root.accountOverview
                  ? root.proxyAccounts.length + " connected accounts" : root.heroMeta(root.provider)
                if (root.providers.length === 1 && root.provider)
                  context = root.provider.name + (context ? " · " + context : "")
                return context + (backend.loading ? (context ? " · " : "") + "Refreshing…" : "")
              }
              visible: text !== ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          UsageSettings {
            id: configForm
            visible: root.viewMode === "settings"
            width: parent.width
            foreground: root.foreground
            urgent: root.urgent
            surface: root.surface
            fontFamily: root.fontFamily
            accountDetails: root.accountTooltip(root.provider)
            proxyProviders: root.proxyMode ? backend.providers : []
            onSaveRequested: function(values) { root.saveSettings(values) }
            onCancelRequested: root.leaveSettings()
            onRevealRequested: function(item) {
              settingsRevealTimer.item = item
              settingsRevealTimer.restart()
            }
          }
          CostSettings {
            id: costConfigForm
            sources: costBackend.payload ? UsageLogic.listOrEmpty(costBackend.payload.sources) : []
            visible: root.viewMode === "cost-settings"
            width: parent.width
            foreground: root.foreground
            urgent: root.urgent
            surface: root.surface
            fontFamily: root.fontFamily
            onSaveRequested: function(values) { root.saveSettings(values) }
            onCancelRequested: root.leaveSettings()
            onRevealRequested: function(item) {
              settingsRevealTimer.item = item
              settingsRevealTimer.restart()
            }
          }

          Column {
            id: accountOverviewSection
            visible: root.viewMode === "limits" && root.accountOverview
            width: parent.width
            spacing: Style.spacing.lg

            Repeater {
              id: accountRepeater
              model: root.proxyAccounts
              ProxyAccountCard {
                required property var modelData
                required property int index
                width: accountOverviewSection.width
                account: modelData
                accountNumber: index + 1
              }
            }

            Ui.Button {
              text: "Additional limits " + (root.expandedAccountLimits ? "▴" : "▾")
              focusable: true
              horizontalPadding: Style.spacing.sm
              Accessible.name: root.expandedAccountLimits ? "Hide additional limits" : "Show additional limits"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.expandedAccountLimits = !root.expandedAccountLimits
            }
          }

          Text {
            visible: root.viewMode === "limits" && root.providers.length === 0
            width: parent.width
            topPadding: Style.spacing.huge
            bottomPadding: Style.spacing.huge
            text: backend.loading
              ? "Loading AI subscription usage…"
              : root.proxyMode ? "No enabled managed accounts found. Check the accounts configured in CLIProxyAPI."
              : "No connected providers found. Enable a provider in the widget settings and sign in to its CLI."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Ui.BorderSurface {
            id: errorCard
            visible: root.viewMode === "limits" && !root.accountOverview && !!root.provider && root.provider.status === "error"
            width: parent.width
            implicitHeight: errorColumn.implicitHeight + errorCard.contentTopInset + errorCard.contentBottomInset
            color: root.alpha(root.urgent, 0.09)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.4), Style.spacing.hairline)
            padding: Style.spacing.xxl
            radius: root.usageCardRadius

            Column {
              id: errorColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.leftMargin: errorCard.contentLeftInset
              anchors.rightMargin: errorCard.contentRightInset
              anchors.topMargin: errorCard.contentTopInset
              spacing: Style.spacing.labelGap

              Text {
                width: parent.width
                text: UsageLogic.errorTitle(root.provider)
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: root.errorBody(root.provider)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
              }
            }
          }

          Text {
            visible: root.viewMode === "limits" && !root.accountOverview && !!root.provider && root.provider.status !== "error"
              && String(root.provider.notice || "") !== ""
            width: parent.width
            text: root.provider ? String(root.provider.notice || "") : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Ui.PanelSeparator {
            visible: root.viewMode === "limits" && (limitsSection.visible || creditsSection.visible)
            foreground: root.foreground
          }

          Column {
            id: limitsSection
            visible: root.viewMode === "limits" && !root.accountOverview && !!root.provider && root.provider.status === "ok"
              && UsageLogic.isListLike(root.provider.windows) && root.provider.windows.length > 0
            width: parent.width
            spacing: Style.spacing.lg

            Ui.PanelSectionHeader {
              text: "USAGE LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.provider ? UsageLogic.listOrEmpty(root.provider.windows) : []

              LimitCard {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          Column {
            id: creditsSection
            visible: root.viewMode === "limits" && !root.accountOverview && !!root.provider
              && root.provider.status === "ok" && !!root.provider.credits
            width: parent.width
            spacing: Style.spacing.lg

            Ui.PanelSectionHeader {
              text: root.provider && root.provider.credits
                ? String(root.provider.credits.label || "CREDITS").toUpperCase() : "CREDITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CreditsCard {
              width: parent.width
              credits: root.provider ? root.provider.credits : null
            }
          }

          Ui.PanelSeparator {
            visible: root.viewMode === "limits" && history.visible
            foreground: root.foreground
          }

          UsageHistory {
            id: history
            visible: root.viewMode === "limits" && !root.accountOverview && !!root.provider && !!root.provider.history
              && ((UsageLogic.isListLike(root.provider.history.h24) && root.provider.history.h24.length > 0)
                || (UsageLogic.isListLike(root.provider.history.d7) && root.provider.history.d7.length > 0))
            width: parent.width
            history: root.provider ? root.provider.history : ({ h24: [], d7: [] })
            mode: root.historyMode
            foreground: root.foreground
            fontFamily: root.fontFamily
            onModeChanged: root.historyMode = mode
          }

          UsageCosts {
            id: costsView
            visible: root.viewMode === "costs"
            width: parent.width
            payload: costBackend.payload
            loading: costBackend.loading
            errorText: costBackend.fetchError
            periodDays: costBackend.periodDays
            foreground: root.foreground
            urgent: root.urgent
            surface: root.surface
            fontFamily: root.fontFamily
            onPeriodRequested: function(days) { costBackend.selectPeriod(days) }
            onMenuClosed: Qt.callLater(function() {
              if (root.opened && !root.configuring && !resetBackend.active)
                keyCatcher.forceActiveFocus()
            })
          }

          Ui.PanelSeparator { visible: !root.configuring; foreground: root.foreground }

          Item {
            visible: !root.configuring
            width: parent.width
            implicitHeight: Math.max(footerLeft.implicitHeight, footerRight.implicitHeight)

            Text {
              id: footerLeft
              HoverHandler { id: footerHover }
              Ui.PanelToolTip {
                visible: footerHover.hovered && root.viewMode === "costs" && costBackend.lastSuccessAt > 0
                text: "Updated " + Qt.formatDateTime(new Date(costBackend.lastSuccessAt), "MMM d, HH:mm:ss")
                  + (costBackend.payload && Number(costBackend.payload.scanDurationMs) > 0
                    ? " · Scan " + costBackend.payload.scanDurationMs + "ms" : "")
                fontFamily: root.fontFamily
              }
              anchors.left: parent.left
              anchors.right: footerRight.left
              anchors.rightMargin: Style.spacing.controlGap
              text: root.footerLeft()
              color: (root.viewMode === "costs" ? costBackend.fetchError : backend.fetchError) !== ""
                ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              id: footerRight
              anchors.right: parent.right
              text: root.footerRight()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  component ProxyAccountCard: Ui.BorderSurface {
    id: accountCard
    objectName: "proxyAccountCard"
    property var account: ({})
    property int accountNumber: 0
    readonly property var windows: UsageLogic.accountWindows(account, root.expandedAccountLimits)
    readonly property bool healthy: account.status === "ok"
    implicitHeight: accountContent.implicitHeight + contentTopInset + contentBottomInset
    color: Style.normalFillFor(root.foreground, Color.accent, root.urgent)
    borderSpec: Border.flat(root.alpha(root.foreground, 0.22), Style.spacing.hairline)
    padding: Style.spacing.xxl
    radius: root.usageCardRadius

    Column {
      id: accountContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: accountCard.contentLeftInset
      anchors.rightMargin: accountCard.contentRightInset
      anchors.topMargin: accountCard.contentTopInset
      spacing: Style.spacing.md

      Item {
        width: parent.width
        implicitHeight: Math.max(accountLogo.height, accountPlan.implicitHeight,
          resetBadge.visible ? resetBadge.implicitHeight : 0)

        Item {
          id: accountLogo
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.font.body * 1.2
          height: width

          Image {
            id: accountLogoImage
            anchors.fill: parent
            source: root.iconUrl(accountCard.account)
            sourceSize.width: accountLogo.width * 2
            sourceSize.height: accountLogo.height * 2
            fillMode: Image.PreserveAspectFit
          }

          Text {
            anchors.centerIn: parent
            visible: accountLogoImage.status !== Image.Ready
            text: UsageLogic.providerMark(accountCard.account.id)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        Text {
          id: accountPlan
          anchors.left: accountLogo.right
          anchors.leftMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - accountLogo.width - Style.spacing.md
            - (resetBadge.visible ? resetBadge.width + Style.spacing.md : 0))
          text: UsageLogic.accountPlanLabel(accountCard.account)
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          verticalAlignment: Text.AlignVCenter
          wrapMode: Text.WordWrap
        }

        Rectangle {
          id: resetBadge
          objectName: "accountResetBadge"
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: resetLabel.text !== ""
          implicitWidth: resetLabel.implicitWidth + Style.spacing.lg * 2
          implicitHeight: resetLabel.implicitHeight + Style.spacing.sm * 2
          radius: height / 2
          color: resetClick.containsMouse && resetClick.enabled || activeFocus ? root.alpha(root.foreground, 0.08) : "transparent"
          border.color: root.alpha(root.foreground, activeFocus ? 0.6 : 0.18)
          activeFocusOnTab: resetClick.enabled
          Accessible.role: Accessible.Button
          Accessible.name: resetLabel.text + ": apply a reset"
          Keys.onReturnPressed: resetClick.activate()
          Keys.onSpacePressed: resetClick.activate()

          MouseArea {
            id: resetClick
            objectName: "accountResetAction"
            anchors.fill: parent
            enabled: root.proxyMode && accountCard.account.status === "ok"
              && Number(accountCard.account.credits && accountCard.account.credits.resetCreditsAvailable) > 0
              && !resetBackend.active && !resetBackend.busy
            hoverEnabled: true
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            function activate() {
              if (enabled) resetBackend.begin(accountCard.account,
                root.accountDisplayName(accountCard.account, accountCard.accountNumber))
            }
            onClicked: activate()
          }

          ToolTip.visible: resetClick.containsMouse
          ToolTip.text: resetClick.enabled ? "Apply a banked reset to this account" : "No reset available"

          Text {
            id: resetLabel
            objectName: "accountResetLabel"
            anchors.centerIn: parent
            text: UsageLogic.accountResetLabel(accountCard.account)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
      Text {
        width: parent.width
        text: root.accountDisplayName(accountCard.account, accountCard.accountNumber)
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }

      Repeater {
        model: accountCard.healthy ? accountCard.windows : []
        Column {
          id: accountWindow
          required property var modelData
          objectName: "proxyAccountWindow"
          readonly property bool known: modelData.remaining !== null && modelData.remaining !== undefined
            && isFinite(Number(modelData.remaining))
          readonly property bool stressed: root.windowSeverity(modelData) === "warning" || root.windowSeverity(modelData) === "critical"
          width: accountContent.width
          spacing: Style.spacing.sm
          Row {
            width: parent.width
            Text {
              width: parent.width - accountPercent.implicitWidth
              text: String(accountWindow.modelData.label || "Usage limit")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Text {
              id: accountPercent
              text: accountWindow.known ? Math.round(Number(accountWindow.modelData.remaining)) + "% left" : "—"
              color: accountWindow.stressed ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }
          BlockMeter {
            visible: accountWindow.known
            width: parent.width
            value: accountWindow.known ? Number(accountWindow.modelData.remaining) / 100 : 0
            fillColor: accountWindow.stressed ? root.urgent : root.foreground
            trackColor: root.alpha(root.foreground, 0.14)
          }
          Text {
            width: parent.width
            visible: text !== ""
            text: root.resetText(accountWindow.modelData)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      Text {
        width: parent.width
        visible: text !== ""
        text: accountCard.account.status === "error" ? root.errorBody(accountCard.account)
          : accountCard.account.stale || !accountCard.healthy ? String(accountCard.account.notice || "Quota unavailable")
          : accountCard.windows.length === 0 ? "No subscription limits reported." : ""
        textFormat: Text.PlainText
        color: accountCard.account.status === "error" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  component LimitCard: Ui.BorderSurface {
    id: limitCard
    property var window: null
    readonly property string severity: root.windowSeverity(window)
    readonly property bool stressed: severity === "warning" || severity === "critical"

    implicitHeight: limitContent.implicitHeight + contentTopInset + contentBottomInset
    color: severity === "critical"
      ? root.alpha(root.urgent, 0.09)
      : Style.normalFillFor(root.foreground, Color.accent, root.urgent)
    borderSpec: stressed
      ? Border.flat(root.alpha(root.urgent, severity === "critical" ? 0.45 : 0.28), Style.spacing.hairline)
      : Border.controlSpec("normal", root.foreground, Color.accent, root.urgent)
    padding: Style.spacing.xxl
    radius: root.usageCardRadius

    Column {
      id: limitContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: limitCard.contentLeftInset
      anchors.rightMargin: limitCard.contentRightInset
      anchors.topMargin: limitCard.contentTopInset
      spacing: Style.spacing.md

      Item {
        width: parent.width
        implicitHeight: Math.max(limitLabel.implicitHeight, limitPercent.implicitHeight)

        Text {
          id: limitLabel
          anchors.left: parent.left
          anchors.right: limitPercent.left
          anchors.rightMargin: Style.spacing.controlGap
          anchors.verticalCenter: parent.verticalCenter
          text: limitCard.window ? String(limitCard.window.label || "Usage limit") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          id: limitPercent
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: limitCard.window && limitCard.window.remaining !== null && limitCard.window.remaining !== undefined && isFinite(Number(limitCard.window.remaining))
            ? Math.round(Number(limitCard.window.remaining)) + "% left" : "—"
          color: limitCard.stressed ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: limitCard.stressed
        }
      }

      BlockMeter {
        visible: !!limitCard.window && limitCard.window.remaining !== null && limitCard.window.remaining !== undefined
        width: parent.width
        value: limitCard.window ? Number(limitCard.window.remaining) / 100 : 0
        fillColor: limitCard.stressed ? root.urgent : root.foreground
        trackColor: root.alpha(root.foreground, 0.14)
      }

      Text {
        visible: text !== ""
        width: parent.width
        text: root.resetText(limitCard.window)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        visible: text !== ""
        width: parent.width
        text: limitCard.window ? String(limitCard.window.detail || "") : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component CreditsCard: Ui.BorderSurface {
    id: creditsCard
    property var credits: null
    readonly property bool hasMeter: !!credits
      && credits.used !== null && credits.used !== undefined
      && credits.limit !== null && credits.limit !== undefined
      && Number(credits.limit) > 0

    implicitHeight: creditsContent.implicitHeight + contentTopInset + contentBottomInset
    color: Style.normalFillFor(root.foreground, Color.accent, root.urgent)
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent, root.urgent)
    padding: Style.spacing.xxl
    radius: root.usageCardRadius

    Column {
      id: creditsContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: creditsCard.contentLeftInset
      anchors.rightMargin: creditsCard.contentRightInset
      anchors.topMargin: creditsCard.contentTopInset
      spacing: Style.spacing.md

      Text {
        width: parent.width
        text: root.creditsPrimary(creditsCard.credits)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        visible: creditsCard.hasMeter
        width: parent.width
        text: creditsCard.hasMeter
          ? "MONTHLY ALLOWANCE · "
            + Math.round(Number(creditsCard.credits.used) / Number(creditsCard.credits.limit) * 100)
            + "% USED"
          : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.capitalization: Font.AllUppercase
        elide: Text.ElideRight
      }

      BlockMeter {
        visible: creditsCard.hasMeter
        width: parent.width
        value: creditsCard.hasMeter
          ? Number(creditsCard.credits.used) / Number(creditsCard.credits.limit) : 0
        fillColor: root.foreground
        trackColor: root.alpha(root.foreground, 0.14)
      }

      Text {
        visible: text !== ""
        width: parent.width
        text: root.creditsDetail(creditsCard.credits)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
