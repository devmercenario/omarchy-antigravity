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
    // This plugin's updater wins over the stock one when it is installed;
    // on Omarchy 4.5 it is handed back and the stock one runs. "agy" is
    // 4.5's own Antigravity collector; each updater skips the id it does not
    // know. HOME arrives as $0, never interpolated into the script.
    command: ["bash", "-c",
              "u=\"$0/.local/bin/omarchy-agent-usage-update\"; [[ -n $0 && -x $u ]] || u=omarchy-agent-usage-update; exec \"$u\" --limits-only antigravity agy",
              root.home]
  }
}
