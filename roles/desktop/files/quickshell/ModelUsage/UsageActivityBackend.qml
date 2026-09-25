import QtQuick
import Quickshell.Io
import "UsageLogic.js" as UsageLogic

// Account activity has a short polling interval without repeating quota calls.
Item {
  id: root
  visible: false
  required property var usageBackend
  property var settings: ({})
  property var providers: []
  property string fetchError: ""
  property double lastSuccessAt: 0
  property bool pendingRefresh: false
  property bool launchPending: false
  property string scriptPath: usageBackend.localPath(Qt.resolvedUrl("scripts/proxy-activity.py"))
  readonly property string keeperUrl: String(settings.costKeeperUrl || "")
  readonly property string passwordFile: String(settings.costKeeperPasswordFile || "")
  readonly property bool trackingEnabled: usageBackend.usageSource === "cliproxy" && keeperUrl.trim() !== ""
  readonly property string connectionId: JSON.stringify([usageBackend.connectionId, keeperUrl, passwordFile])
  readonly property string notice: !trackingEnabled
    ? "Configure CPA Usage Keeper in settings to track the last-used account."
    : fetchError !== "" ? fetchError : lastSuccessAt <= 0 ? "Loading account activity…" : ""

  function refresh() {
    if (!trackingEnabled) return
    if (process.running || launchPending) { pendingRefresh = true; return }
    launchPending = true
    pendingRefresh = false
    var command = ["python3", scriptPath, "--cliproxy-url", usageBackend.cliproxyUrl,
      "--keeper-url", keeperUrl, "--timeout", "10"]
    if (usageBackend.cliproxyKeyFile !== "") command.push("--cliproxy-key-file", usageBackend.cliproxyKeyFile)
    if (passwordFile !== "") command.push("--keeper-password-file", passwordFile)
    process.command = command
    process.connectionId = connectionId
    process.running = true
  }

  function settle() {
    launchPending = false
    if (process.connectionId !== connectionId || !trackingEnabled) {
      pendingRefresh = trackingEnabled
    } else {
      var parsed = null
      if (process.exitSeen && process.lastExit === 0 && !process.failed) {
        try { parsed = JSON.parse(process.body) } catch (e) { parsed = null }
      }
      if (!parsed || parsed.schemaVersion !== 1 || !UsageLogic.isListLike(parsed.providers)) {
        fetchError = "Account activity refresh failed."
      } else if (String(parsed.error || "") !== "") {
        fetchError = String(parsed.error)
      } else {
        providers = parsed.providers
        fetchError = ""
        lastSuccessAt = Date.now()
      }
    }
    if (pendingRefresh) Qt.callLater(function() {
      if (root.pendingRefresh) root.refresh()
    })
  }

  onConnectionIdChanged: {
    providers = []
    fetchError = ""
    lastSuccessAt = 0
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
    running: root.trackingEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
