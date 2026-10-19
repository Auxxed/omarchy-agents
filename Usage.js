.pragma library

// The panel's reading of usage records: limit windows, pace, money, Hermes
// status lines, model names. Kept free of Qt so tests/test_usage.js runs it
// under node. Times come in as nowMs so a panel left open stays truthful.

var ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/
var SESSION_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/
var SOURCE_RE = /^[a-z][a-z0-9_-]{0,31}$/
var END_REASON_RE = /^[a-z][a-z0-9_]{0,39}$/
var HOUR = 3600 * 1000
var DAY = 24 * HOUR

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

// Host-owned sinks (PanelHero, Button, tooltips) render as AutoText.
function plain(value, maxLen) {
  var s = String(value || "")
  s = s.replace(/[\u0000-\u001f\u007f-\u009f\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, "")
  s = s.replace(/[<>&]/g, "")
  var n = maxLen || 80
  if (s.length > n) s = s.substring(0, n)
  return s
}

function safeId(value) {
  var s = String(value || "")
  if (!ID_RE.test(s) || s.indexOf("..") >= 0) return ""
  return s
}

function numberValue(value) {
  var n = Number(value || 0)
  return isFinite(n) ? Math.round(n) : 0
}

function moneyValue(value) {
  var n = Number(value)
  return isFinite(n) && n >= 0 ? n : 0
}

// ---------------------------------------------------------------- records

// A prepaid agent's credit ledger. Like rate limits, the balance is
// per-account.
function balanceValue(raw) {
  if (!raw || typeof raw !== "object") return null
  var remaining = Number(raw.remaining)
  var funded = Number(raw.funded)
  if (!isFinite(remaining) || remaining < 0) return null
  return {
    remaining: remaining,
    funded: isFinite(funded) && funded > 0 ? funded : 0,
    spent: Math.max(0, Number(raw.spent) || 0),
    currency: String(raw.currency || "USD"),
    estimated: raw.estimated === true
  }
}

// The record is a file on disk, so every field the panel acts on is
// re-checked here: session ids reach an argv, titles reach text sinks.
function hermesInfo(raw) {
  if (!raw || typeof raw !== "object") return null
  var sessions = []
  var list = Array.isArray(raw.recentSessions) ? raw.recentSessions.slice(0, 6) : []
  for (var i = 0; i < list.length; i++) {
    var s = list[i]
    if (!s || typeof s !== "object") continue
    var id = String(s.id || "")
    if (!SESSION_RE.test(id)) continue
    var source = String(s.source || "")
    sessions.push({
      id: id,
      title: String(s.title || "Untitled session").substring(0, 80),
      source: SOURCE_RE.test(source) ? source : "cli",
      model: String(s.model || "").substring(0, 64),
      messages: numberValue(s.messages),
      lastActivityAt: String(s.lastActivityAt || "").substring(0, 40),
      open: s.open === true,
      pinned: s.pinned === true,
      costUsd: moneyValue(s.costUsd)
    })
  }
  var gateway = raw.gateway && typeof raw.gateway === "object" ? raw.gateway : {}
  var cron = raw.cron && typeof raw.cron === "object" ? raw.cron : {}
  var ended = raw.lastEnded && typeof raw.lastEnded === "object" ? raw.lastEnded : {}
  var endReason = String(ended.reason || "")
  return {
    sessions: sessions,
    gatewayRunning: String(gateway.state || "") === "running",
    activeAgents: numberValue(gateway.activeAgents),
    paused: raw.paused === true,
    cronJobs: numberValue(cron.jobs),
    cronActive: numberValue(cron.active),
    cronFailing: numberValue(cron.failing),
    cronNextRunAt: String(cron.nextRunAt || "").substring(0, 40),
    todayCostUsd: moneyValue(raw.todayCostUsd),
    weekCostUsd: moneyValue(raw.weekCostUsd),
    runningWorkers: numberValue(raw.runningWorkers),
    lastEndReason: END_REASON_RE.test(endReason) ? endReason : "",
    lastEndedAt: String(ended.at || "").substring(0, 40)
  }
}

function displayProvider(record) {
  return {
    providerId: String(record.id),
    providerName: String(record.name || record.id),
    ready: record.ready === true,
    usageStatusText: String(record.usageStatusText || ""),
    authHelpText: String(record.authHelpText || ""),
    limits: Array.isArray(record.limits) ? record.limits : [],
    // Set when the limits are a cached copy shown under a status (sign-in
    // expired, API down): the panel says how old they are.
    limitsAsOf: String(record.limitsAsOf || ""),
    tierLabel: String(record.tierLabel || ""),
    balance: balanceValue(record.balance),
    todayPrompts: numberValue(record.todayPrompts),
    todaySessions: numberValue(record.todaySessions),
    todayTotalTokens: numberValue(record.todayTotalTokens),
    todayTokensByModel: record.todayTokensByModel || ({}),
    recentDays: Array.isArray(record.recentDays) ? record.recentDays : [],
    totalPrompts: numberValue(record.totalPrompts),
    totalSessions: numberValue(record.totalSessions),
    activeDays: numberValue(record.activeDays),
    modelUsage: record.modelUsage || ({}),
    hasLocalStats: record.hasLocalStats !== false,
    hasPromptStats: record.hasPromptStats !== false,
    // Hermes-only control data: recent sessions, gateway, cron, pause.
    hermes: hermesInfo(record.hermes)
  }
}

// All-time keeps a quiet day from hiding an agent; today's counts admit a
// machine whose only source is history.jsonl, which knows nothing older.
function providerHasData(p) {
  return numberValue(p.totalPrompts) > 0 || numberValue(p.totalSessions) > 0
    || numberValue(p.activeDays) > 0 || numberValue(p.todayPrompts) > 0
    || numberValue(p.todaySessions) > 0 || (p.limits && p.limits.length > 0)
    || !!p.balance
}

// ---------------------------------------------------------------- format

function formatTokenCount(n) {
  if (n === undefined || n === null) return "0"
  if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
  return String(n)
}

function modelWordCase(word) {
  if (word === "gpt") return "GPT"
  if (word === "deepseek") return "DeepSeek"
  return word.charAt(0).toUpperCase() + word.slice(1)
}

// Model ids arrive hyphenated with the version split across segments
// (`claude-opus-4-8`, `gpt-5.6-sol`). Rejoin the numeric run into one
// version and title-case the words around it.
function friendlyModelName(id) {
  if (!id) return "Unknown"
  var name = String(id)
  var slash = name.lastIndexOf("/")
  if (slash >= 0) name = name.slice(slash + 1)
  name = name.replace(/^claude-/, "").replace(/-\d{8}$/, "").replace(/:/g, "-")
  var parts = name.split("-")
  var words = []
  var version = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "") continue
    if (/^\d/.test(part)) {
      version.push(part)
      continue
    }
    if (version.length > 0) {
      words.push(version.join("."))
      version = []
    }
    words.push(modelWordCase(part))
  }
  if (version.length > 0) words.push(version.join("."))
  return words.length > 0 ? words.join(" ") : "Unknown"
}

