#!/bin/bash
# ==============================================================================
# Omarchy Antigravity Integration Uninstaller
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
AGENT_LAUNCHER_MARKER_RE='^# omarchy-antigravity: agent-launcher$'
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

# Copy $1 to $1.bak.<epoch>, keeping its mode; a second backup in the same
# second takes the next free number instead of overwriting the first.
backup_file() {
  local n
  n=$(date +%s)
  while [[ -e "$1.bak.$n" || -L "$1.bak.$n" ]]; do
    n=$((n + 1))
  done
  cp -p -- "$1" "$1.bak.$n"
}

# Files the plugin installed, with the sha256 each had then, so an edit made
# afterwards is told apart from an older plugin release before the file is
# replaced or removed. Edited files are kept in PLUGIN_BACKUP_DIR, outside
# PATH and outside the collector glob.
INSTALL_MANIFEST="$HOME/.config/omarchy/antigravity.installed"
PLUGIN_BACKUP_DIR="$HOME/.local/share/omarchy-antigravity/backups"

file_sha() {
  sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1
}

# Returns 0 when $1 changed since it was installed, 1 when it is unchanged,
# and 2 when it was never recorded (installed by an earlier release).
installed_state() {
  local recorded
  recorded=$(awk -F'\t' -v p="$1" '$2 == p { sha = $1 } END { print sha }' "$INSTALL_MANIFEST" 2>/dev/null)
  [[ -n "$recorded" ]] || return 2
  [[ "$(file_sha "$1")" != "$recorded" ]]
}

