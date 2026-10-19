import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Usage.js" as U

Panel {
  id: root
  moduleName: "io.github.auxxed.agents"
  ipcTarget: "io.github.auxxed.agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: usage.enabledProviders
  readonly property string launchHelper: decodeURIComponent(
    Qt.resolvedUrl("bin/launch-agent").toString().replace(/^file:\/\//, ""))
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  // Until you pick one, the panel (and right-click launch) follows the
  // defaultProvider setting, falling back to the first tab.
  readonly property string defaultProviderId: safeId(settings ? settings.defaultProvider : "")
  readonly property int providerIndex: {
    var fallback = 0
    for (var i = 0; i < providers.length; i++) {
      if (providers[i].providerId === selectedProviderId) return i
      if (providers[i].providerId === defaultProviderId) fallback = i
    }
    return fallback
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null
  readonly property bool hermesSelected: !!provider && provider.providerId === "hermes"
  readonly property var hermes: hermesSelected ? (provider.hermes || null) : null
  property bool hermesControlPending: false

  readonly property bool barShowPercent: !!settings
    && (settings.barShowPercent === true || String(settings.barShowPercent) === "On")
  // The selected agent's fullest window; an agent with no windows (a free
  // or prepaid plan) hands the bar to the fullest window of any agent.
  readonly property var barWindow: headline || busiestWindow()
  readonly property string barPercentText: barWindow && barWindow.percent >= 0
    ? Math.round(clamp(barWindow.percent, 0, 1) * 100) + "%"
    : ""

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: (!!headline && headline.percent >= 0.9) || balanceAlarming

  function clamp(v, lo, hi) { return U.clamp(v, lo, hi) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Host-owned sinks (PanelHero, Button, tooltips) render as AutoText.
  function plain(value, maxLen) { return U.plain(value, maxLen) }

  function safeId(value) { return U.safeId(value) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    leaderUsage().refreshAll(true)
  }

  // Several bars, one widget each. The first instance is the leader: it
  // runs the collectors, owns the IPC target and sends limit alerts; the
  // others read the records it writes.
  function leaderPanel() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : null
    return items && items.length && items[0] ? items[0] : root
  }
  function isLeader() { return leaderPanel() === root }
  function leaderUsage() {
    var lead = leaderPanel()
    return lead && lead.usageModel ? lead.usageModel : usage
  }
  readonly property var usageModel: usage
  // Settled once siblings have registered, so only one IpcHandler is live.
  property bool ipcOwner: false

  // IPC opens the panel on the focused monitor, through the shell.
  function viaShell(action) {
    var sh = bar ? bar.shell : null
    if (!sh || typeof sh[action] !== "function") return false
    if (action === "hide") sh.hide(moduleName)
    else sh[action](moduleName, "{}")
    return true
  }

  // alertPercent: one notification when a limit window crosses it; 0 turns
  // alerts off. A window already past it when the shell starts stays quiet.
  readonly property int alertPercent: {
    var raw = settings ? settings.alertPercent : undefined
    var n = Math.round(Number(raw === undefined || raw === null || raw === "" ? 90 : raw))
    return isFinite(n) && n >= 0 && n <= 100 ? n : 90
  }
  property var limitState: ({})

  function checkLimitAlerts() {
    var result = U.limitCrossings(limitState, providers, alertPercent)
    limitState = result.state
    if (!isLeader()) return
    for (var i = 0; i < result.alerts.length; i++) {
      var alert = result.alerts[i]
      var w = alert.window
      var when = U.resetLine(w, Date.now(), true)
      Util.execArgv(["/usr/bin/omarchy-notification-send", "-g", button.text, "-u", "normal",
        alert.providerName + " " + w.title.toLowerCase() + " limit at " + Math.round(U.clamp(w.percent, 0, 1) * 100) + "%",
        when !== "" ? when + "." : "Close to the limit."])
    }
  }

  onProvidersChanged: checkLimitAlerts()

  function launchAgent() {
    // Right-click opens the subscription currently shown in the panel
    // (middle-click / h/l cycle that selection). An unknown id, or no
    // selection yet, falls through to the stock picker.
    var id = root.provider ? root.safeId(root.provider.providerId) : ""
    if (id !== "")
      Util.execArgv(["/usr/bin/bash", root.launchHelper, id])
    else
      Util.execArgv(["/usr/bin/omarchy-agent", "--pick"])
    root.close()
  }

  function launchHermesApp() {
    Util.execArgv(["/usr/bin/bash", root.launchHelper, "hermes-desktop"])
    root.close()
  }

  function resumeHermesSession(session) {
    if (!session || !/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/.test(session.id)) return
    Util.execArgv(["/usr/bin/bash", root.launchHelper, "hermes-session", session.id, session.source === "desktop" ? "desktop" : "cli"])
    root.close()
  }

  // Hermes' emergency stop holds cron, kanban and new gateway turns; it
  // never kills work already running. Only a click here toggles it.
  function toggleHermesPause() {
    if (!root.hermes || hermesControl.running) return
    root.hermesControlPending = true
    hermesControl.command = ["/usr/bin/bash", root.launchHelper, root.hermes.paused ? "hermes-unpause" : "hermes-pause"]
    hermesControl.running = true
  }

  function hermesStatusText(h) { return U.hermesStatusText(h, root.nowMs) }

  function hermesLastEndedText(h) { return U.hermesLastEndedText(h, root.nowMs) }

  function hermesCostText(h) { return U.hermesCostText(h) }

  function sessionMeta(session) { return U.sessionMeta(session, root.nowMs) }

  // Hover summary for the bar icon: the fullest window of every agent.
  function barTooltip() { return U.barTooltip(providers) }

  function limitWindows(p) { return U.limitWindows(p) }

  // The fullest window decides how much room is left.
  function bindingWindow(p) { return U.bindingWindow(p) }

  function busiestWindow() { return U.busiestWindow(providers) }

  // "2d 4h ago" while the limits are a cached copy.
  function limitsAge(p) { return U.limitsAge(p, root.nowMs) }

  function formatDuration(ms) { return U.formatDuration(ms) }

  function formatMoney(value, currency) { return U.formatMoney(value, currency) }

  function balanceDetailText(b) { return U.balanceDetailText(b) }

  function heroMeta(p) { return U.heroMeta(p) }

  function todayDate() { return U.todayDate(root.nowMs) }

  function dayLabel(date, today) { return U.dayLabel(date, today) }

  function dayTooltip(day, today) { return U.dayTooltip(day, today, provider) }

  function weekPeak(p) { return U.weekPeak(p) }

  function modelRows(p) { return U.modelRows(p) }

  function modelTooltip(row) { return U.modelTooltip(row) }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    var id = root.safeId(p.providerId)
    if (id === "") return []
    if (colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + id + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + id + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  readonly property Item barButton: barShowPercent && barPercentText !== "" ? percentButton : button
  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    leaderUsage().refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
    leaderTest: root.isLeader
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: root.ipcOwner = root.isLeader()
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: hermesControl
    running: false
    onExited: {
      root.hermesControlPending = false
      root.leaderUsage().runUpdate("normal", ["hermes"])
    }
  }

  IpcHandler {
    target: root.ipcTarget
    enabled: root.ipcOwner
    function open(): void { if (!root.viaShell("summon")) root.open() }
    function close(): void { if (!root.viaShell("hide")) root.close() }
    function show(): void { open() }
    function hide(): void { close() }
    function toggle(): void { if (!root.viaShell("toggle")) root.toggle() }
  }

  function barPressed(buttonCode) {
    if (buttonCode === Qt.RightButton) root.launchAgent()
    else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
    else root.toggle()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    visible: root.barButton === button
    bar: root.bar
    text: "\u{F16A3}"
    active: root.alarming
    tooltipText: root.barTooltip()
    onPressed: function(buttonCode) { root.barPressed(buttonCode) }
  }

  // Opt-in (barShowPercent): the icon plus the selected agent's fullest window.
  WidgetButton {
    id: percentButton
    anchors.fill: parent
    visible: root.barButton === percentButton
    bar: root.bar
    text: "\u{F16A3} " + root.barPercentText
    active: root.alarming
    tooltipText: root.barTooltip()
    onPressed: function(buttonCode) { root.barPressed(buttonCode) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling. The
    // height is fixed rather than fitted so cycling tabs never resizes the
    // card; a longer tab scrolls inside it.
    contentHeight: panel.fittedContentHeight(Style.space(640), Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if (root.hermes && t === "o") root.launchHermesApp()
        else if (root.hermes && /^[1-6]$/.test(t)) root.resumeHermesSession(root.hermes.sessions[Number(t) - 1])
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { id: panelScrollBar; policy: ScrollBar.AsNeeded }

        Column {
          id: column
          // The scrollbar sits over the right edge where the token counts are
          // right-aligned. Its gutter is kept on every tab, scrolling or not,
          // so cycling tabs never shifts the layout sideways.
          width: panelFlick.width - panelScrollBar.width - Style.space(6)
          spacing: Style.space(12)

          // ---------- Hero: provider mark · name · plan ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.plain(root.provider.providerName, 40) : ""
            meta: root.plain(root.heroMeta(root.provider), 80)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                id: heroMark
                property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                // Provider objects are rebuilt on every refresh, which churns the
                // array's identity without changing its content. Restart the fallback
                // walk only when the URLs change: re-pointing source at a URL whose
                // load already failed emits no statusChanged, so an identity-only
                // reset would strand the walker on a missing -light twin.
                property string candidatesKey: candidates.join("\n")
                property int candidateIndex: 0
                onCandidatesKeyChanged: candidateIndex = 0

                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                  // Advancing source from inside its own status change trips the
                  // binding-loop detector; defer the step one tick.
                  onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                    Qt.callLater(function() { heroMark.candidateIndex++ })
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  text: button.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch ----------
          Row {
            id: providerSwitch
            visible: root.providers.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.providers.length > 0
              ? (width - spacing * (root.providers.length - 1)) / root.providers.length
              : 0

            Repeater {
              model: root.providers

              Button {
                required property var modelData
                required property int index

                width: providerSwitch.cellWidth
                text: root.plain(modelData.providerName, 24)
                selected: index === root.providerIndex
                hasCursor: root.cursorActive && index === root.providerIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: {
                  root.cursorActive = true
                  root.selectProvider(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }

          // ---------- Hermes controls ----------
          Column {
            id: hermesSection
            visible: root.hermesSelected
            width: parent.width
            spacing: Style.space(8)

            Row {
              id: hermesActions
              width: parent.width
              spacing: Style.spacing.md
              readonly property int count: root.hermes ? 2 : 1
              readonly property real cellWidth: (width - spacing * (count - 1)) / count

              // Actions, not tabs: an icon and no border, so they don't read
              // as more of the agent switch above.
              Button {
                width: hermesActions.cellWidth
                iconText: "\u{F03CC}"
                text: "Open app"
                tooltipText: "Open Hermes desktop (o)"
                bordered: false
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.launchHermesApp()
              }

              Button {
                visible: !!root.hermes
                width: hermesActions.cellWidth
                iconText: root.hermes && root.hermes.paused ? "\u{F040A}" : "\u{F03E4}"
                text: root.hermesControlPending ? "…" : (root.hermes && root.hermes.paused ? "Resume" : "Pause")
                tooltipText: root.hermes && root.hermes.paused
                  ? "Lift the emergency stop"
                  : "Hold cron, kanban and new gateway turns"
                selected: !!root.hermes && root.hermes.paused
                bordered: false
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.toggleHermesPause()
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: !!root.hermes
              width: parent.width
              text: root.hermes && root.hermes.paused
                ? "Paused: scheduled and incoming work is on hold"
                : root.hermesStatusText(root.hermes)
              color: root.hermes && (root.hermes.paused || root.hermes.cronFailing > 0)
                ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.hermesCostText(root.hermes)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.hermesLastEndedText(root.hermes)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // ---------- Status ----------
          // What's wrong and the fix in one box. Urgent only when the agent
          // has nothing usable to show; a working agent with one source
          // missing (no Portal sign-in, cached limits) gets a quiet note.
          BorderSurface {
            id: statusBox
            readonly property bool blocking: !!root.provider && root.provider.ready !== true
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: blocking ? root.alpha(root.urgent, 0.10) : root.alpha(root.foreground, 0.05)
            borderSpec: Border.flat(blocking ? root.alpha(root.urgent, 0.35) : root.alpha(root.foreground, 0.18), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: {
                if (!root.provider) return ""
                var status = root.plain(root.provider.usageStatusText, 80)
                var help = root.plain(root.provider.authHelpText, 200)
                return help !== "" ? status + ". " + help : status
              }
              color: statusBox.blocking ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Hermes sessions ----------
          PanelSeparator {
            visible: sessionSection.visible
            foreground: root.foreground
          }

          Column {
            id: sessionSection
            visible: !!root.hermes && root.hermes.sessions.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              width: parent.width
              text: "RECENT SESSIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.hermes ? root.hermes.sessions : []

              SessionRow {
                required property var modelData
                required property int index
                width: sessionSection.width
                session: modelData
                shortcut: index + 1
              }
            }
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                textFormat: Text.PlainText
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: root.limitsAge(root.provider) !== ""
                ? "LIMITS · AS OF " + root.limitsAge(root.provider).toUpperCase()
                : "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
                stale: root.limitsAge(root.provider) !== ""
                opacity: stale ? 0.55 : 1
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))

            readonly property bool quiet: root.weekPeak(root.provider) <= 0

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: usageSection.quiet
              width: parent.width
              text: "Nothing in the last 7 days"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: usageSection.quiet ? [] : usageSection.days

              DayRow {
                required property var modelData
                required property int index

                width: usageSection.width
                day: modelData
                ratio: Number(modelData.messageCount || 0) / usageSection.peak
                // By date, not by position: the Claude stats-cache fallback can
                // hand us a window that stops short of today.
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

        }
      }
    }
  }

  // One Hermes session: click (or its number key) to pick it back up where
  // it lives, the desktop app or a terminal.
  component SessionRow: Item {
    id: sessionRow
    property var session: null
    property int shortcut: 0

    implicitHeight: sessionTitle.implicitHeight + sessionMeta.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, sessionHover.containsMouse ? 0.12 : 0.04)
    }

    Text {
      id: sessionKey
      textFormat: Text.PlainText
      text: String(sessionRow.shortcut)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(12)
    }

    Text {
      id: sessionTitle
      textFormat: Text.PlainText
      text: sessionRow.session
        ? (sessionRow.session.pinned ? "★ " : "") + sessionRow.session.title
        : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: sessionKey.right
      anchors.leftMargin: Style.space(6)
      anchors.right: sessionSource.left
      anchors.rightMargin: Style.space(8)
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.lg / 2
    }

    Text {
      id: sessionMeta
      textFormat: Text.PlainText
      text: root.sessionMeta(sessionRow.session)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      anchors.left: sessionTitle.left
      anchors.right: sessionTitle.right
      anchors.top: sessionTitle.bottom
    }

    Text {
      id: sessionSource
      textFormat: Text.PlainText
      text: sessionRow.session ? (sessionRow.session.source === "desktop" ? "app" : sessionRow.session.source) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: sessionHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.resumeHermesSession(sessionRow.session)
    }
  }

  // A limit window: label and percentage, meter with a pace mark, and the
  // reset countdown with where the window is heading. A cached copy shows
  // no pace: its percentage is older than the clock.
  component LimitRow: Column {
    id: limitRow
    property var window: null
    property bool stale: false

    readonly property bool alarming: window && window.percent >= 0.9
    readonly property var pace: stale ? null : U.pace(window, root.nowMs)

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && limitRow.window.percent >= 0
          ? Math.round(limitRow.window.percent * 100) + "%"
          : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      alarming: limitRow.alarming
      mark: limitRow.pace ? limitRow.pace.expected : -1
    }

    Text {
      id: resetText
      textFormat: Text.PlainText
      width: parent.width
      text: U.resetLine(limitRow.window, root.nowMs, !limitRow.stale)
      color: limitRow.pace && limitRow.pace.runsOut ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // Rounded track showing the percentage of the allowance used. The mark,
  // when set, is where an even pace through the window would be now.
  component Meter: Item {
    id: meter
    property real value: -1
    property real mark: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Rectangle {
      visible: meter.mark > 0 && meter.mark < 1
      width: Math.max(2, Math.round(meter.thickness * 0.5))
      height: Math.round(meter.thickness * 2.4)
      radius: width / 2
      x: Math.round(meterTrack.width * root.clamp(meter.mark, 0, 1) - width / 2)
      anchors.verticalCenter: meterTrack.verticalCenter
      color: root.dim
    }
  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: U.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? U.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
