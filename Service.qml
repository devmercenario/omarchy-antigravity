import QtQuick
import Quickshell
import Quickshell.Io

// Omarchy Service for Antigravity integration
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME") || ""

  IpcHandler {
    target: "devmercenario.antigravity"

    function auth(): string {
      authProcess.running = true
      return "auth-launched"
    }

    function refresh(): string {
      refreshProcess.running = true
      return "refreshing"
    }

    function status(): string {
      return "running"
    }
  }

  Process {
    id: authProcess
    running: false
    command: ["omarchy-launch-tui", "--app-id=org.omarchy.agent", "agy"]
  }

  Process {
    id: refreshProcess
    running: false
    command: [home + "/.local/bin/omarchy-agent-usage-update", "--limits-only", "antigravity"]
  }

  Timer {
    id: periodicRefresh
    interval: 900000 // 15 minutes
    running: true
    repeat: true
    onTriggered: {
      if (!refreshProcess.running) refreshProcess.running = true
    }
  }
}
