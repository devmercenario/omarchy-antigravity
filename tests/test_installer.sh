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

# 1. Run install.sh
echo "  ▶ Testing install.sh in isolated environment..."
"$PROJECT_ROOT/install.sh" >/dev/null 2>&1

# Assert installed binaries
for bin in omarchy-agent-usage-antigravity omarchy-agent-usage-update omarchy-antigravity gemini; do
  target="$TEST_HOME/.local/bin/$bin"
  if [[ ! -x "$target" ]]; then
    echo "❌ Assertion failed: $target was not installed or is not executable." >&2
    exit 1
  fi
done

# Assert default agent configuration
AGENT_FILE="$TEST_HOME/.config/omarchy/defaults/agent"
if [[ ! -f "$AGENT_FILE" ]] || [[ "$(cat "$AGENT_FILE")" != "gemini" ]]; then
  echo "❌ Assertion failed: $AGENT_FILE is not set to gemini." >&2
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

# 2. Run uninstall.sh
echo "  ▶ Testing uninstall.sh in isolated environment..."
"$PROJECT_ROOT/uninstall.sh" >/dev/null 2>&1

# Assert binaries removed
if [[ -f "$TEST_HOME/.local/bin/omarchy-agent-usage-antigravity" ]] || [[ -f "$TEST_HOME/.local/bin/gemini" ]]; then
  echo "❌ Assertion failed: binaries were not removed during uninstall." >&2
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
echo "🎉 Installer and uninstaller tests passed successfully!"
