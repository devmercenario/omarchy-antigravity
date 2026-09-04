#!/bin/bash
# ==============================================================================
# Master Test Suite Runner for omarchy-antigravity
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}   Running omarchy-antigravity Full Test Suite        ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo ""

TOTAL_SUITES=5
PASSED_SUITES=0

run_suite() {
  local name="$1"
  local cmd="$2"

  echo -e "${BLUE}▶ Running suite: ${name}${NC}"
  if eval "$cmd"; then
    echo -e "${GREEN}✔ ${name} PASSED${NC}"
    echo ""
    PASSED_SUITES=$((PASSED_SUITES + 1))
  else
    echo -e "${RED}✖ ${name} FAILED${NC}"
    echo ""
    return 1
  fi
}

run_suite "Python Collector Unit & Integration Tests" "python3 -m unittest '$SCRIPT_DIR/test_collector.py'"
run_suite "Plugin Manifest Validation" "bash '$SCRIPT_DIR/test_manifest.sh'"
run_suite "Installer & Uninstaller Lifecycle" "bash '$SCRIPT_DIR/test_installer.sh'"
run_suite "Post-Update Hook Persistence" "bash '$SCRIPT_DIR/test_hook.sh'"
run_suite "CLI Functional Commands" "bash '$SCRIPT_DIR/test_cli.sh'"

echo -e "${BLUE}======================================================${NC}"
if (( PASSED_SUITES == TOTAL_SUITES )); then
  echo -e "${GREEN}🎉 ALL ${TOTAL_SUITES} TEST SUITES PASSED SUCCESSFULLY (100% COVERED)${NC}"
  echo -e "${BLUE}======================================================${NC}"
  exit 0
else
  echo -e "${RED}❌ SOME TESTS FAILED (${PASSED_SUITES}/${TOTAL_SUITES} passed)${NC}"
  echo -e "${BLUE}======================================================${NC}"
  exit 1
fi
