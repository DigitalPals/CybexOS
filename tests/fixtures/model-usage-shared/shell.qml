import QtQuick
import Quickshell

ShellRoot {
  id: root
  property var first: null
  property var second: null
  property var firstActivity: null
  property var secondActivity: null
  property var original: null
  property int phase: 0
  property int ticks: 0
  property int entered: 0
  Item { id: host }
  function check(ok, message) {
    if (!ok) { console.error("SHARED TEST FAILED: " + message); Qt.exit(1) }
  }
  function settings(key) {
    return { usageSource: "cliproxy", cliproxyUrl: "http://127.0.0.1:8317", cliproxyKeyFile: key,
      costKeeperUrl: "http://127.0.0.1:8080", enabledProviders: ["codex"], refreshIntervalSec: 900 }
  }
  Component.onCompleted: {
    var url = Quickshell.env("MODEL_USAGE_REPO_URL")
    var quota = Qt.createComponent(url + "/UsageSharedBackend.qml")
    var activity = Qt.createComponent(url + "/UsageSharedActivityBackend.qml")
    check(quota.status === Component.Ready, quota.errorString())
    check(activity.status === Component.Ready, activity.errorString())
    var props = { settings: settings("old"), automaticRefreshEnabled: false,
      scriptPath: Quickshell.env("MODEL_USAGE_FAKE_REQUEST") }
    first = quota.createObject(host, props)
    second = quota.createObject(host, props)
    check(first && second && first.connection === second.connection, "two outputs share quota")
    firstActivity = activity.createObject(host, { usageBackend: first, settings: settings("old"), scriptPath: props.scriptPath })
    secondActivity = activity.createObject(host, { usageBackend: second, settings: settings("old"), scriptPath: props.scriptPath })
    check(firstActivity && secondActivity && firstActivity.connection === secondActivity.connection, "two outputs share legacy activity")
    first.automaticRefreshEnabled = true
    check(second.connection.automaticRefreshEnabled, "one awake output enables shared quota")
    original = second.connection
  }
  Timer {
    interval: 50
    running: true
    repeat: true
    onTriggered: {
      root.ticks++
      root.check(root.ticks < 180, "timeout at phase " + root.phase)
      if (root.phase === 0 && root.second.lastSuccessAt > 0 && root.secondActivity.lastSuccessAt > 0) {
        root.firstActivity.destroy()
        root.first.destroy()
        root.first = null
        root.phase = 1
        root.entered = root.ticks
      } else if (root.phase === 1 && root.ticks > root.entered + 5) {
        root.check(root.second.connection === root.original, "hot unplug retains quota worker")
        root.check(!root.second.connection.automaticRefreshEnabled, "last awake output removed pauses work")
        root.second.refresh()
        root.phase = 2
      } else if (root.phase === 2 && root.second.payload.attempt >= 2 && root.secondActivity.providers[0].attempt >= 2) {
        root.second.settings = root.settings("new")
        root.check(root.second.connection !== root.original && root.second.lastSuccessAt === 0, "credential change resets connection")
        root.check(!root.second.connection.automaticRefreshEnabled, "offline settings change does not fetch")
        root.second.automaticRefreshEnabled = true
        root.phase = 3
      } else if (root.phase === 3 && root.second.lastSuccessAt > 0 && root.secondActivity.lastSuccessAt > 0) {
        root.secondActivity.destroy()
        root.second.destroy()
        root.phase = 4
        root.entered = root.ticks
      } else if (root.phase === 4 && root.ticks > root.entered + 5) {
        console.log("Shared quota and legacy activity QML lifecycle: passed")
        Qt.quit()
      }
    }
  }
}
