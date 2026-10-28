#!/bin/bash
# ==============================================================================
# Functional Test: omarchy-antigravity CLI Helper
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_ROOT/bin/omarchy-antigravity"

# Isolated HOME with an empty keyring, so `status` never reads real
# credentials or runs the real collector against the network.
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-test-cli.XXXXXX")
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.local/bin" "$TEST_HOME/stubs"
printf '#!/bin/bash\nexit 1\n' > "$TEST_HOME/stubs/secret-tool"
printf '#!/bin/bash\nexit 0\n' > "$TEST_HOME/stubs/omarchy-shell"
chmod +x "$TEST_HOME/stubs/secret-tool" "$TEST_HOME/stubs/omarchy-shell"
export PATH="$TEST_HOME/stubs:$PATH"

echo "🧪 Running CLI helper tests..."

# 1. Test help command
echo "  ▶ Testing help command..."
output=$("$CLI" help)
if ! echo "$output" | grep -q "Usage: omarchy-antigravity"; then
  echo "❌ Assertion failed: help command did not display usage." >&2
  exit 1
fi

# 2. Test invalid command exits non-zero
echo "  ▶ Testing invalid argument handling..."
if "$CLI" invalid-command >/dev/null 2>&1; then
  echo "❌ Assertion failed: invalid command should return non-zero code." >&2
  exit 1
fi

# 3. Test status command
echo "  ▶ Testing status command..."
status_out=$("$CLI" status)
if ! echo "$status_out" | grep -q "Checking Antigravity credentials"; then
  echo "❌ Assertion failed: status did not execute credential check." >&2
  exit 1
fi
if ! echo "$status_out" | grep -q "Not authenticated"; then
  echo "❌ Assertion failed: an empty keyring (lookup exit 1) must read as not authenticated." >&2
  exit 1
fi

# 4. Test that refresh reports a failed update instead of claiming success
echo "  ▶ Testing refresh failure reporting..."
printf '#!/bin/bash\necho "antigravity: boom" >&2\nexit 1\n' > "$TEST_HOME/.local/bin/omarchy-agent-usage-update"
chmod +x "$TEST_HOME/.local/bin/omarchy-agent-usage-update"
if refresh_out=$("$CLI" refresh 2>&1); then
  echo "❌ Assertion failed: refresh exited 0 although the update failed." >&2
  exit 1
fi
if echo "$refresh_out" | grep -q "Quota refreshed!"; then
  echo "❌ Assertion failed: refresh claimed success after a failed update." >&2
  exit 1
fi
rm -f "$TEST_HOME/.local/bin/omarchy-agent-usage-update"

# 5. statusline enable backs up a user's own script once, never its own copy
echo "  ▶ Testing statusline enable backups..."
agy_dir="$TEST_HOME/.gemini/antigravity-cli"
"$CLI" statusline enable >/dev/null
"$CLI" statusline enable >/dev/null
if [[ -e "$agy_dir/statusline.sh.bak" ]]; then
  echo "❌ Assertion failed: statusline enable backed up the plugin's own script." >&2
  exit 1
fi
printf '#!/bin/bash\necho mine\n' > "$agy_dir/statusline.sh"
"$CLI" statusline enable >/dev/null
if ! grep -q 'echo mine' "$agy_dir/statusline.sh.bak" 2>/dev/null; then
  echo "❌ Assertion failed: statusline enable did not back up the user's script." >&2
  exit 1
fi
if ! jq -e --arg s "$agy_dir/statusline.sh" '.statusLine == {"type":"command","command":$s,"enabled":true}' "$agy_dir/settings.json" >/dev/null; then
  echo "❌ Assertion failed: statusline enable did not configure settings.json." >&2
  exit 1
fi
"$CLI" statusline disable >/dev/null
if ! jq -e '.statusLine.enabled == false' "$agy_dir/settings.json" >/dev/null; then
  echo "❌ Assertion failed: statusline disable did not disable the status line." >&2
  exit 1
fi

# 6. Test syntax of all shell scripts in bin/
echo "  ▶ Testing bash syntax for bin scripts..."
for script in "$PROJECT_ROOT"/bin/*; do
  [[ -f "$script" ]] || continue
  if file "$script" | grep -q "shell script"; then
    bash -n "$script"
  fi
done

echo "  ✅ CLI tool passed all functional tests!"
echo "🎉 CLI tests passed successfully!"
