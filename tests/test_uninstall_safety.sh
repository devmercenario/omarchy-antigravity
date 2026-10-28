#!/bin/bash
# ==============================================================================
# Integration Test: Reinstall & Uninstall Safety
#
# Uninstall must revert exactly what install did and nothing the user owns:
# a status line the user wrote (and the settings entry pointing at it), a
# helper the plugin shadowed, an agents plugin folder that already existed,
# provider settings the user changed. Reinstalling must not back up the
# plugin's own files, or uninstall would "restore" them for good.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORIG_PATH="$PATH"
USER_PLUGIN_ID="${USER:-$(id -un)}.agents"

echo "🧪 Running reinstall & uninstall safety tests..."

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-test-uninstall.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

fail() {
  echo "❌ Assertion failed: $*" >&2
  exit 1
}

# A fresh isolated HOME with stubs for everything that would reach the live
# session (omarchy-shell IPC, plugin clone/remove), an empty keyring, and an
# empty OMARCHY_PATH so the updater only sees this plugin's collector.
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
  AGY_DIR="$TEST_HOME/.gemini/antigravity-cli"
  SHELL_JSON="$TEST_HOME/.config/omarchy/shell.json"
  PLUGIN_DIR="$TEST_HOME/.config/omarchy/plugins/$USER_PLUGIN_ID"
  LOG="$TEST_HOME/install.log"
  stub secret-tool 'exit 1'
  stub agy 'echo agy mock'
  stub omarchy-shell 'exit 0'
  stub omarchy-plugin-clone '
d="$HOME/.config/omarchy/plugins/${USER:-$(id -un)}.agents"
mkdir -p "$d"
echo "{\"id\":\"x.agents\",\"omarchy\":{\"clonedFrom\":\"$1\"}}" > "$d/manifest.json"
echo "// stock panel" > "$d/Panel.qml"
echo "// stock main" > "$d/Main.qml"'
  # Like the real command: unloads the clone and moves it to a hidden backup.
  stub omarchy-plugin-remove '
echo "$*" >> "$HOME/plugin-remove.calls"
mv "$HOME/.config/omarchy/plugins/$1" "$HOME/.config/omarchy/plugins/.$1.bak.test"'
}

stub() {
  printf '#!/bin/bash\n%s\n' "$2" > "$TEST_HOME/stubs/$1"
  chmod +x "$TEST_HOME/stubs/$1"
}

run_install() {
  "$PROJECT_ROOT/install.sh" "$@" </dev/null >>"$LOG" 2>&1 || { cat "$LOG" >&2; fail "install.sh $* failed"; }
}

run_uninstall() {
  "$PROJECT_ROOT/uninstall.sh" </dev/null >>"$LOG" 2>&1 || { cat "$LOG" >&2; fail "uninstall.sh failed"; }
}

user_statusline() {
  mkdir -p "$AGY_DIR"
  printf '#!/bin/bash\necho "%s"\n' "$1" > "$AGY_DIR/statusline.sh"
  chmod +x "$AGY_DIR/statusline.sh"
  jq -n --arg c "$AGY_DIR/statusline.sh" \
    '{theme: "dark", statusLine: {type: "command", command: $c, enabled: true, padding: 2}}' \
    > "$AGY_DIR/settings.json"
}

# ------------------------------------------------------------------ 1
echo "  ▶ A user's own status line survives install + uninstall untouched..."
fresh_home foreign-statusline
user_statusline "mine"
settings_before=$(jq -S . "$AGY_DIR/settings.json")
run_install --no-default --no-statusline
run_uninstall
grep -q 'echo "mine"' "$AGY_DIR/statusline.sh" || fail "uninstall removed or changed the user's statusline.sh."
[[ "$(jq -S . "$AGY_DIR/settings.json")" == "$settings_before" ]] || fail "uninstall changed the user's statusLine settings."

