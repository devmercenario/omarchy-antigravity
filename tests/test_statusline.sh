#!/bin/bash
# ==============================================================================
# Functional & Unit Tests: Antigravity CLI Statusline
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATUSLINE="$PROJECT_ROOT/bin/omarchy-antigravity-statusline"
CLI="$PROJECT_ROOT/bin/omarchy-antigravity"

echo "🧪 Running statusline tests..."

# 1. Verify statusline script is executable and passes syntax check
echo "  ▶ Testing statusline syntax..."
bash -n "$STATUSLINE"

# 2. Test statusline direct invocation
echo "  ▶ Testing direct execution..."
out=$("$STATUSLINE")
if ! echo "$out" | grep -q "AGY"; then
  echo "❌ Assertion failed: statusline did not output AGY header." >&2
  exit 1
fi

# 3. Test JSON input via stdin
echo "  ▶ Testing statusline with JSON payload via stdin..."
mock_json='{"cwd":"/tmp","terminal_width":90,"model":{"id":"gemini-test","display_name":"Gemini Pro"}}'
out_json=$(echo "$mock_json" | "$STATUSLINE")
if ! echo "$out_json" | grep -q "tmp"; then
  echo "❌ Assertion failed: statusline did not use cwd from JSON input." >&2
  exit 1
fi

# 4. Test clock trailing spacing (must have single trailing space after time for symmetry)
echo "  ▶ Testing clock trailing spacing..."
clean_out=$(printf "%b" "$out" | sed "s/\x1b\[[0-9;]*[a-zA-Z]//g")
if [[ ! "$clean_out" =~ [0-9]{2}:[0-9]{2}[[:space:]]$ ]]; then
  echo "❌ Assertion failed: statusline must end with single space after clock. Got: '${clean_out}'" >&2
  exit 1
fi

# 5. Test CLI helper statusline subcommands
echo "  ▶ Testing omarchy-antigravity statusline subcommands..."
cli_status=$("$CLI" statusline status)
if ! echo "$cli_status" | grep -q "Antigravity CLI Status Bar"; then
  echo "❌ Assertion failed: omarchy-antigravity statusline status failed." >&2
  exit 1
fi

echo "  ✅ All statusline assertions passed!"
echo "🎉 Statusline tests passed successfully!"
