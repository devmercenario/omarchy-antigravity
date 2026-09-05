#!/bin/bash
# ==============================================================================
# Integration Test: Omarchy Post-Update Hook (90-antigravity.hook)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SRC="$PROJECT_ROOT/hooks/post-update.d/90-antigravity.hook"

echo "🧪 Running post-update hook persistence tests..."

TEST_HOME=$(mktemp -d "/tmp/omarchy-test-hook.XXXXXX")
cleanup() {
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

export HOME="$TEST_HOME"
export XDG_STATE_HOME="$TEST_HOME/.local/state"
export XDG_CACHE_HOME="$TEST_HOME/.cache"
export XDG_CONFIG_HOME="$TEST_HOME/.config"
export PATH="$TEST_HOME/.local/bin:$PATH"

mkdir -p "$TEST_HOME/.config/omarchy/defaults"
mkdir -p "$TEST_HOME/.local/bin"

# Test Case 1: System update reset agent file, but user opted into Antigravity
echo "  ▶ Test Case 1: Hook restores gemini when agent file was wiped..."
touch "$TEST_HOME/.config/omarchy/antigravity.default"
rm -f "$TEST_HOME/.config/omarchy/defaults/agent"

# Simulate shell.json
cat <<'EOF' > "$TEST_HOME/.config/omarchy/shell.json"
{
  "bar": {
    "layout": {
      "right": [
        {
          "id": "omarchy.agents",
          "providers": {
            "claude": { "enabled": true }
          }
        }
      ]
    }
  }
}
EOF

# Run hook
bash "$HOOK_SRC"

AGENT_FILE="$TEST_HOME/.config/omarchy/defaults/agent"
if [[ ! -f "$AGENT_FILE" ]] || [[ "$(cat "$AGENT_FILE")" != "gemini" ]]; then
  echo "❌ Assertion failed: hook did not restore defaults/agent to gemini when consented." >&2
  exit 1
fi

SHIM_FILE="$TEST_HOME/.local/bin/gemini"
if [[ ! -x "$SHIM_FILE" ]]; then
  echo "❌ Assertion failed: hook did not restore ~/.local/bin/gemini shim." >&2
  exit 1
fi

SHELL_JSON="$TEST_HOME/.config/omarchy/shell.json"
if ! jq -e '.bar.layout.right[] | select(.id == "omarchy.agents") | .providers.antigravity.enabled == true' "$SHELL_JSON" >/dev/null 2>&1; then
  echo "❌ Assertion failed: hook did not enable antigravity in shell.json." >&2
  exit 1
fi

echo "  ✅ Test Case 1 passed!"

# Test Case 2: User explicitly switched default agent to another agent (e.g. claude)
echo "  ▶ Test Case 2: Hook does NOT overwrite user configuration without consent..."
touch "$TEST_HOME/.config/omarchy/antigravity.default"
echo "claude" > "$AGENT_FILE"

bash "$HOOK_SRC"

if [[ "$(cat "$AGENT_FILE")" != "claude" ]]; then
  echo "❌ Assertion failed: hook overwrote user default agent without consent!" >&2
  exit 1
fi

if [[ -f "$TEST_HOME/.config/omarchy/antigravity.default" ]]; then
  echo "❌ Assertion failed: hook did not remove antigravity.default when user chose another agent." >&2
  exit 1
fi

echo "  ✅ Test Case 2 passed: Hook strictly respects user configuration!"
echo "🎉 All hook tests passed successfully!"
