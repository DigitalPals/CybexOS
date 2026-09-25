import QtQuick
import Quickshell.Io
import "UsageLogic.js" as UsageLogic

// On-demand process boundary for transcript scanning and price estimation.
// Quota polling remains independent in UsageBackend.qml.
Item {
  id: root
  visible: false

  property var settings: ({})
  property int periodDays: 30
  property var payload: ({
    schemaVersion: 1,
    generatedAt: "",
    pricing: ({ status: "unavailable", source: "", fetchedAt: null, knownModels: 0, message: "" }),
    coverage: [],
    period: ({ days: 30, resolution: "day", since: "", until: "", label: "Past 30 days" }),
    totals: ({ costUsd: 0, totalTokens: 0, records: 0, pricedRecords: 0, sessions: 0 }),
    providers: [],
    models: [],
    periods: []
  })
  property bool loading: false
  property string fetchError: ""
  property double lastSuccessAt: 0
  property double lastAttemptAt: 0
  property bool pendingRefresh: false
  property bool pendingPriceRefresh: false
  property bool launchPending: false
  property bool requested: false

  readonly property var enabledProviderIds: normalizedProviderIds(setting(
    "costLocalProviders", ["claude", "codex"]))
  readonly property string scriptPath: localPath(Qt.resolvedUrl("scripts/cost-fetch.py"))
  readonly property int staleAfterMs: Math.max(60, Math.min(3600,
    Math.round(Number(setting("refreshIntervalSec", 900)) || 900))) * 1000
  readonly property var providers: payload ? UsageLogic.listOrEmpty(payload.providers) : []
  readonly property var periods: payload ? UsageLogic.listOrEmpty(payload.periods) : []
  readonly property string priceOverrides: String(setting("costPriceOverrides", "{}"))
  readonly property string t3Servers: String(setting("costT3Servers", "[]"))
  readonly property string connectionId: JSON.stringify([enabledProviderIds, t3Servers])

  signal refreshed()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function normalizedProviderIds(value) {
    var allowed = ["claude", "codex"]
    var requestedProviders = UsageLogic.isListLike(value) ? value : allowed
    var result = []
    for (var i = 0; i < allowed.length; i++)
      if (UsageLogic.contains(requestedProviders, allowed[i])) result.push(allowed[i])
    return result
  }

  function normalizedPeriod(value) {
    var parsed = Math.round(Number(value))
    return parsed === 1 || parsed === 7 || parsed === 30 ? parsed : 30
  }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (e) { return value }
  }

  function ensureLoaded() {
    requested = true
    // Opening Costs notifies both the view and popup. They share one scan;
    // explicit refreshes and settings changes still queue their own follow-up.
    if (loading) return
    var payloadDays = payload && payload.period ? Number(payload.period.days) : 0
    if (lastSuccessAt <= 0 || payloadDays !== periodDays
        || Date.now() - lastSuccessAt >= staleAfterMs) requestRefresh()
  }

  function selectPeriod(days) {
    var next = normalizedPeriod(days)
    if (next === periodDays && lastSuccessAt > 0) return
    periodDays = next
    requested = true
    requestRefresh()
  }

  function refresh() {
    requested = true
    requestRefresh(true)
  }

  function requestRefresh(forcePrices) {
    pendingPriceRefresh = pendingPriceRefresh || forcePrices === true
    if (fetchProcess.running || launchPending || pendingRefresh) {
      pendingRefresh = true
      return
    }
    startFetch()
  }

  function startFetch() {
    if (fetchProcess.running || launchPending) return
    launchPending = true
    loading = true
    pendingRefresh = false
    lastAttemptAt = Date.now()
    var command = [
      "python3", scriptPath,
      "--providers", enabledProviderIds.join(","),
      "--days", String(periodDays),
      "--timeout", "10",
      "--t3-servers", t3Servers,
      "--price-overrides", priceOverrides
    ]
    if (pendingPriceRefresh) command.push("--refresh-prices")
    pendingPriceRefresh = false
    fetchProcess.command = command
    fetchProcess.connectionId = connectionId
    fetchProcess.running = true
  }

  function settle() {
    launchPending = false
    loading = false
    if (fetchProcess.connectionId !== connectionId) {
      // A response from an old source must never repopulate the new source.
      pendingRefresh = requested
    } else if (fetchProcess.outputTooLarge) {
      fetchError = "Estimated-cost backend returned too much data"
    } else if (fetchProcess.timedOut) {
      fetchError = "Estimated-cost scan timed out"
    } else if (!fetchProcess.exitSeen) {
      fetchError = "Could not start python3 for estimated costs"
    } else if (fetchProcess.lastExit !== 0) {
      fetchError = "Estimated-cost backend exited with status " + fetchProcess.lastExit
    } else {
      var parsed = null
      try { parsed = JSON.parse(fetchProcess.body) } catch (e) { parsed = null }
      if (!parsed || parsed.schemaVersion !== 1 || !UsageLogic.isListLike(parsed.providers)
          || !UsageLogic.isListLike(parsed.models) || !UsageLogic.isListLike(parsed.periods)
          || !parsed.totals || !parsed.period || !parsed.pricing) {
        fetchError = "Estimated-cost backend returned unreadable data"
      } else {
        var backendError = String(parsed.backendError || "")
        if (backendError !== "") {
          fetchError = backendError
        } else {
          payload = parsed
          fetchError = ""
          var generated = new Date(String(parsed.generatedAt || "")).getTime()
          lastSuccessAt = isFinite(generated) ? generated : Date.now()
          refreshed()
        }
      }
    }
    if (pendingRefresh) Qt.callLater(function() {
      if (root.pendingRefresh) root.startFetch()
    })
  }

  onPriceOverridesChanged: if (requested) requestRefresh()
  onConnectionIdChanged: {
    payload = ({ schemaVersion: 1, generatedAt: "", source: "transcripts",
      pricing: {}, coverage: [], totals: {}, providers: [], models: [], periods: [] })
    lastSuccessAt = 0
    fetchError = ""
    if (requested) requestRefresh()
  }

  Process {
    id: fetchProcess
    running: false
    property string body: ""
    property bool exitSeen: false
    property int lastExit: 0
    property bool timedOut: false
    property bool outputTooLarge: false
    property string connectionId: ""
    readonly property int maxBodyChars: 4 * 1024 * 1024

    function appendBody(data) {
      if (outputTooLarge) return
      var chunk = String(data)
      if (body.length + chunk.length > maxBodyChars) {
        body = ""
        outputTooLarge = true
        running = false
        return
      }
      body += chunk
    }

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { fetchProcess.appendBody(data) }
    }
    // Drain diagnostics in arbitrary chunks without retaining them.
    stderr: SplitParser { splitMarker: "" }
    onExited: function(exitCode) {
      fetchProcess.exitSeen = true
      fetchProcess.lastExit = exitCode
    }
    onRunningChanged: {
      if (running) {
        root.launchPending = false
        body = ""
        exitSeen = false
        lastExit = 0
        timedOut = false
        outputTooLarge = false
        root.loading = true
        processTimeout.restart()
      } else {
        processTimeout.stop()
        root.settle()
      }
    }
  }

  Timer {
    id: processTimeout
    interval: 60000
    repeat: false
    onTriggered: {
      fetchProcess.timedOut = true
      fetchProcess.running = false
    }
  }
}
