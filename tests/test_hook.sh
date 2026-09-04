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
export PATH="$TEST_HOME/.local/bin:$PATH"

mkdir -p "$TEST_HOME/.config/omarchy/defaults"
mkdir -p "$TEST_HOME/.local/bin"

# Simulate system update having reset default agent to something else
echo "claude" > "$TEST_HOME/.config/omarchy/defaults/agent"

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
echo "  ▶ Executing 90-antigravity.hook..."
bash "$HOOK_SRC"

# 1. Assert default agent restored to gemini
AGENT_FILE="$TEST_HOME/.config/omarchy/defaults/agent"
if [[ ! -f "$AGENT_FILE" ]] || [[ "$(cat "$AGENT_FILE")" != "gemini" ]]; then
  echo "❌ Assertion failed: hook did not restore defaults/agent to gemini." >&2
  exit 1
fi

# 2. Assert gemini shim was created
SHIM_FILE="$TEST_HOME/.local/bin/gemini"
if [[ ! -x "$SHIM_FILE" ]]; then
  echo "❌ Assertion failed: hook did not restore ~/.local/bin/gemini shim." >&2
  exit 1
fi
if ! grep -q "agy --dangerously-skip-permissions" "$SHIM_FILE"; then
  echo "❌ Assertion failed: shim does not contain agy command." >&2
  exit 1
fi

# 3. Assert shell.json has antigravity enabled
SHELL_JSON="$TEST_HOME/.config/omarchy/shell.json"
if ! jq -e '.bar.layout.right[] | select(.id == "omarchy.agents") | .providers.antigravity.enabled == true' "$SHELL_JSON" >/dev/null 2>&1; then
  echo "❌ Assertion failed: hook did not enable antigravity in shell.json." >&2
  exit 1
fi

echo "  ✅ Post-update hook restored all configs and shims correctly!"
echo "🎉 Hook tests passed successfully!"
