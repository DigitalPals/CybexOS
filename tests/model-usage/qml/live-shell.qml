import QtQuick
import Quickshell

ShellRoot {
  id: root
  property var first: null
  property var second: null
  property var original: null
  property int phase: 0
  property int ticks: 0
  QtObject {
    id: usage
    property string usageSource: "cliproxy"
    property string cliproxyUrl: "http://synthetic.invalid/old"
    property string cliproxyKeyFile: ""
    property string proxyImplementation: "rust"
    readonly property string connectionId: JSON.stringify([usageSource, cliproxyUrl])
    function localPath(url) { return String(url).replace("file://", "") }
  }
  Item { id: host }
  function check(condition, message) {
    if (!condition) { console.error("LIVE TEST FAILED: " + message); Qt.exit(1) }
  }
  Component.onCompleted: {
    var factory = Qt.createComponent(Quickshell.env("MODEL_USAGE_REPO_URL") + "/UsageActivityBackend.qml")
    check(factory.status === Component.Ready, factory.errorString())
    var props = { usageBackend: usage, settings: {}, liveScriptPath: Quickshell.env("MODEL_USAGE_FAKE_LIVE") }
    first = factory.createObject(host, props)
    second = factory.createObject(host, props)
    check(first && second, "create two consumers")
    check(first.liveConnection === second.liveConnection, "consumers share one connection")
    original = second.liveConnection
  }
  Timer {
    interval: 50
    running: true
    repeat: true
    onTriggered: {
      root.ticks++
      root.check(root.ticks < 120, "lifecycle timeout at " + root.phase)
      if (root.phase === 0 && root.second.liveState === "live") {
        root.check(root.second.liveAccounts[0].inFlight === 2, "initial snapshot")
        root.first.destroy()
        root.first = null
        root.phase = 1
      } else if (root.phase === 1 && root.ticks > 8) {
        root.check(root.second.liveConnection === root.original, "first consumer destruction retains observer")
        root.check(root.second.liveState === "live", "observer continues after creator destruction")
        usage.cliproxyUrl = "http://synthetic.invalid/new"
        root.check(root.second.liveAccounts.length === 0, "changed connection clears activity immediately")
        root.phase = 2
      } else if (root.phase === 2 && root.second.liveState === "live") {
        root.check(root.second.liveAccounts[0].inFlight === 1, "old snapshot cannot overwrite changed connection")
        usage.usageSource = "direct"
        root.check(root.second.liveConnection === null && root.second.liveAccounts.length === 0, "last consumer releases observer")
        root.phase = 3
      } else if (root.phase === 3 && root.ticks > 20) {
        root.second.destroy()
        console.log("Live QML contract: passed")
        Qt.quit()
      }
    }
  }
}
