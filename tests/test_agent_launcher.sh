#!/bin/bash
# ==============================================================================
# Integration Test: omarchy-agent launcher wrapper
#
# With Antigravity as the default agent, Omarchy's keybinding, menu and bar
# button must open agy (with its standard permission prompts), and every other
# agent must reach Omarchy's stock launcher exactly as before. Regression for
# devmercenario/omarchy-antigravity#1 (a launch opened the deprecated Gemini
# CLI instead of Antigravity).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="$PROJECT_ROOT/bin/omarchy-agent"

echo "🧪 Running agent launcher tests..."

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-test-agent.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

fail() {
  echo "❌ Assertion failed: $*" >&2
  exit 1
}

export HOME="$ROOT/home"
export OMARCHY_PATH="$ROOT/omarchy"
STUBS="$ROOT/stubs"
CALLS="$ROOT/calls"
mkdir -p "$HOME/Work" "$OMARCHY_PATH/bin" "$STUBS"
# System directories only, so a real agy or omarchy-* on the machine never
# stands in for a stub.
export PATH="$STUBS:/usr/bin:/bin"

stub() {
  printf '#!/bin/bash\n%s\n' "$2" > "$1"
  chmod +x "$1"
}

# Each stub records how it was called, one line per call.
stub "$STUBS/omarchy-default-agent" 'cat "$HOME/agent" 2>/dev/null || true'
stub "$STUBS/omarchy-launch-tui" 'echo "launch-tui $PWD $*" >> "'"$CALLS"'"'
stub "$STUBS/agy" 'echo "agy $*" >> "'"$CALLS"'"'
stub "$OMARCHY_PATH/bin/omarchy-agent" 'echo "stock $*" >> "'"$CALLS"'"'

run() {
  rm -f "$CALLS"
  (cd "${RUN_DIR:-$HOME}" && "$WRAPPER" "$@")
}

calls() {
  cat "$CALLS" 2>/dev/null || true
}

echo "  ▶ Other agents reach the stock launcher untouched..."
echo "claude" > "$HOME/agent"
run --pick --prompt "hi there"
[[ "$(calls)" == "stock --pick --prompt hi there" ]] || fail "claude was not delegated verbatim (got: $(calls))."

echo "gemini" > "$HOME/agent"
run
[[ "$(calls)" == "stock " ]] || fail "gemini (Omarchy's Gemini CLI) was not delegated to the stock launcher."

rm -f "$HOME/agent"
run --pick
[[ "$(calls)" == "stock --pick" ]] || fail "no default agent must still reach the stock picker."

echo "  ▶ Antigravity opens agy in the agent terminal, in ~/Work..."
echo "antigravity" > "$HOME/agent"
run --pick
[[ "$(calls)" == "launch-tui $HOME/Work --app-id=org.omarchy.agent agy" ]] \
  || fail "antigravity did not open agy via omarchy-launch-tui (got: $(calls))."

echo "  ▶ Prompts and --inline follow the stock launcher's flags..."
run --prompt "fix the bug"
[[ "$(calls)" == "launch-tui $HOME/Work --app-id=org.omarchy.agent agy -i fix the bug" ]] \
  || fail "the prompt was not passed as agy -i (got: $(calls))."
run --inline
[[ "$(calls)" == "agy " ]] || fail "--inline did not exec agy directly (got: $(calls))."

echo "  ▶ No permission bypass is ever passed to agy..."
run --prompt "x"
if calls | grep -qE -- '--dangerously|--yolo|--mode'; then
  fail "the launcher passed a permission bypass to agy."
fi

echo "  ▶ Bad arguments and a missing agy fail with a message..."
if run --bogus 2>"$ROOT/err"; then fail "an unexpected argument was accepted."; fi
grep -q "Unexpected argument: --bogus" "$ROOT/err" || fail "missing unexpected-argument message."
rm -f "$STUBS/agy"
if run 2>"$ROOT/err"; then fail "a missing agy did not fail."; fi
grep -q "Antigravity CLI (agy) is not installed" "$ROOT/err" || fail "missing not-installed message."
[[ -z "$(calls)" ]] || fail "nothing should launch without agy."

echo "  ▶ The launcher never execs itself..."
echo "claude" > "$HOME/agent"
mkdir -p "$ROOT/loop/bin"
ln -s "$WRAPPER" "$ROOT/loop/bin/omarchy-agent"
if OMARCHY_PATH="$ROOT/loop" run 2>"$ROOT/err"; then fail "a self-referencing OMARCHY_PATH did not fail."; fi
grep -q "omarchy-agent was not found" "$ROOT/err" || fail "missing self-reference message."

echo "🎉 Agent launcher tests passed successfully!"
