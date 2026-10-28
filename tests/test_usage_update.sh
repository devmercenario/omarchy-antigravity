#!/bin/bash
# ==============================================================================
# Usage-Updater Regression Tests
#
# Guards against the fork-bomb regression where a stale `*.bak` of the update
# helper itself was discovered by the `omarchy-agent-usage-*` collector glob
# and treated as a collector, re-executing the updater recursively. It also
# proves genuine collectors are still discovered and run (a bare `*` guard
# would silently skip every collector), and covers the recursion guard,
# collector-id filtering, the per-collector lock, parallel runs, and how
# collector failures and stderr are reported.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPDATER="$PROJECT_ROOT/bin/omarchy-agent-usage-update"

# Isolated HOME, and an empty OMARCHY_PATH so the stock collectors of an
# Omarchy host are not discovered: this test only sees what it stages.
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-test-update.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
export XDG_STATE_HOME="$TEST_HOME/.local/state"
export OMARCHY_PATH="$TEST_HOME/omarchy"
unset OMARCHY_AGENT_USAGE_UPDATE_ACTIVE
STATE_DIR="$XDG_STATE_HOME/omarchy/agents/usage"
BIN="$HOME/.local/bin"
mkdir -p "$BIN" "$STATE_DIR" "$OMARCHY_PATH/bin"

fail() {
  echo "❌ Assertion failed: $*" >&2
  exit 1
}

echo "🧪 Running usage-updater tests..."

# A genuine collector: it must be discovered and run. It counts its runs so
# a recursive re-entry of the updater would show up as a second run.
cat > "$BIN/omarchy-agent-usage-faketest" <<EOF
#!/bin/bash
echo run >> "$TEST_HOME/faketest.runs"
echo '{"id":"faketest","name":"Fake Test Agent","ready":true,"totalPrompts":1}'
EOF
chmod +x "$BIN/omarchy-agent-usage-faketest"

# Copies or variants of the updater and other non-collector names. Each one
# records that it ran; none may. They are deliberately non-recursive so this
# test can never fork-bomb.
for name in update.bak update.bak.1700000000 update-old update.backup \
            Upper bad.id 'tilde~' faketest.json.tmp; do
  cat > "$BIN/omarchy-agent-usage-$name" <<EOF
#!/bin/bash
echo "$name" >> "$TEST_HOME/forbidden.runs"
echo '{"id":"forbidden"}'
EOF
  chmod +x "$BIN/omarchy-agent-usage-$name"
done