function formatDuration(ms) {
  if (!(ms > 0)) return "now"
  var minutes = Math.floor(ms / 60000)
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return days + "d " + (hours % 24) + "h"
  if (hours > 0) return hours + "h " + (minutes % 60) + "m"
  return Math.max(1, minutes) + "m"
}

function relativeTime(iso, nowMs) {
  var ms = new Date(String(iso || "")).getTime()
  if (!isFinite(ms)) return ""
  var ago = nowMs - ms
  if (ago < 60000) return "now"
  return formatDuration(ago).split(" ")[0] + " ago"
}

function currencyPrefix(currency) {
  var code = String(currency || "USD").toUpperCase()
  if (code === "USD") return "$"
  if (code === "EUR") return "€"
  if (code === "GBP") return "£"
  return code + " "
}

function formatMoney(value, currency) {
  var amount = Number(value)
  if (!isFinite(amount)) amount = 0
  return currencyPrefix(currency) + amount.toFixed(2)
}

function balanceDetailText(b) {
  if (!b || !(b.funded > 0)) return ""
  var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
  if (b.estimated) text += " · estimated"
  return text
}

// The plan you pay for, under the name of the tool it pays for.
function heroMeta(p) {
  if (!p) return ""
  var tier = String(p.tierLabel || "")
  if (tier === "") return "Subscription"
  return tier.charAt(0).toUpperCase() + tier.slice(1)
}

