// Tests for Usage.js, the panel's reading of usage records.
// Run: node tests/test_usage.js
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const src = fs.readFileSync(path.join(__dirname, "..", "Usage.js"), "utf8").replace(/^\.pragma library\s*/, "")
const exported = "return {" + [...src.matchAll(/^(?:function|var) (\w+)/gm)].map(m => m[1]).join(",") + "}"
const U = new Function(src + "\n" + exported)()

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    console.error("FAIL " + name)
    throw e
  }
}

const HOUR = 3600e3
const DAY = 24 * HOUR
const NOW = Date.parse("2026-10-19T12:00:00Z")
const iso = ms => new Date(ms).toISOString()

test("window spans from labels the collectors write", () => {
  assert.strictEqual(U.windowSpanMs("Session (5-hour)"), 5 * HOUR)
  assert.strictEqual(U.windowSpanMs("5h window"), 5 * HOUR)
  assert.strictEqual(U.windowSpanMs("30m window"), 30 * 60e3)
  assert.strictEqual(U.windowSpanMs("Weekly (7-day)"), 7 * DAY)
  assert.strictEqual(U.windowSpanMs("Monthly credits"), 30 * DAY)
  assert.strictEqual(U.windowSpanMs("Limit"), 0)
})

test("an explicit title sets the span, never a number inside a model name", () => {
  assert.strictEqual(U.limitWindow("Opus 5 (1M context) Session", 0.2, "", "Opus 5 (1M context) Session").spanMs, 5 * HOUR)
  assert.strictEqual(U.limitWindow("Opus 5 (1M context) Weekly", 0.2, "", "Opus 5 (1M context) Weekly").spanMs, 7 * DAY)
  assert.strictEqual(U.limitWindow("Weekly (7-day)", 0.2, "", "Weekly").spanMs, 7 * DAY)
  assert.strictEqual(U.limitWindow("Monthly credits", 0.2, "", "Monthly").spanMs, 30 * DAY)
  assert.strictEqual(U.limitWindow("Chat", 0.2, "", "Chat").spanMs, 0)
  assert.strictEqual(U.limitWindow("Session (5-hour)", 0.2, "", undefined).title, "Session")
})

test("the binding window is the fullest one", () => {
  const p = { limits: [{ label: "Session (5-hour)", percent: 0.4 }, { label: "Weekly (7-day)", percent: 0.7 }, { label: "x", percent: -1 }] }
  assert.strictEqual(U.bindingWindow(p).title, "Weekly")
  assert.strictEqual(U.limitWindows(p).length, 2)
  assert.strictEqual(U.bindingWindow(null), null)
  assert.strictEqual(U.busiestWindow([p, { limits: [{ label: "Monthly", percent: 0.9 }] }]).percent, 0.9)
})

test("pace: on track leaves a share at reset", () => {
  // Weekly, 4 days in (57%), 30% used: ~48% left at reset.
  const w = U.limitWindow("Weekly (7-day)", 0.3, iso(NOW + 3 * DAY), "Weekly")
  const p = U.pace(w, NOW)
  assert.ok(Math.abs(p.expected - 4 / 7) < 1e-9)
  assert.strictEqual(p.runsOut, false)
  assert.strictEqual(p.text, "~48% left at reset")
})

test("pace: burning fast says when it runs out", () => {
  // 2 days in, 50% used: runs out two more days from now, before the reset.
  const w = U.limitWindow("Weekly (7-day)", 0.5, iso(NOW + 5 * DAY), "Weekly")
  const p = U.pace(w, NOW)
  assert.strictEqual(p.runsOut, true)
  assert.strictEqual(p.text, "Runs out in 2d 0h at this pace")
})

test("pace: the first fifth of a window is too early to extrapolate", () => {
  // 20 minutes into a 5-hour session at 9%: no verdict, just the mark.
  const p = U.pace(U.limitWindow("Session (5-hour)", 0.09, iso(NOW + 4 * HOUR + 40 * 60e3)), NOW)
  assert.strictEqual(p.text, "")
  assert.strictEqual(p.runsOut, false)
  assert.ok(p.expected > 0.06 && p.expected < 0.07)
})

test("pace: nothing to say before there is anything to go on", () => {
  const unused = U.pace(U.limitWindow("Weekly (7-day)", 0, iso(NOW + 2 * DAY), "Weekly"), NOW)
  assert.strictEqual(unused.text, "")
  assert.ok(unused.expected > 0.7)
  const early = U.pace(U.limitWindow("Session (5-hour)", 0.1, iso(NOW + 5 * HOUR - 60e3)), NOW)
  assert.strictEqual(early.text, "")
  assert.strictEqual(U.pace(U.limitWindow("Chat", 0.5, iso(NOW + DAY), "Chat"), NOW), null)
  assert.strictEqual(U.pace(U.limitWindow("Weekly (7-day)", 0.5, iso(NOW - 60e3)), NOW), null)
  assert.strictEqual(U.pace(U.limitWindow("Weekly (7-day)", 0.5, iso(NOW + 9 * DAY)), NOW), null)
  assert.strictEqual(U.pace(U.limitWindow("Weekly (7-day)", 1, iso(NOW + DAY)), NOW).text, "Used up")
})

