#!/bin/bash
# ==============================================================================
# Integration Test: Installer and Uninstaller Lifecycle
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🧪 Running installer & uninstaller integration tests..."

# Create an isolated temporary HOME directory
TEST_HOME=$(mktemp -d "/tmp/omarchy-test-home.XXXXXX")
cleanup() {
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Setup mock environment
export HOME="$TEST_HOME"
export XDG_STATE_HOME="$TEST_HOME/.local/state"
export XDG_CACHE_HOME="$TEST_HOME/.cache"
export XDG_CONFIG_HOME="$TEST_HOME/.config"
export PATH="$TEST_HOME/.local/bin:$PATH"

# Create mock dependencies in TEST_HOME/.local/bin
mkdir -p "$TEST_HOME/.local/bin"
mkdir -p "$TEST_HOME/.config/omarchy"

# Create a mock shell.json
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

# Mock secret-tool and agy
cat <<'EOF' > "$TEST_HOME/.local/bin/secret-tool"
#!/bin/bash
exit 0
EOF
chmod +x "$TEST_HOME/.local/bin/secret-tool"

cat <<'EOF' > "$TEST_HOME/.local/bin/agy"
#!/bin/bash
echo "agy mock"
EOF
chmod +x "$TEST_HOME/.local/bin/agy"

# Pre-seed a fake pre-existing update helper to verify the installer backs it
# up (it shadows the stock Omarchy helper) and the uninstaller restores it.
cat <<'EOF' > "$TEST_HOME/.local/bin/omarchy-agent-usage-update"
#!/bin/bash
echo "preexisting helper"
EOF
chmod +x "$TEST_HOME/.local/bin/omarchy-agent-usage-update"

# Pre-seed a user-customized agents plugin so we can verify the installer
# backs up existing UI edits and the uninstaller restores them.
TEST_USER_ID="${USER:-$(id -un)}.agents"
TEST_PLUGIN_DIR="$TEST_HOME/.config/omarchy/plugins/$TEST_USER_ID"
mkdir -p "$TEST_PLUGIN_DIR/assets"
printf '// user custom panel\n' > "$TEST_PLUGIN_DIR/Panel.qml"
printf '// user custom main\n' > "$TEST_PLUGIN_DIR/Main.qml"
printf '<svg>user custom</svg>\n' > "$TEST_PLUGIN_DIR/assets/antigravity.svg"

# 1. Run install.sh with --statusline flag
echo "  ▶ Testing install.sh in isolated environment..."
"$PROJECT_ROOT/install.sh" --statusline >/dev/null 2>&1

# Assert installed binaries
for bin in omarchy-agent-usage-antigravity omarchy-agent-usage-update omarchy-antigravity omarchy-antigravity-statusline; do
  target="$TEST_HOME/.local/bin/$bin"
  if [[ ! -x "$target" ]]; then
    echo "❌ Assertion failed: $target was not installed or is not executable." >&2
    exit 1
  fi
done

# Assert statusline script and settings.json configuration
if [[ ! -x "$TEST_HOME/.gemini/antigravity-cli/statusline.sh" ]]; then
  echo "❌ Assertion failed: statusline.sh was not installed to ~/.gemini/antigravity-cli/." >&2
  exit 1
fi

if ! jq -e '.statusLine.enabled == true' "$TEST_HOME/.gemini/antigravity-cli/settings.json" >/dev/null 2>&1; then
  echo "❌ Assertion failed: statusLine was not enabled in settings.json." >&2
  exit 1
fi

# Assert non-conflicting: gemini shim should NOT be installed
if [[ -f "$TEST_HOME/.local/bin/gemini" ]]; then
  echo "❌ Assertion failed: gemini shim should not be installed." >&2
  exit 1
fi

# Assert default agent configuration
AGENT_FILE="$TEST_HOME/.config/omarchy/defaults/agent"
if [[ ! -f "$AGENT_FILE" ]] || [[ "$(cat "$AGENT_FILE")" != "antigravity" ]]; then
  echo "❌ Assertion failed: $AGENT_FILE is not set to antigravity." >&2
  exit 1
fi

# Assert shell.json has antigravity enabled
SHELL_JSON="$TEST_HOME/.config/omarchy/shell.json"
if ! jq -e '.bar.layout.right[] | select(.id == "omarchy.agents") | .providers.antigravity.enabled == true' "$SHELL_JSON" >/dev/null 2>&1; then
  echo "❌ Assertion failed: antigravity was not enabled in shell.json." >&2
  exit 1
fi

# Assert hook installed
HOOK_FILE="$TEST_HOME/.config/omarchy/hooks/post-update.d/90-antigravity.hook"
if [[ ! -x "$HOOK_FILE" ]]; then
  echo "❌ Assertion failed: $HOOK_FILE was not installed or is not executable." >&2
  exit 1
fi

echo "  ✅ install.sh passed all assertions!"

# Assert user UI edits were backed up and the plugin UI installed
if [[ ! -f "$TEST_PLUGIN_DIR/Panel.qml.bak" || ! -f "$TEST_PLUGIN_DIR/Main.qml.bak" ]]; then
  echo "❌ Assertion failed: user UI edits were not backed up by install.sh." >&2
  exit 1
fi
if ! cmp -s "$PROJECT_ROOT/ui/Panel.qml" "$TEST_PLUGIN_DIR/Panel.qml"; then
  echo "❌ Assertion failed: plugin Panel.qml was not installed." >&2
  exit 1
fi
if ! grep -q "user custom panel" "$TEST_PLUGIN_DIR/Panel.qml.bak"; then
  echo "❌ Assertion failed: user Panel.qml backup content is wrong." >&2
  exit 1
fi

# Assert the pre-existing update helper was backed up and replaced
if [[ ! -f "$TEST_HOME/.local/bin/omarchy-agent-usage-update.bak" ]]; then
  echo "❌ Assertion failed: pre-existing update helper was not backed up." >&2
  exit 1
fi
if ! grep -q "preexisting helper" "$TEST_HOME/.local/bin/omarchy-agent-usage-update.bak"; then
  echo "❌ Assertion failed: update helper backup content is wrong." >&2
  exit 1
fi
if ! grep -q "Update local usage records" "$TEST_HOME/.local/bin/omarchy-agent-usage-update"; then
  echo "❌ Assertion failed: plugin update helper was not installed." >&2
  exit 1
fi

# 2. Run uninstall.sh
echo "  ▶ Testing uninstall.sh in isolated environment..."
"$PROJECT_ROOT/uninstall.sh" >/dev/null 2>&1

# Assert binaries removed
if [[ -f "$TEST_HOME/.local/bin/omarchy-agent-usage-antigravity" ]] || \
   [[ -f "$TEST_HOME/.local/bin/omarchy-antigravity" ]] || \
   [[ -f "$TEST_HOME/.local/bin/omarchy-antigravity-statusline" ]]; then
  echo "❌ Assertion failed: binaries were not removed during uninstall." >&2
  exit 1
fi

# Assert statusline script and settings removed
if [[ -f "$TEST_HOME/.gemini/antigravity-cli/statusline.sh" ]]; then
  echo "❌ Assertion failed: statusline.sh was not removed during uninstall." >&2
  exit 1
fi

if jq -e '.statusLine' "$TEST_HOME/.gemini/antigravity-cli/settings.json" >/dev/null 2>&1; then
  echo "❌ Assertion failed: statusLine was not deleted from settings.json during uninstall." >&2
  exit 1
fi

# Assert hook removed
if [[ -f "$HOOK_FILE" ]]; then
  echo "❌ Assertion failed: hook was not removed during uninstall." >&2
  exit 1
fi

# Assert default agent reset
if [[ -f "$AGENT_FILE" ]]; then
  echo "❌ Assertion failed: default agent was not cleared during uninstall." >&2
  exit 1
fi

echo "  ✅ uninstall.sh passed all assertions!"

# Assert user UI edits were restored by the uninstaller
if ! grep -q "user custom panel" "$TEST_PLUGIN_DIR/Panel.qml"; then
  echo "❌ Assertion failed: user Panel.qml was not restored on uninstall." >&2
  exit 1
fi
if ! grep -q "user custom main" "$TEST_PLUGIN_DIR/Main.qml"; then
  echo "❌ Assertion failed: user Main.qml was not restored on uninstall." >&2
  exit 1
fi
if [[ -f "$TEST_PLUGIN_DIR/Panel.qml.bak" ]]; then
  echo "❌ Assertion failed: Panel.qml.bak should have been consumed on uninstall." >&2
  exit 1
fi
if ! grep -q "preexisting helper" "$TEST_HOME/.local/bin/omarchy-agent-usage-update"; then
  echo "❌ Assertion failed: pre-existing update helper was not restored on uninstall." >&2
  exit 1
fi
if [[ -f "$TEST_HOME/.local/bin/omarchy-agent-usage-update.bak" ]]; then
  echo "❌ Assertion failed: update helper backup should have been consumed on uninstall." >&2
  exit 1
fi

echo "🎉 Installer and uninstaller tests passed successfully!"