# ------------------------------------------------------------------ 2
echo "  ▶ A status line replaced by install is restored with its settings entry..."
fresh_home restored-statusline
user_statusline "mine"
run_install --no-default --statusline
grep -qx '# omarchy-antigravity: statusline' "$AGY_DIR/statusline.sh" || fail "plugin statusline was not installed."
grep -q 'echo "mine"' "$AGY_DIR/statusline.sh.bak" || fail "user's statusline.sh was not backed up."
run_install --no-default --statusline
grep -q 'echo "mine"' "$AGY_DIR/statusline.sh.bak" || fail "reinstall replaced the user's statusline backup."
run_uninstall
grep -q 'echo "mine"' "$AGY_DIR/statusline.sh" || fail "user's statusline.sh was not restored."
[[ ! -e "$AGY_DIR/statusline.sh.bak" ]] || fail "statusline backup was not consumed."
jq -e --arg c "$AGY_DIR/statusline.sh" '.statusLine.command == $c and .theme == "dark"' "$AGY_DIR/settings.json" >/dev/null \
  || fail "the statusLine entry for the restored user script was removed."

# ------------------------------------------------------------------ 3
echo "  ▶ A status line the user changed after install is left alone..."
fresh_home edited-statusline
run_install --no-default --statusline
printf '#!/bin/bash\necho "edited later"\n' > "$AGY_DIR/statusline.sh"
run_uninstall
grep -q 'edited later' "$AGY_DIR/statusline.sh" || fail "uninstall removed a statusline.sh the user replaced."
jq -e '.statusLine.command' "$AGY_DIR/settings.json" >/dev/null || fail "uninstall removed the statusLine entry of a user script."