// ---------------------------------------------------------------- limits
//
// Providers report a short rolling session window and longer weekly or
// monthly ones. Everything below normalizes them into one record so the
// meters, the hero and the pace line speak a single language.

// Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
// them ("5h window", "30m window"). Both have to land on the same record.
function windowIsLong(text) {
  return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
    || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
}

function windowSpanMs(label) {
  var text = String(label || "").toLowerCase()
  if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * DAY
  if (windowIsLong(text)) return 7 * DAY
  var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
  if (hours) return Number(hours[1]) * HOUR
  var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
  if (minutes) return Number(minutes[1]) * 60 * 1000
  return 0
}

function windowTitle(label) {
  var text = String(label || "").toLowerCase()
  if (text.indexOf("month") >= 0) return "Monthly"
  if (windowIsLong(text)) return "Weekly"
  if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
  var bare = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
  return bare === "" ? "Limit" : bare
}

// A collector that already knows which window a limit belongs to says so,
// and that beats reading it back out of the label: a model-scoped limit is
// titled after its model plus its window ("Opus 5 (1M context) Session"),
// and the "1M" in it would parse as a one-minute window. So an explicit
// title's last word sets the span; a title without one (Grok's "Chat") has
// no span and so no pace.
function titledSpanMs(title) {
  var m = String(title || "").match(/\b(Weekly|Monthly|Session)$/)
  if (!m) return 0
  if (m[1] === "Weekly") return 7 * DAY
  if (m[1] === "Monthly") return 30 * DAY
  return 5 * HOUR
}

function limitWindow(label, percent, resetAt, title) {
  var explicit = String(title || "")
  var span = explicit !== "" ? titledSpanMs(explicit) : windowSpanMs(label)
  return {
    title: explicit !== "" ? explicit : windowTitle(label),
    percent: Number(percent),
    resetAt: String(resetAt || ""),
    spanMs: span
  }
}

function limitWindows(p) {
  if (!p) return []
  var out = []
  var list = p.limits || []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i] || {}
    var percent = Number(entry.percent)
    if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
  }
  return out
}

// The window that decides how much room is left: the fullest one, since
// that is what stops the next prompt.
function bindingWindow(p) {
  var windows = limitWindows(p)
  var best = null
  for (var i = 0; i < windows.length; i++) {
    if (!best || windows[i].percent > best.percent) best = windows[i]
  }
  return best
}

function busiestWindow(providers) {
  var best = null
  for (var i = 0; i < providers.length; i++) {
    var w = bindingWindow(providers[i])
    if (w && (!best || w.percent > best.percent)) best = w
  }
  return best
}

function resetMs(w, nowMs) {
  if (!w || w.resetAt === "") return -1
  var ms = new Date(w.resetAt).getTime()
  return isFinite(ms) ? ms - nowMs : -1
}

// "2d 4h ago" while the limits are a cached copy.
function limitsAge(p, nowMs) {
  if (!p || String(p.limitsAsOf || "") === "") return ""
  var at = Date.parse(p.limitsAsOf)
  if (!isFinite(at)) return ""
  return formatDuration(nowMs - at) + " ago"
}

