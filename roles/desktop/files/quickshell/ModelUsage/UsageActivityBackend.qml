import QtQuick
import Quickshell.Io
import "UsageLogic.js" as UsageLogic

// Go/Keeper retains polling; Rust shares a persistent cached activity stream.
Item {
  id: root
  visible: false
  required property var usageBackend
  property var settings: ({})
  property var legacyProviders: []
  readonly property var providers: useLive ? (liveConnection ? liveConnection.providers : []) : legacyProviders
  property string legacyError: ""
  readonly property string fetchError: useLive ? (liveState === "live" ? "" : liveNotice) : legacyError
  property double legacySuccessAt: 0
  readonly property double lastSuccessAt: useLive ? (liveConnection ? liveConnection.lastSuccessAt : 0) : legacySuccessAt
  property bool pendingRefresh: false
  property bool launchPending: false
  property string scriptPath: usageBackend.localPath(Qt.resolvedUrl("scripts/proxy-activity.py"))
  readonly property string keeperUrl: String(settings.costKeeperUrl || "")
  readonly property string passwordFile: String(settings.costKeeperPasswordFile || "")
  readonly property bool rustProxy: usageBackend.proxyImplementation === "rust"
  readonly property bool trackingEnabled: usageBackend.usageSource === "cliproxy" && (rustProxy || keeperUrl.trim() !== "")
  readonly property bool useLive: trackingEnabled && rustProxy && settings.liveAccountActivity !== false
  property string liveScriptPath: usageBackend.localPath(Qt.resolvedUrl("scripts/proxy-live.py"))
  property var liveConnection: null
  property string liveKey: ""
  property bool ready: false
  readonly property string liveState: useLive ? (liveConnection ? liveConnection.state : "unavailable") : "off"
  readonly property var liveAccounts: useLive && liveConnection ? liveConnection.accounts : []
  readonly property string liveNotice: useLive ? (liveConnection ? liveConnection.message : "Live activity unavailable.") : ""
  readonly property string connectionId: JSON.stringify([usageBackend.connectionId, usageBackend.proxyImplementation, keeperUrl, passwordFile, useLive, liveScriptPath])

  function syncLive() {
    if (!ready) return
    var key = useLive ? JSON.stringify([usageBackend.cliproxyUrl, usageBackend.cliproxyKeyFile, liveScriptPath]) : ""
    if (key === liveKey) return
    liveConnection = null
    if (liveKey !== "") UsageLogic.releaseLive(liveKey)
    liveKey = key
    if (key !== "") {
      liveConnection = UsageLogic.acquireLive(key, null, { scriptPath: liveScriptPath,
          proxyUrl: usageBackend.cliproxyUrl, keyFile: usageBackend.cliproxyKeyFile })
    }
  }
  Component.onCompleted: { ready = true; syncLive() }
  Component.onDestruction: {
    ready = false
    liveConnection = null
    if (liveKey !== "") UsageLogic.releaseLive(liveKey)
  }
  readonly property string notice: !trackingEnabled
    ? "Configure CPA Usage Keeper in settings to track the last-used account."
    : fetchError !== "" ? fetchError : lastSuccessAt <= 0 ? "Loading account activity…" : ""

  function refresh() {
    if (!trackingEnabled || useLive) return
    if (process.running || launchPending) { pendingRefresh = true; return }
    launchPending = true
    pendingRefresh = false
    var command = ["python3", scriptPath, "--cliproxy-url", usageBackend.cliproxyUrl,
      "--timeout", "10"]
    if (!rustProxy && keeperUrl.trim() !== "") command.push("--keeper-url", keeperUrl)
    if (usageBackend.cliproxyKeyFile !== "") command.push("--cliproxy-key-file", usageBackend.cliproxyKeyFile)
    if (!rustProxy && passwordFile !== "") command.push("--keeper-password-file", passwordFile)
    process.command = command
    process.connectionId = connectionId
    process.running = true
  }

  function settle() {
    launchPending = false
    if (process.connectionId !== connectionId || !trackingEnabled || useLive) {
      pendingRefresh = trackingEnabled && !useLive
    } else {
      var parsed = null
      if (process.exitSeen && process.lastExit === 0 && !process.failed) {
        try { parsed = JSON.parse(process.body) } catch (e) { parsed = null }
      }
      if (!parsed || parsed.schemaVersion !== 1 || !UsageLogic.isListLike(parsed.providers)) {
        legacyError = "Account activity refresh failed."
      } else if (String(parsed.error || "") !== "") {
        legacyError = String(parsed.error)
      } else {
        legacyProviders = parsed.providers
        legacyError = ""
        legacySuccessAt = Date.now()
      }
    }
    if (pendingRefresh) Qt.callLater(function() {
      if (root.pendingRefresh) root.refresh()
    })
  }

  onConnectionIdChanged: {
    syncLive()
    if (useLive && process.running) process.running = false
    legacyProviders = []
    legacyError = ""
    legacySuccessAt = 0
    pendingRefresh = false
    Qt.callLater(refresh)
  }

  Process {
    id: process
    property string connectionId: ""
    property string body: ""
    property bool exitSeen: false
    property int lastExit: 0
    property bool failed: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) {
        if (process.failed) return
        if (process.body.length + data.length > 65536) {
          process.failed = true
          process.body = ""
          process.running = false
        } else process.body += data
      }
    }
    stderr: SplitParser { splitMarker: "" }
    onExited: function(exitCode) { exitSeen = true; lastExit = exitCode }
    onRunningChanged: {
      if (running) {
        root.launchPending = false
        body = ""
        exitSeen = false
        failed = false
        watchdog.restart()
      } else {
        watchdog.stop()
        root.settle()
      }
    }
  }
  Timer {
    id: watchdog
    interval: 15000
    onTriggered: { process.failed = true; process.running = false }
  }
  Timer {
    interval: 15000
    running: root.trackingEnabled && !root.useLive
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
