#!/bin/bash
# ==============================================================================
# Omarchy Antigravity Integration Uninstaller
# ==============================================================================

set -euo pipefail

BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/omarchy"
SHELL_CONFIG="$CONFIG_DIR/shell.json"
HOOK_FILE="$CONFIG_DIR/hooks/post-update.d/90-antigravity.hook"
CACHE_DIR="$HOME/.cache/omarchy/agent-usage"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage"
STATE_FILE="$STATE_DIR/antigravity.json"
USER_PLUGIN_ID="${USER:-$(id -un)}.agents"
USER_PLUGIN_DIR="$CONFIG_DIR/plugins/$USER_PLUGIN_ID"

# Marker lines that identify this plugin's own copies (see install.sh); only
# files carrying them are removed or replaced here.
STATUSLINE_MARKER_RE='^# (omarchy-antigravity: statusline|Omarchy Antigravity CLI Statusline)$'
UPDATER_MARKER_RE='^# (omarchy-antigravity: agent-usage-update|omarchy:summary=Update local usage records for all configured coding agents)$'
CLONE_MARKER=".omarchy-antigravity-cloned"

# True when $1 is a regular file (not a symlink) carrying marker regex $2.
has_marker() {
  [[ -f "$1" && ! -L "$1" ]] && grep -qE -- "$2" "$1" 2>/dev/null
}

