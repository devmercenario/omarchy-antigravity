#!/bin/bash
# ==============================================================================
# Integration Test: Omarchy 4.5 native Antigravity support
#
# Omarchy 4.5 ships Antigravity itself (agent id "agy", a usage collector and
# the panel icon). Its updater only runs Omarchy's own collectors and its panel
# calls omarchy-agent-usage-update through PATH, so the plugin must step aside:
# no second Antigravity tab, no 4.0-era updater, launcher or panel copy — only
# the status line and the helper stay. Covers a fresh install on 4.5 and the
# hand-over the post-update hook performs when `omarchy update` brings 4.5.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORIG_PATH="$PATH"
USER_PLUGIN_ID="${USER:-$(id -un)}.agents"

echo "🧪 Running Omarchy 4.5 native-mode tests..."

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-test-native.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

fail() {
  echo "❌ Assertion failed: $*" >&2
  exit 1
}

# An isolated HOME with stubs for everything that reaches the live session,
# and an OMARCHY_PATH that starts as Omarchy 4.0 (no native collector).
fresh_home() {
  TEST_HOME="$ROOT/$1"
  mkdir -p "$TEST_HOME/.local/bin" "$TEST_HOME/stubs" "$TEST_HOME/omarchy/bin" "$TEST_HOME/.config/omarchy"
  export HOME="$TEST_HOME"
  export XDG_STATE_HOME="$TEST_HOME/.local/state"
  export XDG_CACHE_HOME="$TEST_HOME/.cache"
  export XDG_CONFIG_HOME="$TEST_HOME/.config"
  export OMARCHY_PATH="$TEST_HOME/omarchy"
  export PATH="$TEST_HOME/.local/bin:$TEST_HOME/stubs:$ORIG_PATH"
  unset OMARCHY_AGENT_USAGE_UPDATE_ACTIVE
  BIN="$TEST_HOME/.local/bin"
  SHELL_JSON="$TEST_HOME/.config/omarchy/shell.json"
  AGENT_FILE="$TEST_HOME/.config/omarchy/defaults/agent"
  STATE="$XDG_STATE_HOME/omarchy/agents/usage"
  LOG="$TEST_HOME/install.log"
  stub secret-tool 'exit 1'
  stub agy 'echo agy mock'
  stub omarchy-shell 'exit 0'
  stub omarchy-plugin-clone '
d="$HOME/.config/omarchy/plugins/${USER:-$(id -un)}.agents"
mkdir -p "$d"
echo "// stock panel" > "$d/Panel.qml"
echo "// stock main" > "$d/Main.qml"'
  jq -n --arg id "$USER_PLUGIN_ID" \
    '{bar: {layout: {right: [{id: "omarchy.clock"}, {id: $id, providers: {claude: {enabled: true}}}]}}}' \
    > "$SHELL_JSON"
}

stub() {
  printf '#!/bin/bash\n%s\n' "$2" > "$TEST_HOME/stubs/$1"
  chmod +x "$TEST_HOME/stubs/$1"
}

# Turn the sandbox into Omarchy 4.5: its own agy collector and an updater that
# records how it was called.
make_native() {
  printf '#!/bin/bash\necho "{}"\n' > "$OMARCHY_PATH/bin/omarchy-agent-usage-agy"
  printf '#!/bin/bash\necho "stock-update $*" >> "$HOME/stock-update.calls"\n' \
    > "$OMARCHY_PATH/bin/omarchy-agent-usage-update"
  chmod +x "$OMARCHY_PATH/bin/omarchy-agent-usage-agy" "$OMARCHY_PATH/bin/omarchy-agent-usage-update"
}

run_install() {
  "$PROJECT_ROOT/install.sh" "$@" </dev/null >>"$LOG" 2>&1 || { cat "$LOG" >&2; fail "install.sh $* failed"; }
}

file_id() {
  stat -c '%i %Y' "$1"
}

echo "  ▶ A fresh install on Omarchy 4.5 keeps only the status line and the helper..."
fresh_home fresh
make_native
run_install --set-default --statusline
[[ -x "$BIN/omarchy-antigravity" ]] || fail "the helper was not installed."
grep -q 'omarchy-antigravity: statusline' "$TEST_HOME/.gemini/antigravity-cli/statusline.sh" \
  || fail "the status line was not installed."
for f in omarchy-agent-usage-antigravity omarchy-agent-usage-update omarchy-agent; do
  [[ ! -e "$BIN/$f" ]] || fail "$f was installed although Omarchy 4.5 provides its own."
done
[[ ! -d "$TEST_HOME/.config/omarchy/plugins/$USER_PLUGIN_ID" ]] || fail "the 4.0 panel copy was installed on 4.5."
[[ "$(cat "$AGENT_FILE")" == "agy" ]] || fail "the default agent was not set to Omarchy's own 'agy'."
jq -e '[.. | objects | .antigravity? // empty] | length == 0' "$SHELL_JSON" >/dev/null \
  || fail "the plugin's provider switch was added to Omarchy 4.5's widget."
