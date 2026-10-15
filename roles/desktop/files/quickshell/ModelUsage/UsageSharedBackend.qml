import QtQuick
import "UsageLogic.js" as UsageLogic

// A panel owns a subscription, while the engine owns the request channel.
// Destroying or moving the first bar cannot invalidate another bar's context.
Item {
  id: root
  visible: false
  property var settings: ({})
  property bool automaticRefreshEnabled: true
  property bool acquiredActive: false
  property string scriptPath: localPath(Qt.resolvedUrl("scripts/usage-fetch.py"))
  property var connection: null
  property string acquiredKey: ""
  property bool ready: false
  readonly property string connectionId: JSON.stringify([usageSource, cliproxyUrl, cliproxyKeyFile])
  readonly property string usageSource: settings.usageSource === "cliproxy" ? "cliproxy" : "direct"
  readonly property string cliproxyUrl: String(settings.cliproxyUrl || "http://127.0.0.1:8317")
  readonly property string cliproxyKeyFile: String(settings.cliproxyKeyFile || "")
  readonly property var enabledProviderIds: ["claude", "codex", "kimi"].filter(function(id) {
    return !UsageLogic.isListLike(root.settings.enabledProviders) || UsageLogic.contains(root.settings.enabledProviders, id)
  })
  readonly property int refreshIntervalSec: Math.max(60, Math.min(3600,
    Math.round(Number(settings.refreshIntervalSec || 900)) || 900))
  readonly property string key: JSON.stringify([connectionId, enabledProviderIds, refreshIntervalSec, scriptPath])
  readonly property var payload: connection ? connection.payload : ({ schemaVersion: 1, providers: [] })
  readonly property var providers: connection ? connection.providers : []
  readonly property string proxyImplementation: connection ? connection.proxyImplementation : ""
  readonly property bool loading: connection ? connection.loading : false
  readonly property string fetchError: connection ? connection.fetchError : ""
  readonly property double lastSuccessAt: connection ? connection.lastSuccessAt : 0
  readonly property double nextRefreshAt: connection ? connection.nextRefreshAt : 0
  signal refreshed(bool manual)

  function localPath(url) {
    var value = String(url || "").replace(/^file:\/\//, "")
    try { return decodeURIComponent(value) } catch (e) { return value }
  }
  function refresh() { if (connection) connection.refresh() }
  function sync() {
    if (!ready || key === acquiredKey) return
    connection = null
    if (acquiredKey !== "") UsageLogic.releaseBackend("UsageBackend", acquiredKey, acquiredActive)
    acquiredKey = key
    acquiredActive = automaticRefreshEnabled
    connection = UsageLogic.acquireBackend("UsageBackend", key, {
      settings: settings, automaticRefreshEnabled: acquiredActive, scriptPath: scriptPath
    })
  }
  onKeyChanged: if (ready) sync()
  onAutomaticRefreshEnabledChanged: if (connection) {
    UsageLogic.updateBackendActivity("UsageBackend", acquiredKey, acquiredActive, automaticRefreshEnabled)
    acquiredActive = automaticRefreshEnabled
  }
  Component.onCompleted: { ready = true; sync() }
  Component.onDestruction: {
    ready = false
    connection = null
    if (acquiredKey !== "") UsageLogic.releaseBackend("UsageBackend", acquiredKey, acquiredActive)
  }
  Connections {
    target: root.connection
    function onRefreshed(manual) { root.refreshed(manual) }
  }
}
