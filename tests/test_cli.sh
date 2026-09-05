#!/bin/bash
# ==============================================================================
# Functional Test: omarchy-antigravity CLI Helper
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_ROOT/bin/omarchy-antigravity"

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

# 4. Test syntax of all shell scripts in bin/
echo "  ▶ Testing bash syntax for bin scripts..."
for script in "$PROJECT_ROOT"/bin/*; do
  [[ -f "$script" ]] || continue
  if file "$script" | grep -q "shell script"; then
    bash -n "$script"
  fi
done

echo "  ✅ CLI tool passed all functional tests!"
echo "🎉 CLI tests passed successfully!"