// Where usage stands against an even burn across the window. expected is
// the share of the window that has passed (the meter's pace mark). At the
// current rate the window either runs out before it resets, or has some
// share left at reset. Before there is anything to go on, only the mark is
// given.
function pace(w, nowMs) {
  if (!w || !(w.spanMs > 0)) return null
  var remaining = resetMs(w, nowMs)
  if (remaining <= 0 || remaining > w.spanMs) return null
  var elapsed = w.spanMs - remaining
  var expected = elapsed / w.spanMs
  var used = clamp(Number(w.percent) || 0, 0, 1)
  var result = { expected: expected, runsOut: false, runsOutMs: -1, leftAtReset: -1, text: "" }
  if (used >= 1) {
    result.runsOut = true
    result.runsOutMs = 0
    result.text = "Used up"
    return result
  }
  // Nothing used yet says nothing about the pace, and the first fifth of a
  // window is too short to extrapolate: one burst twenty minutes into a
  // five-hour session would read as running out.
  if (used <= 0 || elapsed < w.spanMs * 0.2) return result
  var rate = used / elapsed
  if (rate > 0 && (1 - used) / rate < remaining) {
    result.runsOut = true
    result.runsOutMs = (1 - used) / rate
    result.text = "Runs out in " + formatDuration(result.runsOutMs) + " at this pace"
    return result
  }
  result.leftAtReset = clamp(1 - (used + rate * remaining), 0, 1)
  result.text = "~" + Math.round(result.leftAtReset * 100) + "% left at reset"
  return result
}

// "Resets in 2d 4h · ~40% left at reset", without the pace part when
// withPace is false (a cached copy's percentage is older than the clock).
function resetLine(w, nowMs, withPace) {
  var remainingMs = resetMs(w, nowMs)
  if (remainingMs <= 0) return ""
  var p = withPace === false ? null : pace(w, nowMs)
  var text = "Resets in " + formatDuration(remainingMs)
  return p && p.text !== "" ? text + " · " + p.text : text
}

// Hover summary for the bar icon: the fullest window of every agent.
function barTooltip(providers) {
  var parts = []
  for (var i = 0; i < providers.length && parts.length < 6; i++) {
    var w = bindingWindow(providers[i])
    var name = plain(providers[i].providerName, 20)
    if (w) parts.push(name + " " + Math.round(clamp(w.percent, 0, 1) * 100) + "%")
    else if (providers[i].balance) parts.push(name + " " + formatMoney(providers[i].balance.remaining, providers[i].balance.currency))
  }
  return plain(parts.join(" · "), 160)
}

// One alert per crossing: a window that was below the line at the last
// look and is at or past it now. A window seen for the first time (shell
// start, a new agent) only sets the baseline, so a restart never repeats
// an alert. Returns the next state and the alerts to send.
function limitCrossings(state, providers, threshold) {
  var next = {}
  var alerts = []
  var line = Number(threshold) / 100
  if (!(line > 0) || line > 1) return { state: next, alerts: alerts }
  for (var i = 0; i < providers.length; i++) {
    var p = providers[i]
    var windows = limitWindows(p)
    for (var j = 0; j < windows.length; j++) {
      var w = windows[j]
      var key = p.providerId + "|" + w.title
      next[key] = w.percent
      var before = state ? state[key] : undefined
      if (before !== undefined && before < line && w.percent >= line)
        alerts.push({ providerName: plain(p.providerName, 40), window: w })
    }
  }
  return { state: next, alerts: alerts }
}

// ---------------------------------------------------------------- hermes

function hermesStatusText(h, nowMs) {
  if (!h) return ""
  var parts = [h.gatewayRunning ? "Gateway running" : "Gateway stopped"]
  if (h.gatewayRunning && h.activeAgents > 0)
    parts.push(h.activeAgents + " agent" + (h.activeAgents === 1 ? "" : "s") + " working")
  if (h.cronJobs > 0) {
    var cron = h.cronActive + " cron job" + (h.cronActive === 1 ? "" : "s")
    var next = h.cronNextRunAt !== "" ? new Date(h.cronNextRunAt).getTime() - nowMs : -1
    if (!h.paused && next > 0) cron += ", next in " + formatDuration(next)
    parts.push(cron)
  }
  if (h.cronFailing > 0) parts.push(h.cronFailing + " failing")
  if (h.runningWorkers > 0)
    parts.push(h.runningWorkers + " worker" + (h.runningWorkers === 1 ? "" : "s") + " running")
  return parts.join(" · ")
}