# ------------------------------------------------------------------ 4
echo "  ▶ Reinstalling never backs up the plugin's own files..."
fresh_home reinstall
# Stand-in for the stock Omarchy helper further down PATH.
stub omarchy-agent-usage-update 'echo stock helper'
stock_helper="$TEST_HOME/stubs/omarchy-agent-usage-update"
run_install --no-default --statusline
run_install --no-default --statusline
[[ ! -e "$TEST_HOME/.local/bin/.omarchy-agent-usage-update.bak" ]] || fail "reinstall backed up the plugin's own update helper."
[[ ! -e "$AGY_DIR/statusline.sh.bak" ]] || fail "reinstall backed up the plugin's own statusline."
shopt -s nullglob
settings_baks=("$AGY_DIR"/settings.json.bak.*)
shopt -u nullglob
(( ${#settings_baks[@]} == 0 )) || fail "an unchanged settings.json was backed up on reinstall."
run_uninstall
[[ ! -e "$TEST_HOME/.local/bin/omarchy-agent-usage-update" ]] || fail "a plugin copy still masks the stock update helper."
[[ "$(command -v omarchy-agent-usage-update)" == "$stock_helper" ]] || fail "stock update helper is not the one on PATH."
[[ ! -e "$AGY_DIR/statusline.sh" ]] || fail "plugin statusline.sh was not removed."
jq -e 'has("statusLine") | not' "$AGY_DIR/settings.json" >/dev/null || fail "plugin statusLine entry was not removed."

# ------------------------------------------------------------------ 5
echo "  ▶ A user's own update helper survives install, reinstall and uninstall..."
fresh_home user-helper
printf '#!/bin/bash\necho "user helper"\n' > "$TEST_HOME/.local/bin/omarchy-agent-usage-update"
chmod +x "$TEST_HOME/.local/bin/omarchy-agent-usage-update"
run_install --no-default --no-statusline
run_install --no-default --no-statusline
grep -q 'user helper' "$TEST_HOME/.local/bin/.omarchy-agent-usage-update.bak" || fail "user helper backup was replaced on reinstall."
run_uninstall
grep -q 'user helper' "$TEST_HOME/.local/bin/omarchy-agent-usage-update" || fail "user helper was not restored."

# ------------------------------------------------------------------ 6
echo "  ▶ Legacy and self-made helper backups are migrated or dropped..."
fresh_home legacy-plugin-bak
cp "$PROJECT_ROOT/bin/omarchy-agent-usage-update" "$TEST_HOME/.local/bin/omarchy-agent-usage-update.bak"
chmod +x "$TEST_HOME/.local/bin/omarchy-agent-usage-update.bak"
run_install --no-default --no-statusline
[[ ! -e "$TEST_HOME/.local/bin/omarchy-agent-usage-update.bak" ]] || fail "legacy plugin-copy backup was not removed."
[[ ! -e "$TEST_HOME/.local/bin/.omarchy-agent-usage-update.bak" ]] || fail "legacy plugin-copy backup was migrated."
# A hidden backup that is a plugin copy (left by the old self-backup bug)
# must not be restored over the stock helper.
cp "$PROJECT_ROOT/bin/omarchy-agent-usage-update" "$TEST_HOME/.local/bin/.omarchy-agent-usage-update.bak"
run_uninstall
[[ ! -e "$TEST_HOME/.local/bin/omarchy-agent-usage-update" ]] || fail "uninstall restored a plugin-copy backup."
[[ ! -e "$TEST_HOME/.local/bin/.omarchy-agent-usage-update.bak" ]] || fail "plugin-copy backup was left behind."

fresh_home legacy-user-bak
printf '#!/bin/bash\necho "old stock"\n' > "$TEST_HOME/.local/bin/omarchy-agent-usage-update.bak"
chmod +x "$TEST_HOME/.local/bin/omarchy-agent-usage-update.bak"
run_install --no-default --no-statusline
[[ ! -e "$TEST_HOME/.local/bin/omarchy-agent-usage-update.bak" ]] || fail "legacy user backup was not moved to the hidden name."
grep -q 'old stock' "$TEST_HOME/.local/bin/.omarchy-agent-usage-update.bak" || fail "legacy user backup content was lost."
run_uninstall
grep -q 'old stock' "$TEST_HOME/.local/bin/omarchy-agent-usage-update" || fail "migrated user backup was not restored."

# ------------------------------------------------------------------ 7
echo "  ▶ An agents plugin folder cloned by install is removed again..."
fresh_home cloned-plugin
run_install --no-default --no-statusline
[[ -f "$PLUGIN_DIR/.omarchy-antigravity-cloned" ]] || fail "install did not mark the folder it cloned."
cmp -s "$PROJECT_ROOT/ui/Panel.qml" "$PLUGIN_DIR/Panel.qml" || fail "plugin Panel.qml was not installed into the clone."
run_uninstall
[[ ! -e "$PLUGIN_DIR" ]] || fail "uninstall left the cloned plugin folder behind."
grep -qx "$USER_PLUGIN_ID --yes" "$HOME/plugin-remove.calls" || fail "uninstall did not go through omarchy-plugin-remove."

fresh_home cloned-plugin-fallback
stub omarchy-plugin-remove 'exit 1'
run_install --no-default --no-statusline
run_uninstall
[[ ! -e "$PLUGIN_DIR" ]] || fail "uninstall did not delete the clone when omarchy-plugin-remove failed."

fresh_home existing-plugin
mkdir -p "$PLUGIN_DIR"
printf '// my panel\n' > "$PLUGIN_DIR/Panel.qml"
printf '// my notes\n' > "$PLUGIN_DIR/notes.txt"
run_install --no-default --no-statusline
[[ ! -e "$PLUGIN_DIR/.omarchy-antigravity-cloned" ]] || fail "install marked a folder it did not create."
run_uninstall
grep -q 'my panel' "$PLUGIN_DIR/Panel.qml" || fail "user Panel.qml was not restored."
[[ -f "$PLUGIN_DIR/notes.txt" ]] || fail "uninstall removed a plugin folder the user owned."
[[ ! -e "$HOME/plugin-remove.calls" ]] || fail "uninstall removed a plugin the user owned."

# ------------------------------------------------------------------ 8
echo "  ▶ shell.json: provider entry reverted, backups capped, no-op reinstall..."
fresh_home shell-json
cat > "$SHELL_JSON" <<'EOF'
{
  "bar": {
    "layout": {
      "left": [{ "id": "me.agents", "providers": { "antigravity": { "enabled": true, "note": "mine" } } }],
      "right": [
        { "id": "omarchy.agents", "providers": { "claude": { "enabled": true } } },
        { "id": 42 },
        "clock"
      ]
    }
  }
}
EOF
chmod 640 "$SHELL_JSON"
for n in 1 2 3 4 5; do
  echo '{}' > "$SHELL_JSON.bak.100000000$n"
done
run_install --no-default --no-statusline
jq -e '.bar.layout.right[0].providers.antigravity == {"enabled": true}' "$SHELL_JSON" >/dev/null || fail "install did not enable antigravity."
[[ "$(stat -c '%a' "$SHELL_JSON")" == "640" ]] || fail "install changed shell.json's mode."
shopt -s nullglob
baks=("$SHELL_JSON".bak.*)
shopt -u nullglob
(( ${#baks[@]} == 3 )) || fail "expected 3 shell.json backups, found ${#baks[@]}."
[[ ! -e "$SHELL_JSON.bak.1000000001" ]] || fail "the oldest shell.json backups were kept instead of the newest."
before=$(stat -c '%i %y' "$SHELL_JSON")
run_install --no-default --no-statusline
[[ "$(stat -c '%i %y' "$SHELL_JSON")" == "$before" ]] || fail "reinstall rewrote an unchanged shell.json."
shopt -s nullglob
baks=("$SHELL_JSON".bak.*)
leftovers=("$SHELL_JSON".??????)
shopt -u nullglob
(( ${#baks[@]} == 3 )) || fail "reinstall added a shell.json backup without changing it."
# An existing pile is trimmed even when nothing changes.
for n in 1 2 3 4; do
  echo '{}' > "$SHELL_JSON.bak.100000000$n"
done
run_install --no-default --no-statusline
shopt -s nullglob
baks=("$SHELL_JSON".bak.*)
shopt -u nullglob
(( ${#baks[@]} == 3 )) || fail "an existing pile of shell.json backups was not trimmed to 3."
[[ "$(stat -c '%i %y' "$SHELL_JSON")" == "$before" ]] || fail "trimming backups rewrote shell.json."
(( ${#leftovers[@]} == 0 )) || fail "temp files left next to shell.json: ${leftovers[*]}"
run_uninstall
jq -e '.bar.layout.right[0].providers | has("antigravity") | not' "$SHELL_JSON" >/dev/null || fail "uninstall left the provider entry install added."
jq -e '.bar.layout.right[0].providers.claude.enabled == true' "$SHELL_JSON" >/dev/null || fail "uninstall dropped other providers."
jq -e '.bar.layout.left[0].providers.antigravity.note == "mine"' "$SHELL_JSON" >/dev/null || fail "uninstall removed a provider entry the user customised."

# ------------------------------------------------------------------ 9
echo "  ▶ State honours XDG_STATE_HOME; caches and agent backups are cleaned up..."
fresh_home state
export XDG_STATE_HOME="$TEST_HOME/custom-state"
mkdir -p "$TEST_HOME/.config/omarchy/defaults"
echo "claude" > "$TEST_HOME/.config/omarchy/defaults/agent"
for n in 1 2 3 4 5; do
  echo "old$n" > "$TEST_HOME/.config/omarchy/defaults/agent.bak.100000000$n"
done
run_install --set-default --no-statusline
shopt -s nullglob
agent_baks=("$TEST_HOME/.config/omarchy/defaults"/agent.bak.*)
shopt -u nullglob
(( ${#agent_baks[@]} == 3 )) || fail "expected 3 agent backups after install, found ${#agent_baks[@]}."
mkdir -p "$XDG_STATE_HOME/omarchy/agents/usage" "$TEST_HOME/.cache/omarchy/agent-usage"
echo '{}' > "$XDG_STATE_HOME/omarchy/agents/usage/antigravity.json"
echo '{}' > "$TEST_HOME/.cache/omarchy/agent-usage/antigravity-access-token.json"
echo '{}' > "$TEST_HOME/.cache/omarchy/agent-usage/claude-usage.json"
run_uninstall
[[ ! -e "$XDG_STATE_HOME/omarchy/agents/usage/antigravity.json" ]] || fail "uninstall ignored XDG_STATE_HOME."
[[ ! -e "$TEST_HOME/.cache/omarchy/agent-usage/antigravity-access-token.json" ]] || fail "antigravity cache files were left behind."
[[ -e "$TEST_HOME/.cache/omarchy/agent-usage/claude-usage.json" ]] || fail "uninstall removed another agent's cache."
[[ "$(cat "$TEST_HOME/.config/omarchy/defaults/agent")" == "claude" ]] || fail "previous default agent was not restored."

echo "  ✅ Reinstall & uninstall safety checks passed!"
echo "🎉 Reinstall & uninstall safety tests passed successfully!"
