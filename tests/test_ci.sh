#!/bin/bash
# ==============================================================================
# Static Gate: CI workflow hardening + shell/python syntax
#
# Guards the CI configuration itself so a future edit cannot silently drop
# least-privilege permissions, timeouts, concurrency, or action pinning.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW="$PROJECT_ROOT/.github/workflows/test.yml"

fail() {
  echo "❌ $*" >&2
  exit 1
}

echo "🧪 Running CI / static configuration gates..."

# ---------------------------------------------------------------- workflow
[[ -f "$WORKFLOW" ]] || fail "CI workflow file is missing: $WORKFLOW"

grep -qE '^[[:space:]]*contents: read' "$WORKFLOW" \
  || fail "workflow must declare least-privilege permissions (contents: read)"
grep -qE '^[[:space:]]*timeout-minutes:' "$WORKFLOW" \
  || fail "workflow must set a job timeout"
grep -qE '^[[:space:]]*concurrency:' "$WORKFLOW" \
  || fail "workflow must declare concurrency"
grep -q 'cancel-in-progress: true' "$WORKFLOW" \
  || fail "workflow must cancel in-progress runs"

# Every action reference must be pinned to a full 40-character commit SHA.
while IFS= read -r ref; do
  [[ "$ref" =~ @[0-9a-f]{40}$ ]] || fail "action is not pinned to a full commit SHA: $ref"
done < <(grep -oE 'uses: [^ ]+' "$WORKFLOW" | awk '{print $2}')

# No job may request write permissions from untrusted triggers.
if grep -qE '^[[:space:]]*(contents|actions|packages|pull-requests|id-token): write' "$WORKFLOW"; then
  fail "workflow must not request write permissions"
fi

echo "  ✅ CI workflow hardening checks passed."

# ------------------------------------------------------------ shell syntax
for script in "$PROJECT_ROOT/install.sh" \
              "$PROJECT_ROOT/uninstall.sh" \
              "$PROJECT_ROOT"/bin/omarchy-* \
              "$PROJECT_ROOT"/hooks/post-update.d/*.hook \
              "$PROJECT_ROOT"/tests/*.sh; do
  [[ -f "$script" ]] || continue
  # Only syntax-check shell scripts; skip Python entry points such as the collector.
  head -1 "$script" | grep -qE '(^#!.*(bash|/sh)\b)' || continue
  bash -n "$script" || fail "bash syntax error in $script"
done
echo "  ✅ bash syntax OK for all shipped scripts."

# ----------------------------------------------------------- python syntax
python3 -m py_compile "$PROJECT_ROOT/bin/omarchy-agent-usage-antigravity" \
  || fail "python syntax error in collector"
echo "  ✅ python syntax OK."

echo "🎉 CI / static gates passed successfully!"
