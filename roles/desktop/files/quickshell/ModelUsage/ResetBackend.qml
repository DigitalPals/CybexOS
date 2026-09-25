import QtQuick
import Quickshell.Io
import "UsageLogic.js" as UsageLogic

Item {
  id: root
  visible: false
  required property var usageBackend
  property string scriptPath: usageBackend.localPath(Qt.resolvedUrl("scripts/reset-credit.py"))
  readonly property string connectionId: usageBackend.connectionId
  state: "idle"
  readonly property bool active: state !== "idle"
  readonly property bool busy: process.running
  property string accountId: ""
  property string accountLabel: ""
  property string planLabel: ""
  property var details: ({ credits: [] })
  property int selectedIndex: 0
  property string message: ""
  property double preparedAt: 0
  property int generation: 0
  readonly property var selectedCredit: details.credits && selectedIndex >= 0
    && selectedIndex < details.credits.length ? details.credits[selectedIndex] : null
  signal finished()

  function begin(account, label) {
    if (active || busy || usageBackend.usageSource !== "cliproxy" || !account
        || account.id !== "codex" || account.status !== "ok"
        || !(Number(account.credits && account.credits.resetCreditsAvailable) > 0)
        || !account.accountId) return false
    accountId = String(account.accountId)
    accountLabel = label
    planLabel = UsageLogic.accountPlanLabel(account)
    details = ({ credits: [] })
    selectedIndex = 0
    message = ""
    state = "loading"
    launch("prepare")
    return true
  }

  function cancel() {
    // An uncertain submission retains its credit and request ID for a safe retry.
    if (state === "sending" || state === "uncertain") return
    generation++
    state = "idle"
    details = ({ credits: [] })
  }

  function apply() {
    if (busy || (state !== "ready" && state !== "uncertain") || !selectedCredit) return
    if (state === "ready" && (Date.now() - preparedAt > 120000
        || (selectedCredit.expiresAt !== null && selectedCredit.expiresAt * 1000 <= Date.now()))) {
      state = "error"
      message = "This confirmation expired. Close it and click the badge again to refresh the reset details."
      return
    }
    state = "sending"
    message = ""
    launch("consume")
  }

  function launch(action) {
    var command = ["python3", scriptPath, "--action", action, "--account-id", accountId,
      "--cliproxy-url", usageBackend.cliproxyUrl]
    if (usageBackend.cliproxyKeyFile.trim() !== "")
      command.push("--cliproxy-key-file", usageBackend.cliproxyKeyFile)
    if (action === "consume") command.push("--target", details.target,
      "--credit-id", selectedCredit.id, "--request-id", details.requestId)
    process.action = action
    process.generation = generation
    process.body = ""
    process.exitSeen = false
    process.failed = false
    process.command = command
    process.running = true
  }

  function settle() {
    if (process.generation !== generation) return
    var result = null
    try { result = JSON.parse(process.body) } catch (error) {}
    if (process.failed || !process.exitSeen || !result || result.schemaVersion !== 1 || result.ok !== true) {
      state = process.action === "consume" && !(result && result.uncertain === false) ? "uncertain" : "error"
      message = state === "uncertain"
        ? "The reset outcome could not be confirmed. Retry checks the same request without spending another reset."
        : String(result && result.message || "Could not load reset details. Close and try again.")
      if (process.action === "consume") finished()
      return
    }
    if (process.action === "prepare") {
      if (!UsageLogic.isListLike(result.credits) || !result.target || !result.requestId) {
        state = "error"
        message = "The server returned invalid reset details."
        return
      }
      details = result
      selectedIndex = 0
      preparedAt = Date.now()
      state = result.credits.length > 0 ? "ready" : "error"
      if (state === "error") message = "No available Codex resets were found for this account."
    } else {
      var messages = {
        reset: "Banked reset applied. Refreshing account usage…",
        nothing_to_reset: "There is currently nothing to reset on this account.",
        no_credit: "This reset is no longer available. Refreshing account usage…",
        already_redeemed: "This request was already redeemed. Refreshing account usage…"
      }
      state = messages[result.outcome] ? "result" : "uncertain"
      message = messages[result.outcome] || "The server returned an unknown outcome. Retry the same request to check it."
      finished()
    }
  }

  onConnectionIdChanged: {
    generation++
    state = "idle"
    details = ({ credits: [] })
  }

  Process {
    id: process
    property string action: ""
    property int generation: 0
    property string body: ""
    property bool failed: false
    property bool exitSeen: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) {
        if (process.body.length + data.length > 256 * 1024) {
          process.failed = true
          process.running = false
        } else process.body += data
      }
    }
    stderr: SplitParser { splitMarker: "" }
    onExited: function(code) {
      exitSeen = true
      if (code !== 0) failed = true
    }
    onRunningChanged: {
      if (running) timeout.restart()
      else { timeout.stop(); root.settle() }
    }
  }
  Timer {
    id: timeout
    interval: 30000
    onTriggered: { process.failed = true; process.running = false }
  }
}
