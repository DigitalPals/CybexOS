.pragma library

// One observer per connection across bars, monitors and open panels. The
// shared object has no panel parent; the final consumer explicitly stops it.
var liveConnections = ({})

function acquireLive(key, factory, properties) {
  var entry = liveConnections[key]
  if (!entry) {
    // Create in this engine-wide library context, not a consumer's context.
    // A parentless object alone still loses its functions when its creator dies.
    if (!factory) factory = Qt.createComponent("UsageLiveConnection.qml")
    var object = factory.createObject(null, properties)
    if (!object) return null
    entry = { object: object, references: 0 }
    liveConnections[key] = entry
  }
  entry.references++
  return entry.object
}

function releaseLive(key) {
  var entry = liveConnections[key]
  if (!entry) return
  entry.references--
  if (entry.references <= 0) {
    delete liveConnections[key]
    entry.object.stop()
  }
}

function validLivePayload(payload) {
  if (!payload || payload.schemaVersion !== 1) return false
  if (payload.heartbeat === true) return true
  if (!contains(["live", "reconnecting", "unavailable"], payload.state)
      || typeof payload.message !== "string" || payload.message.length > 256
      || !isListLike(payload.providers) || payload.providers.length > 4096
      || !isListLike(payload.accounts) || payload.accounts.length > 4096) return false
  var seen = ({})
  for (var p = 0; p < payload.providers.length; p++) {
    var provider = payload.providers[p]
    if (!provider || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(provider.id)
        || !contains(["ok", "ambiguous"], provider.status)
        || (provider.status === "ok" && !/^[a-f0-9]{16}$/.test(provider.accountId))
        || typeof provider.lastUsedAt !== "number" || !isFinite(provider.lastUsedAt)
        || provider.lastUsedAt <= 0) return false
  }
  for (var i = 0; i < payload.accounts.length; i++) {
    var row = payload.accounts[i]
    if (!row || !/^[a-f0-9]{16}$/.test(row.accountId)
        || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(row.provider)) return false
    if (seen[row.accountId]) return false
    seen[row.accountId] = true
    var counts = [row.inFlight, row.sessions]
    for (var j = 0; j < counts.length; j++)
      if (typeof counts[j] !== "number" || !isFinite(counts[j])
          || Math.floor(counts[j]) !== counts[j] || counts[j] < 0 || counts[j] > 1000000) return false
  }
  return payload.state === "live" || payload.accounts.length === 0
}

function accountLoad(account, activity) {
  if (!account || !activity || activity.liveState !== "live") return null
  var rows = listOrEmpty(activity.liveAccounts)
  for (var i = 0; i < rows.length; i++)
    if (rows[i].accountId === account.accountId && rows[i].provider === account.id) return rows[i]
  return null
}

function sessionBadgeText(load) {
  if (!load) return "Sessions unknown"
  return load.sessions + (load.sessions === 1 ? " session" : " sessions")
}

function sessionDetails(load) {
  if (!load) return "Session counts are unknown until Fusebox reconnects."
  return sessionBadgeText(load) + " assigned to this account recently. Sessions may remain assigned after a request finishes."
}

function proxyName(implementation) {
  if (implementation === "rust") return "Fusebox"
  if (implementation === "go") return "CLIProxyAPI"
  return "Fusebox / CLIProxyAPI"
}

function clamp(value, minimum, maximum) {
  var number = Number(value)
  if (!isFinite(number)) return minimum
  return Math.max(minimum, Math.min(maximum, number))
}

function isListLike(value) {
  if (!value || typeof value !== "object" || value.length === undefined) return false
  var length = Number(value.length)
  return isFinite(length) && length >= 0 && Math.floor(length) === length
}

function listOrEmpty(value) {
  return isListLike(value) ? value : []
}

function firstItems(value, limit) {
  var source = listOrEmpty(value)
  var count = Math.max(0, Math.min(Number(source.length), Math.floor(Number(limit) || 0)))
  var result = []
  for (var i = 0; i < count; i++) result.push(source[i])
  return result
}