test("reset line joins the countdown and the pace, or drops the pace when stale", () => {
  const w = U.limitWindow("Weekly (7-day)", 0.3, iso(NOW + 3 * DAY), "Weekly")
  assert.strictEqual(U.resetLine(w, NOW), "Resets in 3d 0h · ~48% left at reset")
  assert.strictEqual(U.resetLine(w, NOW, false), "Resets in 3d 0h")
  assert.strictEqual(U.resetLine(U.limitWindow("x", 0.3, ""), NOW), "")
})

test("one alert per crossing, none for what was already past the line", () => {
  const prov = pct => [{ providerId: "claude", providerName: "Claude Code", limits: [{ label: "Weekly (7-day)", percent: pct, resetsAt: iso(NOW + DAY) }] }]
  let r = U.limitCrossings({}, prov(0.95), 90)
  assert.strictEqual(r.alerts.length, 0) // first sight: baseline only
  r = U.limitCrossings(r.state, prov(0.96), 90)
  assert.strictEqual(r.alerts.length, 0)
  r = U.limitCrossings(r.state, prov(0.1), 90) // a reset
  r = U.limitCrossings(r.state, prov(0.89), 90)
  assert.strictEqual(r.alerts.length, 0)
  r = U.limitCrossings(r.state, prov(0.9), 90)
  assert.strictEqual(r.alerts.length, 1)
  assert.strictEqual(r.alerts[0].providerName, "Claude Code")
  assert.strictEqual(r.alerts[0].window.title, "Weekly")
  assert.strictEqual(U.limitCrossings(r.state, prov(1), 0).alerts.length, 0) // off
})

test("records are rebuilt field by field", () => {
  const p = U.displayProvider({ id: "grok", name: "Grok", ready: true, limits: "nope", todayPrompts: "7", balance: { remaining: -1 }, recentDays: null })
  assert.deepStrictEqual(p.limits, [])
  assert.strictEqual(p.todayPrompts, 7)
  assert.strictEqual(p.balance, null)
  assert.deepStrictEqual(p.recentDays, [])
  assert.strictEqual(p.hermes, null)
  assert.ok(!U.providerHasData(U.displayProvider({ id: "x" })))
  assert.ok(U.providerHasData(U.displayProvider({ id: "x", limits: [{ percent: 0 }] })))
})

test("hermes data that reaches an argv or a text sink is re-checked", () => {
  const h = U.hermesInfo({
    recentSessions: [{ id: "ok_1", title: "T", source: "desktop" }, { id: "../etc", title: "bad" }, { id: "x; rm -rf ~" },
      { id: "s2", source: "Not A Source" }],
    gateway: { state: "running", activeAgents: 2 }, runningWorkers: 3,
    lastEnded: { reason: "tui_close", at: "2026-10-19T11:00:00+00:00" },
  })
  assert.deepStrictEqual(h.sessions.map(s => s.id), ["ok_1", "s2"])
  assert.strictEqual(h.sessions[1].source, "cli")
  assert.strictEqual(h.lastEndReason, "tui_close")
  assert.strictEqual(U.hermesInfo({ lastEnded: { reason: "Bad Reason!" } }).lastEndReason, "")
  assert.strictEqual(U.hermesStatusText(h, NOW), "Gateway running · 2 agents working · 3 workers running")
  assert.strictEqual(U.hermesLastEndedText(h, NOW), "Last session ended 1h ago: tui close")
})

test("text bound for host-drawn sinks is plain", () => {
  assert.strictEqual(U.plain("<b>Hi</b>\u202E&x\n"), "bHi/bx")
  assert.strictEqual(U.plain("x".repeat(100), 10).length, 10)
  assert.strictEqual(U.safeId("grok-bot"), "grok-bot")
  assert.strictEqual(U.safeId("a..b"), "")
  assert.strictEqual(U.safeId("-x"), "")
})

test("formatting", () => {
  assert.strictEqual(U.formatDuration(90 * 60e3), "1h 30m")
  assert.strictEqual(U.formatDuration(26 * HOUR), "1d 2h")
  assert.strictEqual(U.formatDuration(0), "now")
  assert.strictEqual(U.formatTokenCount(4_900_000_000), "4.9B")
  assert.strictEqual(U.formatTokenCount(12_345), "12.3K")
  assert.strictEqual(U.formatMoney(3.456, "EUR"), "€3.46")
  assert.strictEqual(U.formatMoney("x", "SEK"), "SEK 0.00")
  assert.strictEqual(U.friendlyModelName("claude-opus-4-8-20260101"), "Opus 4.8")
  assert.strictEqual(U.friendlyModelName("openai/gpt-5.6-sol"), "GPT 5.6 Sol")
  assert.strictEqual(U.limitsAge({ limitsAsOf: iso(NOW - 2 * DAY - 4 * HOUR) }, NOW), "2d 4h ago")
  assert.strictEqual(U.limitsAge({ limitsAsOf: "garbage" }, NOW), "")
  assert.strictEqual(U.heroMeta({ tierLabel: "pro" }), "Pro")
})

test("model rows are the four heaviest", () => {
  const rows = U.modelRows({ modelUsage: { a: { inputTokens: 5 }, b: { outputTokens: 50 }, c: { cacheReadInputTokens: 9 }, d: {}, e: { inputTokens: 1 } } })
  assert.deepStrictEqual(rows.map(r => r.name), ["B", "C", "A", "E"])
})

console.log(passed + " passed")
