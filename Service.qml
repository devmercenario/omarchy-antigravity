import QtQuick
import Quickshell
import Quickshell.Io

// Omarchy Service for Antigravity integration. It only answers IPC: the
// agents bar schedules every refresh itself (and honors the provider being
// switched off), so a timer here would just race it.
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME") || ""
  // This plugin's updater has to win over the stock one on PATH; without a
  // HOME, fall back to whichever updater PATH finds.
  readonly property string updateScript: home !== "" ? home + "/.local/bin/omarchy-agent-usage-update" : "omarchy-agent-usage-update"

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
    command: [root.updateScript, "--limits-only", "antigravity"]
  }
}