function contains(value, needle) {
  var source = listOrEmpty(value)
  for (var i = 0; i < source.length; i++) {
    if (source[i] === needle) return true
  }
  return false
}

function minRemaining(provider) {
  if (!provider || provider.status !== "ok") return null
  // Repeater delegates expose nested JSON arrays as QML list-like objects on
  // some Quickshell builds. They still have length/index access, but fail
  // Array.isArray(), so do not reject them solely on that basis.
  var windows = provider.windows
  if (!isListLike(windows) || Number(windows.length) <= 0) return null
  var remaining = 101
  for (var i = 0; i < Number(windows.length); i++) {
    var row = windows[i]
    var raw = row ? row.remaining : null
    if (raw === null || raw === undefined || raw === "") continue
    var value = Number(raw)
    if (isFinite(value)) remaining = Math.min(remaining, value)
  }
  return remaining <= 100 ? clamp(remaining, 0, 100) : null
}

function severity(provider, warningThreshold, criticalThreshold) {
  var remaining = minRemaining(provider)
  if (remaining === null) return provider && provider.status === "error" ? "error" : "none"
  var critical = clamp(criticalThreshold, 0, 100)
  var warning = Math.max(critical, clamp(warningThreshold, 0, 100))
  if (remaining <= critical) return "critical"
  if (remaining <= warning) return "warning"
  return "ok"
}

function meaningfulProviders(providers) {
  var result = []
  var list = listOrEmpty(providers)
  for (var i = 0; i < list.length; i++) {
    if (minRemaining(list[i]) !== null) result.push(list[i])
  }
  return result
}

function availableProviders(providers) {
  function available(reading) {
    return reading && reading.status !== "disabled" && reading.errorKind !== "no_credentials"
  }
  var result = []
  var list = listOrEmpty(providers)
  for (var i = 0; i < list.length; i++) {
    var provider = list[i]
    // Keep connection-level errors visible so the user can fix proxy setup.
    if (provider && provider.id === "cliproxy") {
      result.push(provider)
      continue
    }
    var accounts = listOrEmpty(provider && provider.accounts)
    if (accounts.length > 0) {
      for (var j = 0; j < accounts.length; j++) {
        if (available(accounts[j])) {
          result.push(provider)
          break
        }
      }
    } else if (available(provider)) {
      result.push(provider)
    }
  }
  return result
}

function selectedProviders(providers, ids) {
  var result = []
  var list = listOrEmpty(providers)
  for (var i = 0; i < list.length; i++) {
    if (list[i] && contains(ids, list[i].id)) result.push(list[i])
  }
  return result
}

function lastUsedAccount(provider, activityProviders, hideEmails) {
  var activity = listOrEmpty(activityProviders)
  var last = null
  for (var i = 0; i < activity.length; i++)
    if (provider && activity[i].id === provider.id) last = activity[i]
  if (!last) return { label: "Unknown", reading: null, lastUsedAt: 0 }
  if (last.status === "ambiguous")
    return { label: "Multiple accounts", reading: null, lastUsedAt: last.lastUsedAt }
  var accounts = listOrEmpty(provider && provider.accounts)
  for (var j = 0; j < accounts.length; j++) {
    if (last.status === "ok" && accounts[j].accountId === last.accountId)
      return { label: hideEmails ? "Account " + (j + 1) : String(accounts[j].account || "Account " + (j + 1)),
        reading: accounts[j], lastUsedAt: last.lastUsedAt }
  }
  // Account inventory and activity refresh independently. Never substitute the
  // pool's best-quota account when a new/deleted account cannot be matched.
  return { label: "Unknown", reading: null, lastUsedAt: last.lastUsedAt }
}

function providerMark(providerId) {
  if (providerId === "claude") return "C"
  if (providerId === "codex") return "O"
  if (providerId === "kimi") return "K"
  return String(providerId || "?").charAt(0).toUpperCase()
}