# manifest_set FILE [record]: drop FILE's entry, then re-add it with its
# current sha256 when asked to record it.
manifest_set() {
  local tmp
  mkdir -p "${INSTALL_MANIFEST%/*}" || return 0
  tmp=$(mktemp "$INSTALL_MANIFEST.XXXXXX") || return 0
  {
    awk -F'\t' -v p="$1" '$2 != p' "$INSTALL_MANIFEST" 2>/dev/null || true
    if [[ "${2:-}" == record ]]; then
      printf '%s\t%s\n' "$(file_sha "$1")" "$1"
    fi
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$INSTALL_MANIFEST"
}

# Copy $1 into the backup folder under a name that is never reused.
stash_file() {
  local base n
  mkdir -p "$PLUGIN_BACKUP_DIR" && chmod 700 "$PLUGIN_BACKUP_DIR" || return 0
  base="$PLUGIN_BACKUP_DIR/${1##*/}"
  n=$(date +%s)
  while [[ -e "$base.$n" || -L "$base.$n" ]]; do
    n=$((n + 1))
  done
  cp -p -- "$1" "$base.$n" && echo "ℹ️  Kept a copy of $1 (it may hold your own edits) as $base.$n" >&2
}

# keep_if_edited FILE [SHIPPED]: before a plugin-owned FILE is replaced or
# removed, keep a copy when it was edited since install, or, with no record,
# when it differs from SHIPPED (this release's copy, when there is one).
keep_if_edited() {
  local state=0
  [[ -f "$1" && ! -L "$1" ]] || return 0
  installed_state "$1" || state=$?
  if (( state == 0 )); then
    stash_file "$1"
  elif (( state == 2 )) && ! { [[ -n "${2:-}" ]] && cmp -s -- "$1" "$2"; }; then
    stash_file "$1"
  fi
}

# The `gemini` shim releases before 88721ac installed (it ran agy with
# --dangerously-skip-permissions). Only that exact file is the plugin's;
# anything else at ~/.local/bin/gemini is the user's.
is_legacy_gemini_shim() {
  [[ -f "$1" && ! -L "$1" ]] && (( $(stat -c %s -- "$1") < 512 )) || return 1
  [[ "$(cat -- "$1")" == "#!/bin/bash
# Executable shim to run Antigravity CLI as Omarchy's gemini provider
exec agy --dangerously-skip-permissions \"\$@\"" ]]
}

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
  # A config kept as a symlink (stow, chezmoi) stays one: the change is
  # written to the file it points at.
  if [[ -L "$file" ]]; then
    file=$(realpath -e -- "$file") || return 1
  fi
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

# 1. Remove binaries. A copy edited since install is kept in the backup
# folder first.
for bin_name in omarchy-agent-usage-antigravity omarchy-antigravity omarchy-antigravity-statusline; do
  keep_if_edited "$BIN_DIR/$bin_name" "$SCRIPT_DIR/bin/$bin_name"
  rm -f "$BIN_DIR/$bin_name"
done
# The agent launcher shadows Omarchy's own; only the plugin's copy goes, so the
# stock launcher takes over again.
if has_marker "$BIN_DIR/omarchy-agent" "$AGENT_LAUNCHER_MARKER_RE"; then
  keep_if_edited "$BIN_DIR/omarchy-agent" "$SCRIPT_DIR/bin/omarchy-agent"
  rm -f "$BIN_DIR/omarchy-agent"
fi

# Undo the Antigravity CLI status line only where it is still this plugin's:
# a statusline.sh without the marker, and any statusLine entry not pointing
# at the plugin's script, belong to the user and are left alone.
AGY_CLI_DIR="$HOME/.gemini/antigravity-cli"
AGY_SETTINGS="$AGY_CLI_DIR/settings.json"
STATUSLINE="$AGY_CLI_DIR/statusline.sh"
# The statusLine entry the user had before install (kept aside by install).
STATUSLINE_PREVIOUS="$AGY_CLI_DIR/statusline.omarchy-antigravity.previous.json"
if has_marker "$STATUSLINE" "$STATUSLINE_MARKER_RE"; then
  keep_if_edited "$STATUSLINE" "$SCRIPT_DIR/bin/omarchy-antigravity-statusline"
  if [[ -f "$STATUSLINE.bak" ]] && ! has_marker "$STATUSLINE.bak" "$STATUSLINE_MARKER_RE"; then
    # The user's own script comes back at the same path, so a statusLine
    # entry pointing there keeps working and is kept.
    mv -f "$STATUSLINE.bak" "$STATUSLINE"
  else
    previous='null'
    if [[ -f "$STATUSLINE_PREVIOUS" ]] && jq -e 'type == "object"' "$STATUSLINE_PREVIOUS" >/dev/null 2>&1; then
      previous=$(jq -c . "$STATUSLINE_PREVIOUS")
    fi
    if [[ -f "$AGY_SETTINGS" ]] && ! update_json "$AGY_SETTINGS" '
      if ((.statusLine? | objects | .command?) // "") == $script
      then (if $previous == null then del(.statusLine) else .statusLine = $previous end)
      else . end
    ' --arg script "$STATUSLINE" --argjson previous "$previous"; then
      echo "⚠️  Could not update $AGY_SETTINGS; left it unchanged." >&2
    fi
    rm -f "$STATUSLINE" "$STATUSLINE.bak"
  fi
elif has_marker "$STATUSLINE.bak" "$STATUSLINE_MARKER_RE"; then
  rm -f "$STATUSLINE.bak"
fi
rm -f "$STATUSLINE_PREVIOUS"

# If a legacy gemini permission-bypass shim exists from a prior install, clean it up safely
if is_legacy_gemini_shim "$BIN_DIR/gemini"; then
  rm -f "$BIN_DIR/gemini"
fi

# 2. Remove hook
rm -f "$HOOK_FILE"

# 2b. Agents widget. A plugin folder this installer cloned is removed whole:
# omarchy-plugin-remove also switches the bar back to the built-in widget
# (keeping a hidden backup of the folder). Without it, the folder is moved
# aside the same way rather than deleted, since it may hold the user's own
# edits, and the bar is pointed back at Omarchy's widget here. A folder that
# already existed gets its pre-install UI back, and the current files (with
# any edits made since) are kept as timestamped backups.
restore_ui_file() {
  local file="$1"
  [[ -f "$file.bak" ]] || return 0
  if [[ -f "$file" ]] && ! cmp -s "$file" "$file.bak"; then
    backup_file "$file" || true
  fi
  mv -f "$file.bak" "$file"
}
if [[ -f "$USER_PLUGIN_DIR/$CLONE_MARKER" && ! -L "$USER_PLUGIN_DIR" ]]; then
  if ! command -v omarchy-plugin-remove >/dev/null 2>&1 ||
     ! omarchy-plugin-remove "$USER_PLUGIN_ID" --yes >/dev/null 2>&1; then
    n=$(date +%s)
    while [[ -e "$CONFIG_DIR/plugins/.$USER_PLUGIN_ID.bak.$n" ]]; do
      n=$((n + 1))
    done
    mv -- "$USER_PLUGIN_DIR" "$CONFIG_DIR/plugins/.$USER_PLUGIN_ID.bak.$n"
    if [[ -f "$SHELL_CONFIG" ]] && ! update_json "$SHELL_CONFIG" '
      def fork: type == "object" and .id? == $id;
      if any(.bar.layout[]?[]?; type == "object" and .id? == "omarchy.agents")
      then .bar.layout |= with_entries(.value |= (if type == "array" then map(select(fork | not)) else . end))
      else (.bar.layout[]?[]? | select(fork)) |= (.id = "omarchy.agents")
      end
    ' --arg id "$USER_PLUGIN_ID"; then
      echo "⚠️  Could not point the bar back at Omarchy's agents widget in $SHELL_CONFIG." >&2
    fi
  fi
elif [[ -d "$USER_PLUGIN_DIR" ]]; then
  for ui_file in Panel.qml Main.qml; do
    restore_ui_file "$USER_PLUGIN_DIR/$ui_file"
  done
  for asset in antigravity.svg antigravity-light.svg; do
    restore_ui_file "$USER_PLUGIN_DIR/assets/$asset"
  done
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
# The updater's lock and any temp files an interrupted run left behind too.
rm -f "$STATE_FILE" "$STATE_DIR"/.antigravity.*
for cache_file in "$CACHE_DIR"/antigravity-*; do
  if [[ -f "$cache_file" || -L "$cache_file" ]]; then
    rm -f -- "$cache_file"
  fi
done

# 4. Undo the default agent only while it is still the one the plugin set:
# the opt-in marker is touched after every write the plugin makes, so a later
# choice of the user's own (Gemini, or Omarchy 4.5's "agy") is newer and stays.
AGENT_FILE="$CONFIG_DIR/defaults/agent"
DEFAULT_MARKER="$CONFIG_DIR/antigravity.default"
if [[ -f "$AGENT_FILE" && -f "$DEFAULT_MARKER" && ! "$AGENT_FILE" -nt "$DEFAULT_MARKER" ]] &&
   [[ "$(tr -d '[:space:]' < "$AGENT_FILE")" =~ ^(antigravity|gemini|agy)$ ]]; then
  LATEST_BAK=$(find "$CONFIG_DIR/defaults" -name "agent.bak.*" 2>/dev/null | sort -V | tail -n 1)
  if [[ -n "$LATEST_BAK" && -f "$LATEST_BAK" ]]; then
    mv "$LATEST_BAK" "$AGENT_FILE"
    echo "Restored previous default agent from backup: $(cat "$AGENT_FILE")"
  else
    rm -f "$AGENT_FILE"
    echo "Removed Antigravity as default agent."
  fi
fi
rm -f "$DEFAULT_MARKER" "$CONFIG_DIR/antigravity.native-adopted"
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
  keep_if_edited "$UPDATER" "$SCRIPT_DIR/bin/omarchy-agent-usage-update"
  if [[ -f "$UPDATER_BAK" ]]; then
    mv -f "$UPDATER_BAK" "$UPDATER"
  elif [[ -f "$LEGACY_UPDATER_BAK" ]]; then
    mv -f "$LEGACY_UPDATER_BAK" "$UPDATER"
  else
    rm -f "$UPDATER"
  fi
fi

rm -f "$INSTALL_MANIFEST"

echo "✅ Antigravity integration removed."
if [[ -d "$PLUGIN_BACKUP_DIR" ]]; then
  echo "   Your edited copies of plugin files are kept in $PLUGIN_BACKUP_DIR."
fi
echo "   Run 'omarchy restart shell' to reload."
