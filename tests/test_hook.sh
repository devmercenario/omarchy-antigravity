#!/bin/bash
# ==============================================================================
# Integration Test: Omarchy Post-Update Hook (90-antigravity.hook)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SRC="$PROJECT_ROOT/hooks/post-update.d/90-antigravity.hook"

echo "🧪 Running post-update hook persistence tests..."

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-test-hook.XXXXXX")
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
echo "  ▶ Test Case 1: Hook restores antigravity when agent file was wiped..."
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
if [[ ! -f "$AGENT_FILE" ]] || [[ "$(cat "$AGENT_FILE")" != "antigravity" ]]; then
  echo "❌ Assertion failed: hook did not restore defaults/agent to antigravity when consented." >&2
  exit 1
fi

SHIM_FILE="$TEST_HOME/.local/bin/gemini"
if [[ -f "$SHIM_FILE" ]]; then
  echo "❌ Assertion failed: hook should not create a gemini shim." >&2
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

# Test Case 3: User explicitly disabled the antigravity provider
echo "  ▶ Test Case 3: Hook does NOT re-enable an explicitly disabled provider..."
cat <<'EOF' > "$TEST_HOME/.config/omarchy/shell.json"
{
  "bar": {
    "layout": {
      "right": [
        {
          "id": "omarchy.agents",
          "providers": {
            "antigravity": { "enabled": false }
          }
        }
      ]
    }
  }
}
EOF

bash "$HOOK_SRC"

if ! jq -e '.bar.layout.right[] | select(.id == "omarchy.agents") | .providers.antigravity.enabled == false' "$SHELL_JSON" >/dev/null 2>&1; then
  echo "❌ Assertion failed: hook re-enabled an explicitly disabled provider!" >&2
  exit 1
fi

echo "  ✅ Test Case 3 passed: Hook respects an explicit provider disable!"

# The bar watches shell.json and the hook runs on every `omarchy update`:
# when nothing changes the file must not be rewritten at all.
file_id() {
  stat -c '%i %y %a' "$SHELL_JSON"
}
no_temp_files() {
  local leftovers
  leftovers=$(find "$TEST_HOME/.config/omarchy" -maxdepth 1 -name 'shell.json.*' | head -n 1)
  [[ -z "$leftovers" ]] || { echo "❌ Assertion failed: hook left a temp file behind: $leftovers" >&2; exit 1; }
}

# Test Case 4: a second run over an already-enabled config is a no-op, and a
# real change keeps the file's mode.
echo "  ▶ Test Case 4: Hook leaves an unchanged shell.json untouched..."
cat <<'EOF2' > "$SHELL_JSON"
{
  "bar": {
    "layout": {
      "right": [
        { "id": "omarchy.agents", "providers": { "claude": { "enabled": true } } }
      ]
    }
  }
}
EOF2
chmod 640 "$SHELL_JSON"
bash "$HOOK_SRC"
if [[ "$(stat -c '%a' "$SHELL_JSON")" != "640" ]]; then
  echo "❌ Assertion failed: hook did not keep shell.json's mode." >&2
  exit 1
fi
before=$(file_id)
sleep 0.05
bash "$HOOK_SRC"
if [[ "$(file_id)" != "$before" ]]; then
  echo "❌ Assertion failed: hook rewrote shell.json although nothing changed." >&2
  exit 1
fi
no_temp_files
echo "  ✅ Test Case 4 passed!"

# Test Case 5: odd layouts (no right section, entries without string ids,
# non-object entries) neither break the hook nor touch the file.
echo "  ▶ Test Case 5: Hook tolerates odd layouts without rewriting them..."
cat <<'EOF2' > "$SHELL_JSON"
{"bar": {"layout": {"left": [{"id": 7}, "clock", null, {"name": "no id"}]}}}
EOF2
before=$(file_id)
bash "$HOOK_SRC"
if [[ "$(file_id)" != "$before" ]]; then
  echo "❌ Assertion failed: hook rewrote a config without agents widgets." >&2
  exit 1
fi
no_temp_files
echo '{"theme": "x"}' > "$SHELL_JSON"
before=$(file_id)
bash "$HOOK_SRC"
[[ "$(file_id)" == "$before" ]] || { echo "❌ Assertion failed: hook rewrote a config without a bar." >&2; exit 1; }
no_temp_files

# Agents widgets in any section (and <user>.agents clones) are handled.
cat <<'EOF2' > "$SHELL_JSON"
{"bar": {"layout": {"left": [{"id": "me.agents"}], "right": [{"id": 3}]}}}
EOF2
bash "$HOOK_SRC"
if ! jq -e '.bar.layout.left[0].providers.antigravity.enabled == true' "$SHELL_JSON" >/dev/null; then
  echo "❌ Assertion failed: hook did not enable antigravity in a left-section clone widget." >&2
  exit 1
fi
no_temp_files
echo "  ✅ Test Case 5 passed!"

# Test Case 6 (#1): the "gemini" default earlier releases set opened the
# deprecated Gemini CLI once its agy shim was removed. The plugin's own choice
# (opt-in marker present) moves to antigravity; a user's Gemini pick stays.
echo "  ▶ Test Case 6: Legacy plugin-set 'gemini' default moves to antigravity..."
AGENT_FILE="$TEST_HOME/.config/omarchy/defaults/agent"
touch "$TEST_HOME/.config/omarchy/antigravity.default"
echo "gemini" > "$AGENT_FILE"
bash "$HOOK_SRC"
[[ "$(cat "$AGENT_FILE")" == "antigravity" ]] \
  || { echo "❌ Assertion failed: hook kept the legacy plugin 'gemini' default." >&2; exit 1; }

rm -f "$TEST_HOME/.config/omarchy/antigravity.default"
echo "gemini" > "$AGENT_FILE"
bash "$HOOK_SRC"
[[ "$(cat "$AGENT_FILE")" == "gemini" ]] \
  || { echo "❌ Assertion failed: hook overrode a user's own Gemini default." >&2; exit 1; }
echo "  ✅ Test Case 6 passed!"

echo "🎉 All hook tests passed successfully!"