function accountPlanLabel(account) {
  if (!account) return ""
  var plan = String(account.planType || account.plan || "")
  var normalized = plan.toLowerCase().replace(/^chatgpt\s+/, "").replace(/[-_ ]/g, "")
  if (account.id === "codex") {
    if (normalized === "pro" || normalized === "pro20x") return "Codex Pro · 20×"
    if (normalized === "prolite" || normalized === "pro5x") return "Codex Pro · 5×"
  }
  return String(account.plan || account.name || account.id || "Account")
}

function accountResetLabel(account) {
  if (!account || account.id !== "codex" || account.status !== "ok") return ""
  var count = account.credits && account.credits.resetCreditsAvailable
  if (typeof count !== "number" || !isFinite(count) || count < 0 || Math.floor(count) !== count) return ""
  return count + " banked reset" + (count === 1 ? "" : "s")
}

function accountWindows(account, expanded) {
  var rows = listOrEmpty(account && account.windows)
  if (expanded) return rows
  var overall = [], weekly = [], monthly = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var label = String(row.label || "")
    var seconds = Number(row.windowSeconds)
    if (/^weekly(?: limit)?$/i.test(label)) overall.push(row)
    if (seconds === 604800 || /weekly/i.test(label)) weekly.push(row)
    if (/^monthly(?: limit)?$/i.test(label)) monthly.push(row)
  }
  if (overall.length) return overall
  if (weekly.length) return weekly
  if (monthly.length) return monthly
  // Plans without a weekly/monthly allowance still show their real main window.
  return firstItems(rows, 1)
}

function errorTitle(provider) {
  if (!provider) return "Provider unavailable"
  var name = String(provider.name || provider.id || "Provider")
  switch (provider.errorKind) {
  case "config": return proxyName(provider.proxyImplementation) + " configuration required"
  case "no_credentials": return name + " sign-in required"
  case "expired": return name + " sign-in expired"
  case "rate_limited": return name + " is rate limited"
  case "timeout": return name + " timed out"
  case "cli_unavailable": return name + " CLI unavailable"
  default: return name + " usage unavailable"
  }
}

function preserveProxyReadings(previous, next) {
  if (!previous || previous.source !== "cliproxy") return next
  if (previous.proxyImplementation && next.proxyImplementation
      && previous.proxyImplementation !== next.proxyImplementation) return next
  if (!next.proxyImplementation && previous.proxyImplementation)
    next.proxyImplementation = previous.proxyImplementation
  function retain(old, fresh) {
    if (!old || !fresh || fresh.status !== "error" || old.status !== "ok") return fresh
    if (old.proxyImplementation && fresh.proxyImplementation
        && old.proxyImplementation !== fresh.proxyImplementation) return fresh
    if (fresh.errorKind === "malformed" || fresh.supportsBankedReset === false
        && fresh.proxyImplementation !== old.proxyImplementation) return fresh
    if (fresh.proxyImplementation === "rust" && fresh.errorKind === "quota_unavailable") return fresh
    return Object.assign({}, fresh, {
      status: "ok", stale: true, windows: old.windows, credits: old.credits,
      plan: old.plan, account: old.account, fetchedAt: old.fetchedAt,
      notice: "Last known reading · " + String(fresh.message || "Refresh failed.")
    })
  }
  var oldProviders = listOrEmpty(previous.providers)
  if (next.providers.length === 1 && next.providers[0].id === "cliproxy" && next.providers[0].status === "error"
      && oldProviders.length > 0 && oldProviders[0].id !== "cliproxy") {
    var failure = next.providers[0]
    next.providers = Array.prototype.map.call(oldProviders, function(old) {
      var fresh = Object.assign({}, old, { status: "error", message: failure.message, errorKind: failure.errorKind })
      fresh.accounts = Array.prototype.map.call(listOrEmpty(old.accounts), function(account) {
        return retain(account, Object.assign({}, account, { status: "error", message: failure.message }))
      })
      return retain(old, fresh)
    })
  }
  next.providers = listOrEmpty(next.providers).map(function(fresh) {
    var old = null
    for (var i = 0; i < oldProviders.length; i++)
      if (oldProviders[i].id === fresh.id) old = oldProviders[i]
    var accounts = listOrEmpty(fresh.accounts).map(function(account) {
      var prior = listOrEmpty(old && old.accounts)
      for (var j = 0; j < prior.length; j++)
        if (prior[j].accountId === account.accountId) return retain(prior[j], account)
      return account
    })
    var result = old && old.accountId === fresh.accountId ? retain(old, fresh) : fresh
    if (fresh.accounts) result.accounts = accounts
    return result
  })
  return next
}

