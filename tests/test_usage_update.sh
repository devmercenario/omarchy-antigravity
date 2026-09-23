#!/bin/bash
# ==============================================================================
# Usage-Updater Collector Discovery Regression Test
#
# Guards against the fork-bomb regression where a stale `*.bak` of the update
# helper itself was discovered by the `omarchy-agent-usage-*` collector glob
# and treated as a collector, re-executing the updater recursively. It also
# proves genuine collectors are still discovered and run (a bare `*` guard
# would silently skip every collector).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPDATER="$PROJECT_ROOT/bin/omarchy-agent-usage-update"

# Isolated HOME so the local collector discovery only sees what this test
# stages. On an Omarchy host the stock collectors under /usr/share/omarchy/bin
# still run, but they fail fast against an empty HOME and land in the isolated
# state dir; on CI that directory does not exist at all, so the glob expands
# to nothing and is skipped by the literal-'*' guard.
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
export XDG_STATE_HOME="$TEST_HOME/.local/state"
STATE_DIR="$XDG_STATE_HOME/omarchy/agents/usage"
mkdir -p "$HOME/.local/bin" "$STATE_DIR"

SENTINEL="$HOME/BAK_WAS_EXECUTED"

# A genuine collector: it must be discovered and run.
cat > "$HOME/.local/bin/omarchy-agent-usage-faketest" <<'EOF'
#!/bin/bash
echo '{"id":"faketest","name":"Fake Test Agent","ready":true,"totalPrompts":1}'
EOF
chmod +x "$HOME/.local/bin/omarchy-agent-usage-faketest"

# A stale backup of the updater itself. If the discovery guard regresses, it
# is treated as a collector and executed; the sentinel records that. It is
# deliberately non-recursive so this test can never fork-bomb.
cat > "$HOME/.local/bin/omarchy-agent-usage-update.bak" <<EOF
#!/bin/bash
touch "$SENTINEL"
echo '{"id":"update.bak","name":"SHOULD-NOT-RUN"}'
EOF
chmod +x "$HOME/.local/bin/omarchy-agent-usage-update.bak"

# Full (run-all) refresh. Without the guard this would execute the .bak.
timeout 60 "$UPDATER" --limits-only

# Positive control: the real collector was discovered and its record written.
[[ -f "$STATE_DIR/faketest.json" ]] || {
  echo "❌ Assertion failed: faketest collector was not discovered/run." >&2
  exit 1
}

# The regression under test: the .bak must never have been executed.
[[ ! -f "$SENTINEL" ]] || {
  echo "❌ Assertion failed: *.bak was executed as a collector." >&2
  exit 1
}
[[ ! -f "$STATE_DIR/update.bak.json" ]] || {
  echo "❌ Assertion failed: *.bak wrote a state record." >&2
  exit 1
}

echo "✅ Collector discovery guard passed: real collectors run, *.bak is ignored."