# 1. Full (run-all) refresh: discovery, id filtering and the fork-bomb guard.
echo "  ▶ Discovery runs real collectors and skips updater copies / odd ids..."
timeout 60 "$UPDATER" --limits-only || fail "updater exited non-zero on a clean run"
[[ -f "$STATE_DIR/faketest.json" ]] || fail "faketest collector was not discovered/run."
[[ ! -f "$TEST_HOME/forbidden.runs" ]] || fail "non-collector executed: $(tr '\n' ' ' < "$TEST_HOME/forbidden.runs")"
shopt -s nullglob
stray=("$STATE_DIR"/update* "$STATE_DIR"/Upper* "$STATE_DIR"/bad* "$STATE_DIR"/forbidden*)
shopt -u nullglob
(( ${#stray[@]} == 0 )) || fail "non-collector wrote a state record: ${stray[*]}"
rm -f "$BIN"/omarchy-agent-usage-{update.bak,update.bak.1700000000,update-old,update.backup,Upper,bad.id,'tilde~',faketest.json.tmp}

# 2. Recursion guard: a collector that runs the updater again must not make
# the nested updater re-run the other collectors. The nested call happens at
# most once, so a broken guard shows up as a second faketest run, not a bomb.
echo "  ▶ Recursion guard turns a nested updater into a no-op..."
: > "$TEST_HOME/faketest.runs"
cat > "$BIN/omarchy-agent-usage-recurse" <<EOF
#!/bin/bash
if [[ -z "\${RECURSE_TEST_DEPTH:-}" ]]; then
  RECURSE_TEST_DEPTH=1 "$UPDATER" --limits-only
fi
echo '{"id":"recurse"}'
EOF
chmod +x "$BIN/omarchy-agent-usage-recurse"
timeout 60 "$UPDATER" --limits-only || fail "updater failed with a recursing collector"
[[ "$(wc -l < "$TEST_HOME/faketest.runs")" -eq 1 ]] \
  || fail "nested updater re-ran collectors ($(wc -l < "$TEST_HOME/faketest.runs") faketest runs)."
rm -f "$BIN/omarchy-agent-usage-recurse" "$STATE_DIR/recurse.json"

rm -f "$STATE_DIR/faketest.json"
OMARCHY_AGENT_USAGE_UPDATE_ACTIVE=1 timeout 60 "$UPDATER" faketest || fail "guarded updater exited non-zero"
[[ ! -f "$STATE_DIR/faketest.json" ]] || fail "updater ran despite OMARCHY_AGENT_USAGE_UPDATE_ACTIVE."

# 3. Per-collector lock: a collector whose previous run still holds its lock
# is skipped (not a failure), and runs again once the lock is free.
echo "  ▶ A collector whose previous run is still going is skipped..."
if command -v flock >/dev/null 2>&1; then
  exec 8>>"$STATE_DIR/.faketest.lock"
  flock -n 8 || fail "test could not take the faketest lock"
  err=$(timeout 60 "$UPDATER" faketest 2>&1 >/dev/null) || fail "a locked (skipped) collector made the updater fail"
  [[ ! -f "$STATE_DIR/faketest.json" ]] || fail "locked collector ran anyway."
  [[ "$err" == *"faketest: previous run still in progress"* ]] || fail "lock skip was not reported: $err"
  exec 8>&-
  timeout 60 "$UPDATER" faketest || fail "updater failed after the lock was released"
  [[ -f "$STATE_DIR/faketest.json" ]] || fail "collector did not run after the lock was released."
else
  echo "    (flock not installed; skipped)"
fi

# 4. Failures are reported on stderr with the collector id, the collector's
# own stderr is forwarded (control characters stripped), the previous record
# survives, and the updater exits non-zero.
echo "  ▶ Collector stderr is forwarded and failures are reported..."
echo '{"id":"noisy","previous":true}' > "$STATE_DIR/noisy.json"
cat > "$BIN/omarchy-agent-usage-noisy" <<'EOF'
#!/bin/bash
printf 'token expired\033[31m red\n' >&2
echo '{"id":"noisy"}'
exit 3
EOF
chmod +x "$BIN/omarchy-agent-usage-noisy"
cat > "$BIN/omarchy-agent-usage-garbage" <<'EOF'
#!/bin/bash
echo 'this is not json'
EOF
chmod +x "$BIN/omarchy-agent-usage-garbage"
cat > "$BIN/omarchy-agent-usage-quiet" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/omarchy-agent-usage-quiet"
echo '{"id":"quiet","previous":true}' > "$STATE_DIR/quiet.json"

rc=0
err=$(timeout 60 "$UPDATER" noisy garbage quiet faketest 2>&1 >/dev/null) || rc=$?
(( rc != 0 )) || fail "updater exited 0 although collectors failed"
[[ "$err" == *"noisy: token expired[31m red"* ]] || fail "collector stderr was not forwarded with its id: $err"
[[ "$err" != *$'\e'* ]] || fail "control characters from collector stderr were forwarded"
[[ "$err" == *"noisy: collector failed (exit 3)"* ]] || fail "non-zero collector exit was not reported: $err"
[[ "$err" == *"garbage: collector did not print a valid JSON record"* ]] || fail "invalid JSON was not reported: $err"
[[ "$err" != *"quiet:"* ]] || fail "empty output with exit 0 must be a silent skip: $err"
jq -e '.previous == true' "$STATE_DIR/noisy.json" >/dev/null || fail "failed collector clobbered its previous record"
jq -e '.previous == true' "$STATE_DIR/quiet.json" >/dev/null || fail "skipping collector clobbered its previous record"
[[ ! -f "$STATE_DIR/garbage.json" ]] || fail "invalid JSON was published"
[[ -f "$STATE_DIR/faketest.json" ]] || fail "one failing collector stopped the others"
shopt -s nullglob
leftovers=("$STATE_DIR"/.*.tmp.* "$STATE_DIR"/.*.err.*)
shopt -u nullglob
(( ${#leftovers[@]} == 0 )) || fail "temp files left behind: ${leftovers[*]}"
rm -f "$BIN"/omarchy-agent-usage-{noisy,garbage,quiet}

# 5. Collectors run in parallel: each of these two waits for the other to
# have started, which only works when they run at the same time.
echo "  ▶ Collectors run in parallel..."
for pair in "ping pong" "pong ping"; do
  read -r self other <<< "$pair"
  cat > "$BIN/omarchy-agent-usage-$self" <<EOF
#!/bin/bash
touch "$TEST_HOME/$self.started"
for _ in \$(seq 100); do
  [[ -f "$TEST_HOME/$other.started" ]] && { echo '{"id":"$self"}'; exit 0; }
  sleep 0.05
done
echo "never saw $other start" >&2
exit 1
EOF
  chmod +x "$BIN/omarchy-agent-usage-$self"
done
timeout 60 "$UPDATER" ping pong || fail "collectors did not run in parallel"
[[ -f "$STATE_DIR/ping.json" && -f "$STATE_DIR/pong.json" ]] || fail "parallel collectors did not publish"

echo "  ✅ Usage updater passed all assertions!"
echo "🎉 Usage-updater tests passed successfully!"