// Custom cost rates are stored as JSON for the manifest's string setting, but
// edited as ordinary fields. Model IDs deliberately keep case and prefixes.
function costPriceError(message, rowIndex, fieldKey) {
  var error = new Error(message)
  error.rowIndex = rowIndex
  error.fieldKey = fieldKey
  return error
}

function encodeCostPrices(rows) {
  var fields = ["inputCostPerMillionTokens", "outputCostPerMillionTokens",
    "cacheReadCostPerMillionTokens", "cacheWriteCostPerMillionTokens"]
  var result = Object.create(null)
  if (rows.length > 128) throw new Error("Custom prices support at most 128 models.")
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var model = String(row.model || "").trim()
    if (!model || model.length > 256 || /[\x00-\x1f]/.test(model))
      throw costPriceError("Enter a model ID of 1–256 characters for custom price " + (i + 1) + ".", i, "modelId")
    if (Object.prototype.hasOwnProperty.call(result, model))
      throw costPriceError("Each custom price must use a different model ID.", i, "modelId")
    var bare = model.toLowerCase().split("/").pop().split("[")[0]
    if (["<unattributed>", "<synthetic>", "synthetic"].indexOf(bare) >= 0)
      throw costPriceError("Custom prices require an attributable model ID.", i, "modelId")
    var prices = {}
    for (var j = 0; j < fields.length; j++) {
      var raw = row[fields[j]]
      var value = raw === undefined ? "" : String(raw).trim()
      if (j >= 2 && value === "") continue
      if (value === "" || !/^(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i.test(value)
          || !isFinite(Number(value)) || Number(value) > 1000000000)
        throw costPriceError("Enter input/output prices from 0 to 1,000,000,000 USD per million tokens; cache prices may be blank.", i, fields[j])
      prices[fields[j]] = Number(value)
    }
    result[model] = prices
  }
  var json = JSON.stringify(result)
  if (encodeURIComponent(json).replace(/%[0-9A-F]{2}/gi, "x").length > 65536)
    throw new Error("Custom prices exceed the 64 KiB limit.")
  return json
}

function decodeCostPrices(raw) {
  if (typeof raw !== "string" || raw.length > 65536)
    throw new Error("Saved custom prices are invalid. Remove them to restore automatic pricing.")
  var document = JSON.parse(raw)
  if (!document || typeof document !== "object" || Array.isArray(document))
    throw new Error("Saved custom prices must be an object.")
  var fields = ["inputCostPerMillionTokens", "outputCostPerMillionTokens",
    "cacheReadCostPerMillionTokens", "cacheWriteCostPerMillionTokens"]
  var rows = Object.keys(document).map(function(model) {
    var prices = document[model]
    if (!prices || typeof prices !== "object" || Array.isArray(prices)
        || Object.keys(prices).some(function(key) { return fields.indexOf(key) < 0 }))
      throw new Error("Saved custom prices contain unsupported fields.")
    var row = { model: model }
    for (var i = 0; i < fields.length; i++) {
      var value = prices[fields[i]]
      if (value !== undefined && (typeof value !== "number" || !isFinite(value)))
        throw new Error("Saved custom prices must be numeric.")
      row[fields[i]] = value === undefined ? "" : String(value)
    }
    return row
  })
  encodeCostPrices(rows)
  return rows
}
