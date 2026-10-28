#!/bin/bash
# ==============================================================================
# Pre-push preflight: run the same checks the Omarchy plugin marketplace runs,
# locally, against the tree this script lives in — before you push. The
# .githooks/pre-push hook runs it in a temporary worktree of each pushed
# commit, so uncommitted edits cannot make a push pass or fail.
#
#   bash tests/preflight.sh
#
# Layers covered (mirroring the marketplace):
#   1. Manifest / "Quattro" compatibility  -> omarchy plugin validate
#   2. QML syntax                          -> qmllint
#   3. Full test suite                     -> tests/run_tests.sh
#   4. Automated Security Baseline (local) -> tests/marketplace-baseline-local.mjs
#
# To run automatically on `git push`, add:
#   git config core.hooksPath .githooks   # then put a `pre-push` hook calling this
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; NC='\033[0m'
step() { echo -e "\n${BLUE}▶ $*${NC}"; }
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
fail() { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

# 1. Manifest / Quattro compatibility (the marketplace `marketplace-validation` layer)
step "Manifest validation"
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  omarchy-plugin-validate "$PROJECT_ROOT" || fail "manifest validation failed"
elif command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate "$PROJECT_ROOT" || fail "manifest validation failed"
else
  jq -e '.schemaVersion == 1 and (.id | type == "string") and (.entryPoints | type == "object")' manifest.json >/dev/null \
    || fail "manifest.json is invalid"
fi
ok "manifest validation passed"

# 2. QML syntax
step "QML syntax"
if command -v qmllint >/dev/null 2>&1; then
  # Service.qml and Main.qml lint clean under stock qmllint. Panel.qml imports
  # the Quickshell/Omarchy runtime modules (qs.Commons, qs.Ui, Panel) that a
  # bare qmllint cannot resolve, so it is intentionally skipped here.
  for qml_file in Service.qml ui/Main.qml; do
    qmllint "$qml_file" || fail "QML syntax check failed: $qml_file"
  done
  ok "qmllint passed (Service.qml, ui/Main.qml)"
else
  warn "qmllint not installed; skipping"
fi

# 3. Full test suite
step "Full test suite"
bash "$SCRIPT_DIR/run_tests.sh" || fail "test suite failed"

# 4. Automated security baseline against the local commit (no push, no network)
step "Automated security baseline (local)"
if command -v node >/dev/null 2>&1; then
  node "$SCRIPT_DIR/marketplace-baseline-local.mjs" || fail "security baseline scan failed"
else
  warn "node not installed; skipping the security baseline (CI still runs it)"
fi

echo ""
ok "Preflight complete — all checks passed."