grep -qx 'stock-update --force agy' "$TEST_HOME/stock-update.calls" \
  || fail "the initial refresh did not use Omarchy's updater for agy."

echo "  ▶ 'omarchy-antigravity default' writes 'agy' on 4.5..."
echo "claude" > "$AGENT_FILE"
"$BIN/omarchy-antigravity" default >/dev/null
[[ "$(cat "$AGENT_FILE")" == "agy" ]] || fail "default did not write 'agy' on 4.5."

echo "  ▶ 'omarchy update' to 4.5 hands the 4.0 setup over (post-update hook)..."
fresh_home upgrade
run_install --set-default --statusline
[[ -x "$BIN/omarchy-agent-usage-antigravity" && -x "$BIN/omarchy-agent" ]] || fail "4.0 install is incomplete."
grep -q 'authActionBtn' "$TEST_HOME/.config/omarchy/plugins/$USER_PLUGIN_ID/Panel.qml" \
  || fail "4.0 install did not put the plugin's panel in place."
[[ "$(cat "$AGENT_FILE")" == "antigravity" ]] || fail "4.0 install did not set the antigravity default."
mkdir -p "$STATE"
echo '{"id":"antigravity"}' > "$STATE/antigravity.json"
echo '{"id":"claude"}' > "$STATE/claude.json"

make_native
bash "$TEST_HOME/.config/omarchy/hooks/post-update.d/90-antigravity.hook"

for f in omarchy-agent-usage-antigravity omarchy-agent-usage-update omarchy-agent; do
  [[ ! -e "$BIN/$f" ]] || fail "the hook left the plugin's $f in place on 4.5."
done
[[ -x "$BIN/omarchy-antigravity" && -x "$BIN/omarchy-antigravity-statusline" ]] || fail "the hook removed what 4.5 lacks."
[[ ! -e "$STATE/antigravity.json" ]] || fail "the plugin's Antigravity record would show as a second tab."
[[ -e "$STATE/claude.json" ]] || fail "another agent's record was removed."
[[ "$(cat "$AGENT_FILE")" == "agy" ]] || fail "the antigravity default did not become 'agy'."
jq -e --arg id "$USER_PLUGIN_ID" '
  ([.bar.layout.right[].id] == ["omarchy.clock", "omarchy.agents"])
  and (.bar.layout.right[1].providers == {claude: {enabled: true}})
' "$SHELL_JSON" >/dev/null || fail "the bar was not switched back to Omarchy's agents widget with its settings."
[[ -d "$TEST_HOME/.config/omarchy/plugins/$USER_PLUGIN_ID" ]] || fail "the panel copy's folder was deleted."

echo "  ▶ The hand-over is idempotent..."
before=$(file_id "$SHELL_JSON")
"$BIN/omarchy-antigravity" adopt-native >/dev/null
bash "$TEST_HOME/.config/omarchy/hooks/post-update.d/90-antigravity.hook"
[[ "$(file_id "$SHELL_JSON")" == "$before" ]] || fail "a repeated hand-over rewrote shell.json."

echo "  ▶ A user's own launcher and updater are never touched..."
fresh_home foreign
printf '#!/bin/bash\necho mine\n' > "$BIN/omarchy-agent"
printf '#!/bin/bash\necho mine\n' > "$BIN/omarchy-agent-usage-update"
chmod +x "$BIN/omarchy-agent" "$BIN/omarchy-agent-usage-update"
make_native
"$PROJECT_ROOT/bin/omarchy-antigravity" adopt-native >/dev/null
[[ "$("$BIN/omarchy-agent")" == "mine" && "$("$BIN/omarchy-agent-usage-update")" == "mine" ]] \
  || fail "adopt-native removed files the plugin did not write."
jq -e --arg id "$USER_PLUGIN_ID" '.bar.layout.right[1].id == $id' "$SHELL_JSON" >/dev/null \
  || fail "a widget without the plugin's panel was switched."

echo "  ▶ Without native support adopt-native changes nothing..."
fresh_home no-native
run_install --set-default --no-statusline
before=$(file_id "$SHELL_JSON")
"$BIN/omarchy-antigravity" adopt-native | grep -q "nothing to hand over" || fail "missing no-op message."
[[ -x "$BIN/omarchy-agent-usage-antigravity" ]] || fail "adopt-native removed the collector on Omarchy 4.0."
[[ "$(file_id "$SHELL_JSON")" == "$before" ]] || fail "adopt-native rewrote shell.json on Omarchy 4.0."

echo "🎉 Omarchy 4.5 native-mode tests passed successfully!"
