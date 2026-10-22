import QtQuick
import Quickshell.Io
import "UsageLogic.js" as UsageLogic

Item {
  id: root
  visible: false
  required property string scriptPath
  required property string proxyUrl
  required property string keyFile
  property var providers: []
  property var accounts: []
  property string state: "reconnecting"
  property string message: "Connecting to live account activity…"
  property double lastSuccessAt: 0
  property bool stopped: false

  function unknown() {
    accounts = []
    state = "reconnecting"
    message = "Reconnecting to live account activity…"
  }
  function stop() {
    stopped = true
    restart.stop()
    watchdog.stop()
    process.running = false
    // Let SIGTERM finish before disposing Process (its destructor kills it).
    dispose.restart()
  }
  function start() {
    if (stopped || process.running) return
    var command = ["python3", "-u", scriptPath, "--cliproxy-url", proxyUrl]
    if (keyFile !== "") command.push("--cliproxy-key-file", keyFile)
    process.command = command
    process.body = ""
    process.running = true
    watchdog.restart()
  }
  function receive(data) {
    if (stopped) return
    process.body += data
    if (process.body.length > 1048576) { fail(); return }
    var newline
    while ((newline = process.body.indexOf("\n")) >= 0) {
      var line = process.body.slice(0, newline)
      process.body = process.body.slice(newline + 1)
      var parsed
      try { parsed = JSON.parse(line) } catch (e) { fail(); return }
      if (!UsageLogic.validLivePayload(parsed)) { fail(); return }
      watchdog.restart()
      if (parsed.heartbeat === true) continue
      providers = parsed.providers
      accounts = parsed.accounts
      state = parsed.state
      message = parsed.message
      if (state === "live") lastSuccessAt = Date.now()
    }
  }
  function fail() { unknown(); process.running = false; restart.restart() }
  Component.onCompleted: start()
  Component.onDestruction: stop()

  Process {
    id: process
    property string body: ""
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.receive(data) } }
    stderr: SplitParser { splitMarker: "" }
    onExited: if (root.stopped) { dispose.stop(); Qt.callLater(function() { root.destroy() }) }
    onRunningChanged: if (!running && !root.stopped) {
      root.unknown()
      watchdog.stop()
      restart.restart()
    }
  }
  Timer { id: watchdog; interval: 20000; onTriggered: root.fail() }
  Timer { id: restart; interval: 60000; onTriggered: root.start() }
  Timer { id: dispose; interval: 1000; onTriggered: root.destroy() }
}
