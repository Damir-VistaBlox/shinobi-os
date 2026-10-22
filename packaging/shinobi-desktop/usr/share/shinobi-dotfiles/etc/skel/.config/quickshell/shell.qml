import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "ProviderStatus.js" as ProviderStatus
import "PanelModel.js" as PanelModel

// Every Text in this shell is PlainText. Qt's default format treats a string that looks like
// markup as rich text and fetches what it points at, and the strings shown here are not all
// ours: the active window's title is whatever a web page or a terminal says it is (a target's
// output can set a terminal's title), and an <img> in one would make the shell make a network
// request on its own, outside the gate, from the operator's workstation.
//
// Shinobi's intentionally small Quickshell surface. It replaces Waybar, but
// leaves application picking to wofi and notifications to mako. Keeping the
// shell focused makes it fast to start and easy to reason about on a live ISO.
ShellRoot {
  id: root

  Theme { id: theme }

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string engagementPath: stateHome + "/shinobi/current-engagement"
  property string engagement: "no engagement"
  readonly property string workspace: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.name : "1"
  property string clockText: ""
  property string activeWindow: "desktop"
  property string agentState: "offline"
  property string contextState: "offline"
  property string trustProfile: "observer"
  // What the default LLM provider could do right now, from `shinobi provider
  // readiness --json` (ProviderStatus.js shortens it). Unknown until the first answer.
  property string providerLabel: "LLM ?"
  property string providerTone: "muted"
  property bool providerAnswered: false
  // The panel (Panel.qml): closed until asked for. Its content is rebuilt from the two
  // reports below whenever either arrives, and while it is open from the clock too, since
  // "3m ago" moves without a new report.
  property bool panelOpen: false
  property var panelContent: ({ sections: [], footer: "" })
  property string readinessText: ""
  property var panelStatusText: null
  property bool panelAnswered: false

  function run(command) {
    // Process has one mutable command slot. Ignore an accidental rapid
    // double-click instead of replacing a command that is still executing.
    if (action.running) return
    action.command = ["sh", "-c", command]
    action.running = true
  }

  function setEngagement(value) {
    var normalized = String(value).trim()
    var next = normalized.length > 0 ? normalized : "no engagement"
    var changed = next !== engagement
    engagement = next
    // Clearance is per engagement, so the provider's readiness changes with it.
    if (changed) refreshProvider()
  }

  function refreshEngagement() {
    if (!engagementProbe.running) engagementProbe.running = true
  }

  function refreshActiveWindow() {
    if (!windowProbe.running) windowProbe.running = true
  }

  function refreshControlPlane() {
    if (!controlProbe.running) controlProbe.running = true
  }

  function refreshProvider() {
    if (providerProbe.running) return
    root.providerAnswered = false
    providerProbe.running = true
  }

  function updateProvider(text) {
    var summary = ProviderStatus.summarize(text)
    root.providerAnswered = true
    root.providerLabel = summary.label
    root.providerTone = summary.tone
    root.readinessText = String(text)
    if (root.panelOpen) root.rebuildPanel()
  }

  function rebuildPanel() {
    root.panelContent = PanelModel.build(root.panelStatusText, ProviderStatus.rows(root.readinessText), Date.now())
  }

  function refreshPanel() {
    if (panelProbe.running) return
    root.panelAnswered = false
    panelProbe.running = true
  }

  function updatePanel(text) {
    root.panelStatusText = String(text)
    root.rebuildPanel()
  }

  function setPanel(open) {
    root.panelOpen = open
    if (open) {
      // Whatever was shown when it was last closed is old: forget it, show "loading" (the
      // providers are known already) and ask again. null, not "", because "" means the probe
      // answered nothing.
      root.panelStatusText = null
      root.rebuildPanel()
      root.refreshPanel()
      root.refreshProvider()
    }
  }

  function updateControlPlane(line) {
    try {
      var value = JSON.parse(String(line))
      root.agentState = value.status === "completed" ? "ready" : "error"
      if (value.result && value.result.profile) root.trustProfile = value.result.profile
    } catch (error) {
      root.agentState = "offline"
    }
    if (!contextProbe.running) contextProbe.running = true
  }

  function updateContext(line) {
    try {
      var value = JSON.parse(String(line))
      root.contextState = value.status === "completed" ? "ready" : "error"
    } catch (error) {
      root.contextState = "offline"
    }
  }

  Component.onCompleted: {
    root.clockText = Qt.formatDateTime(new Date(), "ddd · dd MMM · HH:mm")
    root.refreshEngagement()
    root.refreshActiveWindow()
    root.refreshControlPlane()
    root.refreshProvider()
  }

  Timer {
    // The displayed clock has minute precision. Waking only four times per
    // minute keeps the panel cheap while still updating close to the minute.
    interval: 15000
    running: true
    repeat: true
    onTriggered: root.clockText = Qt.formatDateTime(new Date(), "ddd · dd MMM · HH:mm")
  }

  // Only while the panel is open: a closed panel costs nothing.
  Timer {
    interval: 4000
    running: root.panelOpen
    repeat: true
    onTriggered: {
      root.refreshPanel()
      root.refreshProvider()
    }
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: {
      root.refreshControlPlane()
      root.refreshProvider()
    }
  }

  // FileView gives immediate updates for normal engagement changes. The slow
  // probe also covers the initial absent-file case and filesystems where a
  // rename-based write does not produce a watcher event.
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.refreshEngagement()
  }

  // Use Hyprland's own IPC rather than guessing app identity from desktop
  // files. This keeps the panel useful for terminal-heavy engagements too.
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: root.refreshActiveWindow()
  }

  Process {
    id: action
  }

  Process {
    id: controlProbe
    command: ["sh", "-c", "shinobi agent status 2>/dev/null | tr -d '\\n'"]
    stdout: SplitParser { onRead: function(line) { root.updateControlPlane(line) } }
  }

  Process {
    id: providerProbe
    // One line, newline-terminated, so the parser hands it over whole. A failed
    // command prints only the newline (stderr is dropped): the exit handler turns
    // "no answer" into "unknown" instead of leaving the last good answer on screen.
    command: ["sh", "-c", "shinobi provider readiness --json 2>/dev/null | tr -d '\\n'; echo"]
    stdout: SplitParser { onRead: function(line) { if (String(line).length > 0) root.updateProvider(line) } }
    onExited: function(exitCode, exitStatus) { if (!root.providerAnswered) root.updateProvider("") }
  }

  Process {
    id: panelProbe
    // Same shape as the provider probe above: one newline-terminated line, and "no answer"
    // is reported as such (an empty line) so the panel says unavailable instead of keeping
    // what it showed before.
    // A deadline, so a report that never comes (a pipe where a log should be, a stuck disk)
    // ends as "unavailable" instead of leaving the last answer on screen for good.
    command: ["sh", "-c", "timeout 8 shinobi panel status --json 2>/dev/null | tr -d '\\n'; echo"]
    stdout: SplitParser {
      onRead: function(line) {
        if (String(line).length === 0) return
        root.panelAnswered = true
        root.updatePanel(line)
      }
    }
    onExited: function(exitCode, exitStatus) { if (!root.panelAnswered) root.updatePanel("") }
  }

  // `shinobi shellctl toggle-panel` (and the key bound to it) reach the shell through here.
  IpcHandler {
    target: "panel"
    function toggle(): void { root.setPanel(!root.panelOpen) }
    function open(): void { root.setPanel(true) }
    function close(): void { root.setPanel(false) }
  }

  Panel {
    colors: theme
    visible: root.panelOpen
    content: root.panelContent
    onCloseRequested: root.setPanel(false)
    onCommandRequested: function(command) { root.run(command) }
  }

  Process {
    id: contextProbe
    command: ["sh", "-c", "shinobi context 2>/dev/null | tr -d '\\n'"]
    stdout: SplitParser { onRead: function(line) { root.updateContext(line) } }
  }

  Process {
    id: windowProbe
    command: ["sh", "-c", "hyprctl activewindow -j 2>/dev/null | jq -r '.title // empty' | head -n 1"]
    stdout: SplitParser {
      onRead: function(line) {
        var title = String(line).trim()
        root.activeWindow = title.length > 0 ? title : "desktop"
      }
    }
  }

  Process {
    id: engagementProbe
    command: ["sh", "-c", "f=${SHINOBI_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/shinobi/current-engagement}; [ -f \"$f\" ] && cat \"$f\" || printf 'no engagement\\n'"]
    stdout: SplitParser {
      onRead: function(line) { root.setEngagement(line) }
    }
  }

  FileView {
    id: engagementFile
    path: root.engagementPath
    watchChanges: true
    // No engagement is the normal first-boot condition, not an error users
    // should see in their journal.
    printErrors: false
    onLoaded: root.setEngagement(text())
    onFileChanged: reload()
    onLoadFailed: root.setEngagement("")
  }

  component ShellButton: Rectangle {
    id: button
    property string label: ""
    property string command: ""
    property color foreground: theme.foreground
    implicitWidth: text.implicitWidth + 20
    implicitHeight: 28
    radius: 0
    color: hover.hovered ? theme.accent : "transparent"

    Text {
      id: text
      anchors.centerIn: parent
      text: button.label
      textFormat: Text.PlainText
      color: hover.hovered ? theme.background : button.foreground
      font.family: "JetBrainsMono Nerd Font Mono"
      font.pixelSize: 13
      font.bold: true
    }
    HoverHandler { id: hover }
    TapHandler { onTapped: root.run(button.command) }
  }

  component StatusPill: Rectangle {
    id: pill
    property string label: ""
    property color ink: theme.foreground
    property color fill: "transparent"
    // Optional: what a click runs. A pill with none is only a readout.
    property string command: ""
    signal activated()
    implicitWidth: pillText.implicitWidth + 18
    implicitHeight: 26
    radius: 3
    color: fill
    border.color: theme.border
    border.width: 1

    Text {
      id: pillText
      anchors.centerIn: parent
      text: pill.label
      textFormat: Text.PlainText
      color: pill.ink
      font.family: "JetBrainsMono Nerd Font Mono"
      font.pixelSize: 12
      font.bold: true
    }
    TapHandler {
      onTapped: {
        if (pill.command.length > 0) root.run(pill.command)
        pill.activated()
      }
    }
  }

  Variants {
    model: Quickshell.screens
    delegate: PanelWindow {
      required property var modelData
      screen: modelData
      anchors { top: true; left: true; right: true }
      implicitHeight: 42
      color: "transparent"
      exclusionMode: ExclusionMode.Auto
      WlrLayershell.namespace: "shinobi-shell"
      WlrLayershell.layer: WlrLayer.Top

      Rectangle {
        anchors.fill: parent
        color: theme.background
        border.color: theme.border
        border.width: 1

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 8
          anchors.rightMargin: 8
          spacing: 6

          StatusPill {
            label: "󰣇  SHINOBI"
            ink: theme.accent
            fill: theme.surface
            onActivated: root.setPanel(!root.panelOpen)
          }
          StatusPill {
            label: root.agentState === "ready" ? "󰚩  AI " + root.trustProfile : "󰚩  AI " + root.agentState
            ink: root.agentState === "ready" ? theme.good : theme.muted
            fill: root.agentState === "ready" ? theme.safeSurface : theme.inactiveSurface
          }
          // Which LLM the agent would use and, if it could not, the first thing in
          // the way. A click opens the provider menu, where the fix is.
          StatusPill {
            label: root.providerLabel
            ink: root.providerTone === "good" ? theme.good : (root.providerTone === "warn" ? theme.warn : theme.muted)
            fill: root.providerTone === "good" ? theme.safeSurface : theme.inactiveSurface
            command: "shinobi-menu provider"
          }
          StatusPill {
            label: "CTX " + root.contextState
            ink: root.contextState === "ready" ? theme.good : theme.muted
            fill: root.contextState === "ready" ? theme.safeSurface : theme.inactiveSurface
          }
          ShellButton { label: "WS " + root.workspace; command: "shinobi-menu keybindings" }

          Text {
            Layout.fillWidth: true
            text: "󰆍  " + root.activeWindow
            textFormat: Text.PlainText
            color: theme.foreground
            elide: Text.ElideRight
            font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: 12
          }

          StatusPill {
            label: root.engagement === "no engagement" ? "󱊖  NO SCOPE" : "󰯢  " + root.engagement
            ink: root.engagement === "no engagement" ? theme.muted : theme.good
            fill: root.engagement === "no engagement" ? theme.inactiveSurface : theme.safeSurface
            onActivated: root.setPanel(!root.panelOpen)
          }

          Text {
            text: "•"
            textFormat: Text.PlainText
            color: theme.border
            font.pixelSize: 16
          }

          Text {
            text: root.clockText
            textFormat: Text.PlainText
            color: theme.foreground
            font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: 12
          }

          /* Keep control glyphs compact so the engagement and active-window
             context remain readable on laptop-width displays. */
          Item { implicitWidth: 2 }

          /* System actions intentionally remain direct: they are the
             dependable escape hatches in a live engagement. */
          Row {
            spacing: 2
            ShellButton { label: "󰕾"; command: "shinobi-audio mute-toggle" }
            ShellButton { label: "󰤨"; command: "shinobi-network menu" }
            ShellButton { label: "󰂯"; command: "shinobi-bluetooth menu" }
            ShellButton { label: "󰐥"; command: "shinobi-power menu" }
          }
        }
      }
    }
  }
}