// Hermes records lifecycle reasons (tui_close, ws_disconnect,
// compression...), not success or failure, so they are shown as-is.
function hermesLastEndedText(h, nowMs) {
  if (!h || h.lastEndReason === "") return ""
  var when = relativeTime(h.lastEndedAt, nowMs)
  return "Last session ended" + (when !== "" ? " " + when : "") + ": " + h.lastEndReason.replace(/_/g, " ")
}

function hermesCostText(h) {
  if (!h || (h.todayCostUsd <= 0 && h.weekCostUsd <= 0)) return ""
  return formatMoney(h.todayCostUsd, "USD") + " today · " + formatMoney(h.weekCostUsd, "USD") + " this week"
}

function sessionMeta(session, nowMs) {
  if (!session) return ""
  var parts = []
  var when = relativeTime(session.lastActivityAt, nowMs)
  if (when !== "") parts.push(when)
  parts.push(session.messages + " msg")
  if (session.model !== "") parts.push(friendlyModelName(session.model))
  return parts.join(" · ")
}

// ---------------------------------------------------------------- history

function dateString(date) {
  return date.getFullYear()
    + "-" + String(date.getMonth() + 1).padStart(2, "0")
    + "-" + String(date.getDate()).padStart(2, "0")
}

// Local calendar date, recomputed from nowMs so a panel left open across
// midnight moves the "Today" row with the clock.
function todayDate(nowMs) {
  return dateString(new Date(nowMs))
}

function dayName(date) {
  var parsed = new Date(String(date || "") + "T00:00:00")
  if (isNaN(parsed.getTime())) return String(date || "")
  return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
}

function dayLabel(date, today) {
  return today ? "Today" : dayName(date)
}

// Prompt and session counts only exist for today, so they ride along on
// today's tooltip. Billing-API agents never count prompts, and "0 prompts"
// would read as a quiet day, not a gap.
function dayTooltip(day, today, p) {
  if (!day) return ""
  var parsed = new Date(String(day.date) + "T00:00:00")
  var label = isNaN(parsed.getTime())
    ? String(day.date)
    : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
  var text = label + " · " + formatTokenCount(Number(day.messageCount || 0)) + " tokens"
  if (today && p && p.hasPromptStats !== false)
    text += " · " + Number(p.todayPrompts || 0) + " prompts · "
      + Number(p.todaySessions || 0) + " sessions"
  return text
}

function weekPeak(p) {
  var days = p ? (p.recentDays || []) : []
  var peak = 0
  for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
  return peak
}

function modelRows(p) {
  var usageByModel = p ? (p.modelUsage || {}) : {}
  var rows = []
  for (var id in usageByModel) {
    var bucket = usageByModel[id] || {}
    var input = Number(bucket.inputTokens || 0)
    var output = Number(bucket.outputTokens || 0)
    var cacheRead = Number(bucket.cacheReadInputTokens || 0)
    var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
    rows.push({
      name: friendlyModelName(id),
      total: input + output + cacheRead + cacheWrite,
      input: input,
      output: output,
      cacheRead: cacheRead,
      cacheWrite: cacheWrite
    })
  }
  rows.sort(function(a, b) { return b.total - a.total })
  return rows.slice(0, 4)
}

function modelTooltip(row) {
  if (!row) return ""
  return "In " + formatTokenCount(row.input)
    + " · out " + formatTokenCount(row.output)
    + " · cache read " + formatTokenCount(row.cacheRead)
    + " · cache write " + formatTokenCount(row.cacheWrite)
}
