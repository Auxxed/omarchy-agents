import QtQuick
import Quickshell
import Quickshell.Io
import "Usage.js" as U

// The data side of agent usage. Collectors (Omarchy's packaged
// omarchy-agent-usage-update plus this plugin's Grok, Grok Bot and Hermes
// collectors, all run by bin/refresh) write one JSON record per agent into
// the usage directory; this file discovers those records, watches them for
// changes and turns them into the providers the panel shows.
Item {
  id: root
  visible: false

  property var settings: ({})
  // Several bars mean several copies of this file. Only the leader runs the
  // collectors; the others read the records it writes. The panel supplies
  // the test, since only it can see its sibling widgets.
  property var leaderTest: null
  function leader() { return typeof leaderTest !== "function" || leaderTest() === true }

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string usageDir: home + "/.local/state/omarchy/agents/usage"
  readonly property string helper: decodeURIComponent(
    Qt.resolvedUrl("bin/usage-bridge").toString().replace(/^file:\/\//, ""))
  readonly property string refreshHelper: decodeURIComponent(
    Qt.resolvedUrl("bin/refresh").toString().replace(/^file:\/\//, ""))

  // ------------------------------------------------------------- discovery

  property var agentIds: []
  property var agents: []
  property int dataRevision: 0
  property string listBuf: ""

  Process {
    id: listProcess
    running: false
    command: ["/usr/bin/python3", "-I", "-S", root.helper, "list"]

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        root.listBuf += chunk
        if (root.listBuf.length > 4096) {
          listProcess.signal(15)
          root.listBuf = ""
        }
      }
    }
    onExited: function(code) {
      if (code === 0) root.applyAgentListing(root.listBuf)
      root.listBuf = ""
    }
  }

  function rescanAgents() {
    if (!listProcess.running) listProcess.running = true
  }

  function applyAgentListing(output) {
    var ids = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      var stem = name.slice(-5) === ".json" ? name.slice(0, -5) : name
      if (U.safeId(stem) !== "") ids.push(stem)
    }
    ids.sort()
    // Same list, same objects: reassigning the model would tear down every
    // FileView just to build identical ones.
    if (JSON.stringify(ids) !== JSON.stringify(agentIds)) agentIds = ids
  }

  Instantiator {
    id: agentInstantiator
    model: root.agentIds

    delegate: Agent {
      required property var modelData
      agentId: modelData
      path: root.usageDir + "/" + modelData + ".json"
      helper: root.helper
      onRecordChanged: root.recordsChanged()
    }

    onObjectAdded: (index, object) => root.rebuildAgents()
    onObjectRemoved: (index, object) => root.rebuildAgents()
  }

  function rebuildAgents() {
    var result = []
    for (var i = 0; i < agentInstantiator.count; i++) {
      var agent = agentInstantiator.objectAt(i)
      if (agent) result.push(agent)
    }
    agents = result
    recordsChanged()
  }

  function recordsChanged() {
    dataRevision++
    scheduleLimitsRetry()
  }

  // A collector that could not reach its limits endpoint at all (typically
  // the seconds after login, before the network is up) writes retryAdvised
  // into its record. That earns a sooner try than the full refresh
  // interval: 30 s, then 1, 2, 4... minutes while the outage lasts, so a
  // long one never becomes a 30-second treadmill. Only the advising agents
  // rerun. Sign-in problems never advise a retry; waiting does not fix them.
  property var retryAgentIds: []
  property int retryStreak: 0

  Timer {
    id: limitsRetry
    interval: Math.min(root.refreshIntervalSec * 1000, 30000 * Math.pow(2, Math.min(root.retryStreak, 6)))
    repeat: false
    onTriggered: {
      root.retryStreak++
      root.runUpdate("limits", root.retryAgentIds)
    }
  }

  function scheduleLimitsRetry() {
    var advising = []
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (record && record.retryAdvised === true && providerEnabled(String(record.id || "")))
        advising.push(String(record.id))
    }
    retryAgentIds = advising
    if (advising.length > 0 && leader()) {
      if (!limitsRetry.running) limitsRetry.restart()
    } else {
      retryStreak = 0
      limitsRetry.stop()
    }
  }

  Component.onCompleted: rescanAgents()

  // The first run waits a moment so sibling widgets on other bars have
  // registered and the leader is settled.
  Timer {
    interval: 1500
    running: true
    onTriggered: if (root.leader()) root.runUpdate("normal")
  }

  // -------------------------------------------------------------- refresh

  property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 900)))
  property string pendingUpdateKind: ""

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: if (root.leader()) root.runUpdate("normal")
  }

  Process {
    id: updateProcess
    running: false
    onExited: {
      root.rescanAgents()
      if (root.pendingUpdateKind !== "") {
        var kind = root.pendingUpdateKind
        root.pendingUpdateKind = ""
        root.runUpdate(kind)
      }
    }

    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (chunk && chunk.length > 0 && chunk.length < 1024)
          console.warn("agents", chunk.trim())
      }
    }
  }

  function updateCommand(kind, agentIds) {
    var command = ["/usr/bin/python3", "-I", "-S", root.refreshHelper]
    if (kind === "force") command.push("--force")
    if (kind === "limits") command.push("--limits-only")
    var providers = settings && settings.providers ? settings.providers : {}
    for (var id in providers) {
      if (providers[id] && providers[id].enabled === false && U.safeId(id) !== "")
        command.push("--except", id)
    }
    if (agentIds) {
      for (var i = 0; i < agentIds.length; i++) {
        var aid = U.safeId(agentIds[i])
        if (aid !== "") command.push(aid)
      }
    }
    return command
  }

  function runUpdate(kind, agentIds) {
    if (updateProcess.running) {
      // Collapse queued requests to one full rerun; a forced refresh outranks
      // the cheaper kinds it might have been queued behind.
      if (kind === "force" || root.pendingUpdateKind === "") root.pendingUpdateKind = kind
      return
    }
    updateProcess.command = updateCommand(kind, agentIds)
    updateProcess.running = true
  }

  function refresh() { refreshAll(true) }
  function refreshAll(force) { runUpdate(force === true ? "force" : "normal") }

  // Opening the panel wants the numbers that go stale on the wire, not
  // another walk over every transcript on disk: the collectors reuse their
  // recent scans in this mode.
  function refreshLimits() { runUpdate("limits") }

  // ------------------------------------------------------------- providers

  // An agent earns a place in the bar and the panel by being switched on in
  // settings and having actually produced numbers. With nothing to show,
  // the whole module collapses out of the bar rather than sitting there
  // dimmed.
  property var enabledProviders: {
    var rev = dataRevision
    var result = []
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (!record || !record.id) continue
      if (!providerEnabled(String(record.id))) continue
      var display = U.displayProvider(record)
      if (U.providerHasData(display)) result.push(display)
    }
    return result
  }

  function providerEnabled(id) {
    if (!settings || !settings.providers || !settings.providers[id]) return true
    return settings.providers[id].enabled !== false
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
}