# Temp files are removed on any exit; INT/TERM must exit explicitly.
TMP_FILES=()
cleanup_tmp() {
  (( ${#TMP_FILES[@]} == 0 )) || rm -f -- "${TMP_FILES[@]}"
}
trap cleanup_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Keep only the three most recent <file>.bak.<epoch> backups of $1.
prune_backups() {
  local f
  local -a baks=()
  for f in "$1".bak.*; do
    if [[ -f "$f" && ! -L "$f" && "$f" =~ \.bak\.[0-9]+$ ]]; then
      baks+=("$f")
    fi
  done
  (( ${#baks[@]} > 3 )) || return 0
  mapfile -t baks < <(printf '%s\n' "${baks[@]}" | sort -V)
  rm -f -- "${baks[@]:0:${#baks[@]}-3}"
}

# update_json FILE FILTER [jq args...]: rewrite FILE through FILTER only when
# the result differs, via a temp file next to it (atomic rename, same mode).
update_json() {
  local file="$1" filter="$2" tmp
  shift 2
  tmp=$(mktemp "$file.XXXXXX") || return 1
  TMP_FILES+=("$tmp")
  if ! jq "$@" "($filter) as \$new | if \$new == . then empty else \$new end" "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 0
  fi
  chmod --reference="$file" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

echo "🗑️  Uninstalling Antigravity Integration for Omarchy..."

# 1. Remove binaries
rm -f "$BIN_DIR/omarchy-agent-usage-antigravity" \
      "$BIN_DIR/omarchy-antigravity" \
      "$BIN_DIR/omarchy-antigravity-statusline"

# Undo the Antigravity CLI status line only where it is still this plugin's:
# a statusline.sh without the marker, and any statusLine entry not pointing
# at the plugin's script, belong to the user and are left alone.
AGY_CLI_DIR="$HOME/.gemini/antigravity-cli"
AGY_SETTINGS="$AGY_CLI_DIR/settings.json"
STATUSLINE="$AGY_CLI_DIR/statusline.sh"
if has_marker "$STATUSLINE" "$STATUSLINE_MARKER_RE"; then
  if [[ -f "$STATUSLINE.bak" ]] && ! has_marker "$STATUSLINE.bak" "$STATUSLINE_MARKER_RE"; then
    # The user's own script comes back at the same path, so a statusLine
    # entry pointing there keeps working and is kept.
    mv -f "$STATUSLINE.bak" "$STATUSLINE"
  else
    if [[ -f "$AGY_SETTINGS" ]] && ! update_json "$AGY_SETTINGS" '
      if ((.statusLine? | objects | .command?) // "") == $script then del(.statusLine) else . end
    ' --arg script "$STATUSLINE"; then
      echo "⚠️  Could not update $AGY_SETTINGS; left it unchanged." >&2
    fi
    rm -f "$STATUSLINE" "$STATUSLINE.bak"
  fi
elif has_marker "$STATUSLINE.bak" "$STATUSLINE_MARKER_RE"; then
  rm -f "$STATUSLINE.bak"
fi

# If a legacy gemini permission-bypass shim exists from a prior install, clean it up safely
if [[ -f "$BIN_DIR/gemini" ]] && grep -q -- '--dangerously-skip-permissions' "$BIN_DIR/gemini" 2>/dev/null; then
  rm -f "$BIN_DIR/gemini"
fi

# 2. Remove hook
rm -f "$HOOK_FILE"

# 2b. Agents widget. A plugin folder this installer cloned is removed whole:
# omarchy-plugin-remove also switches the bar back to the built-in widget
# (keeping a hidden backup of the folder); without it, delete the folder.
# A folder that already existed only gets the user's UI edits restored.
if [[ -f "$USER_PLUGIN_DIR/$CLONE_MARKER" && ! -L "$USER_PLUGIN_DIR" ]]; then
  if ! command -v omarchy-plugin-remove >/dev/null 2>&1 ||
     ! omarchy-plugin-remove "$USER_PLUGIN_ID" --yes >/dev/null 2>&1; then
    rm -rf -- "$USER_PLUGIN_DIR"
  fi
elif [[ -d "$USER_PLUGIN_DIR" ]]; then
  for ui_file in Panel.qml Main.qml; do
    if [[ -f "$USER_PLUGIN_DIR/$ui_file.bak" ]]; then
      mv -f "$USER_PLUGIN_DIR/$ui_file.bak" "$USER_PLUGIN_DIR/$ui_file"
    fi
  done
  if [[ -d "$USER_PLUGIN_DIR/assets" ]]; then
    for asset in antigravity.svg antigravity-light.svg; do
      if [[ -f "$USER_PLUGIN_DIR/assets/$asset.bak" ]]; then
        mv -f "$USER_PLUGIN_DIR/assets/$asset.bak" "$USER_PLUGIN_DIR/assets/$asset"
      fi
    done
  fi
fi

# Drop the provider entry install.sh added to the agents widget config, but
# only when it is exactly what install wrote ({"enabled": true}).
if [[ -f "$SHELL_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
  if ! update_json "$SHELL_CONFIG" '
    (.bar.layout[]?[]?
      | select(type == "object" and ((.id? // "") | tostring | endswith(".agents"))
               and .providers?.antigravity? == {"enabled": true}))
      |= del(.providers.antigravity)
  '; then
    echo "⚠️  Could not update $SHELL_CONFIG; left it unchanged." >&2
  fi
fi

# 3. Remove cache and state (every antigravity-* cache file, including the
# collector's private access-token cache, plus the updater's lock file).
rm -f "$STATE_FILE" "$STATE_DIR/.antigravity.lock"
for cache_file in "$CACHE_DIR"/antigravity-*; do
  if [[ -f "$cache_file" || -L "$cache_file" ]]; then
    rm -f -- "$cache_file"
  fi
done

# 4. Remove default agent selection if Antigravity was default
rm -f "$CONFIG_DIR/antigravity.default"

# Restore previous agent backup if one exists, or remove if it was antigravity/gemini
AGENT_FILE="$CONFIG_DIR/defaults/agent"
if [[ -f "$AGENT_FILE" ]] && [[ "$(cat "$AGENT_FILE")" =~ ^(antigravity|gemini)$ ]]; then
  LATEST_BAK=$(find "$CONFIG_DIR/defaults" -name "agent.bak.*" 2>/dev/null | sort -V | tail -n 1)
  if [[ -n "$LATEST_BAK" && -f "$LATEST_BAK" ]]; then
    mv "$LATEST_BAK" "$AGENT_FILE"
    echo "Restored previous default agent from backup: $(cat "$AGENT_FILE")"
  else
    rm -f "$AGENT_FILE"
    echo "Removed Antigravity as default agent."
  fi
fi
prune_backups "$AGENT_FILE"

# 5. Refresh agents (use the installed helper while it is still present)
if [[ -x "$BIN_DIR/omarchy-agent-usage-update" ]]; then
  "$BIN_DIR/omarchy-agent-usage-update" >/dev/null 2>&1 || true
elif command -v omarchy-agent-usage-update >/dev/null 2>&1; then
  omarchy-agent-usage-update >/dev/null 2>&1 || true
fi

# 6. Remove (or restore) the update helper we shadow-installed, so the stock
# Omarchy helper is no longer masked by a stale plugin copy. A backup that is
# itself a plugin copy (earlier releases backed up their own helper on a
# reinstall) is discarded rather than restored.
UPDATER="$BIN_DIR/omarchy-agent-usage-update"
UPDATER_BAK="$BIN_DIR/.omarchy-agent-usage-update.bak"
LEGACY_UPDATER_BAK="$BIN_DIR/omarchy-agent-usage-update.bak"
for bak in "$UPDATER_BAK" "$LEGACY_UPDATER_BAK"; do
  if has_marker "$bak" "$UPDATER_MARKER_RE"; then
    rm -f "$bak"
  fi
done
if has_marker "$UPDATER" "$UPDATER_MARKER_RE"; then
  if [[ -f "$UPDATER_BAK" ]]; then
    mv -f "$UPDATER_BAK" "$UPDATER"
  elif [[ -f "$LEGACY_UPDATER_BAK" ]]; then
    mv -f "$LEGACY_UPDATER_BAK" "$UPDATER"
  else
    rm -f "$UPDATER"
  fi
fi

echo "✅ Antigravity integration removed."
echo "   Run 'omarchy restart shell' to reload."
