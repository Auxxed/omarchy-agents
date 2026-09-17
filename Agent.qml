import QtQuick
import Quickshell
import Quickshell.Io

// One agent's usage record. FileView only watches; bytes come from
// bin/usage-bridge so a symlink or FIFO at the path cannot hang the shell.
Item {
  id: root
  visible: false

  property string agentId: ""
  property string path: ""
  property string helper: ""
  property var record: null
  property string readBuf: ""

  readonly property bool idOk: /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(agentId) && agentId.indexOf("..") < 0

  FileView {
    path: root.path
    preload: false
    watchChanges: true
    blockAllReads: true
    printErrors: false
    onFileChanged: root.reload()
  }

  Process {
    id: readProc
    running: false
    command: ["/usr/bin/python3", "-I", "-S", root.helper, "read", root.agentId]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        root.readBuf += chunk
        if (root.readBuf.length > 262144) {
          readProc.signal(15)
          root.readBuf = ""
        }
      }
    }
    onExited: function(code) {
      if (code === 0)
        root.parse(root.readBuf)
      else
        root.record = null
      root.readBuf = ""
    }
  }

  Timer {
    id: killTimer
    interval: 2000
    onTriggered: readProc.signal(9)
  }

  function reload() {
    if (!root.idOk || root.helper === "" || readProc.running)
      return
    root.readBuf = ""
    readProc.running = true
  }

  function parse(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      root.record = parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      console.warn("agents", "Ignoring bad usage record", root.agentId)
      root.record = null
    }
  }

  Component.onCompleted: reload()
  Component.onDestruction: {
    if (readProc.running) readProc.signal(15)
  }
}
