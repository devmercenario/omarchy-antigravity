#!/bin/bash
# ==============================================================================
# Omarchy Antigravity Integration Installer
# Repository: https://github.com/devmercenario/omarchy-antigravity
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/omarchy"
HOOKS_DIR="$CONFIG_DIR/hooks/post-update.d"
SHELL_CONFIG="$CONFIG_DIR/shell.json"

# Marker lines that identify this plugin's own copy of a file it installs
# over (the current marker, or the header every earlier release carried).
STATUSLINE_MARKER_RE='^# (omarchy-antigravity: statusline|Omarchy Antigravity CLI Statusline)$'
UPDATER_MARKER_RE='^# (omarchy-antigravity: agent-usage-update|omarchy:summary=Update local usage records for all configured coding agents)$'
AGENT_LAUNCHER_MARKER_RE='^# omarchy-antigravity: agent-launcher$'

# Omarchy 4.5 and later ship Antigravity support of their own (agent id "agy",
# a usage collector and the panel icon). There the plugin installs only the
# status line and its helper, and `omarchy-antigravity adopt-native` hands
# the rest over.
NATIVE_ANTIGRAVITY=0
[[ -x "${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-agent-usage-agy" ]] && NATIVE_ANTIGRAVITY=1
# Dropped into the agents plugin folder when this installer created it.
CLONE_MARKER=".omarchy-antigravity-cloned"

# True when $1 is a regular file (not a symlink) carrying marker regex $2.
has_marker() {
  [[ -f "$1" && ! -L "$1" ]] && grep -qE -- "$2" "$1" 2>/dev/null
}

# Temp files are removed on any exit. INT/TERM must exit explicitly: a trap
# that only cleans up would let the install carry on after Ctrl-C.
TMP_FILES=()
cleanup_tmp() {
  (( ${#TMP_FILES[@]} == 0 )) || rm -f -- "${TMP_FILES[@]}"
}
trap cleanup_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Copy $1 to $1.bak.<epoch>, keeping its mode (a private file stays
# private); a second backup in the same second takes the next free number
# instead of overwriting the first.
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

# update_json [--backup] FILE FILTER [jq args...]
# Rewrite FILE through the jq FILTER, but only when the result differs (as
# JSON) from what is there: an unchanged file keeps its bytes, inode and
# mtime. The temp file is created next to FILE so the final mv is an atomic
# same-filesystem rename (the bar watches shell.json), and it takes FILE's
# mode. --backup keeps the previous version as FILE.bak.<epoch>; callers
# prune those with prune_backups.
update_json() {
  local backup=0 file filter tmp
  if [[ "$1" == "--backup" ]]; then
    backup=1
    shift
  fi
  file="$1"
  filter="$2"
  shift 2
  # A config kept as a symlink (stow, chezmoi) stays one: the change is
  # written to the file it points at; a backup still lands next to the link.
  local real="$file"
  if [[ -L "$file" ]]; then
    real=$(realpath -e -- "$file") || return 1
  fi
  tmp=$(mktemp "$real.XXXXXX") || return 1
  TMP_FILES+=("$tmp")
  if ! jq "$@" "($filter) as \$new | if \$new == . then empty else \$new end" "$real" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 0
  fi
  chmod --reference="$real" "$tmp" 2>/dev/null || true
  if (( backup )); then
    backup_file "$file" || return 1
  fi
  mv -f "$tmp" "$real"
}

ASSUME_YES=0
SET_DEFAULT=""
INSTALL_STATUSLINE=""

while (( $# > 0 )); do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    --set-default)
      SET_DEFAULT="yes"
      shift
      ;;
    --no-default)
      SET_DEFAULT="no"
      shift
      ;;
    -s|--statusline|--with-statusline)
      INSTALL_STATUSLINE="yes"
      shift
      ;;
    --no-statusline)
      INSTALL_STATUSLINE="no"
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: ./install.sh [options]

Options:
  -y, --yes          Automatic yes to prompts (non-interactive)
  --set-default      Explicitly set Antigravity as the default Omarchy agent
  --no-default       Keep existing default agent intact
  -s, --statusline   Install/enable theme-aware status bar for Antigravity CLI (agy)
  --no-statusline    Do not configure status bar for Antigravity CLI
  -h, --help         Show this help message
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

echo "✨ Installing Antigravity Integration for Omarchy..."

# 1. Dependency checks
echo "🔍 Checking dependencies..."
MISSING_DEPS=()
for dep in secret-tool jq python3; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    MISSING_DEPS+=("$dep")
  fi
done

if (( ${#MISSING_DEPS[@]} > 0 )); then
  echo "❌ Missing required dependencies: ${MISSING_DEPS[*]}" >&2
  echo "Please install them via: omarchy pkg add ${MISSING_DEPS[*]}" >&2
  exit 1
fi

if ! command -v agy >/dev/null 2>&1; then
  echo "⚠️  Antigravity CLI ('agy') was not found in PATH."
  echo "   You can install it before or after this setup."
fi

# 2. Install executable binaries to ~/.local/bin
echo "📦 Installing binaries to $BIN_DIR..."
mkdir -p "$BIN_DIR"
UPDATER_BAK="$BIN_DIR/.omarchy-agent-usage-update.bak"
LEGACY_UPDATER_BAK="$BIN_DIR/omarchy-agent-usage-update.bak"
# Earlier releases kept the backup under a visible name. A plugin copy there
# is useless (and was what the collector glob re-executed). A stock or user
# helper there is the pre-install one only while the plugin's helper is in
# place, so only then does it move to the hidden name; next to a helper of the
# user's own it is a file of theirs and stays put (the updater never runs a
# name starting with "update").
if [[ -f "$LEGACY_UPDATER_BAK" && ! -L "$LEGACY_UPDATER_BAK" ]]; then
  if has_marker "$LEGACY_UPDATER_BAK" "$UPDATER_MARKER_RE"; then
    rm -f "$LEGACY_UPDATER_BAK"
  elif [[ ! -e "$UPDATER_BAK" ]] && has_marker "$BIN_DIR/omarchy-agent-usage-update" "$UPDATER_MARKER_RE"; then
    mv "$LEGACY_UPDATER_BAK" "$UPDATER_BAK"
  fi
fi
# A backup that is itself a plugin copy (an earlier reinstall backed up the
# plugin's own helper) would be "restored" over the stock helper on uninstall.
if has_marker "$UPDATER_BAK" "$UPDATER_MARKER_RE"; then
  rm -f "$UPDATER_BAK"
fi
# The launcher stays on Omarchy 4.5 too: it keeps the plugin's "antigravity"
# default opening agy with its permission prompts, while 4.5's own "agy"
# default goes to Omarchy's launcher.
BIN_SOURCES=("$SCRIPT_DIR/bin/omarchy-agent"
             "$SCRIPT_DIR/bin/omarchy-antigravity"
             "$SCRIPT_DIR/bin/omarchy-antigravity-statusline")
if (( ! NATIVE_ANTIGRAVITY )); then
  BIN_SOURCES=("$SCRIPT_DIR/bin/omarchy-agent-usage-antigravity"
               "$SCRIPT_DIR/bin/omarchy-agent-usage-update"
               "${BIN_SOURCES[@]}")
fi
for bin_src in "${BIN_SOURCES[@]}"; do
  bin_name=$(basename "$bin_src")
  target="$BIN_DIR/$bin_name"
  # Refuse to write through an existing symlink or replace non-regular files.
  if [[ -L "$target" ]]; then
    echo "⚠️  Skipping $target: refusing to write through an existing symlink." >&2
    continue
  fi
  if [[ -e "$target" && ! -f "$target" ]]; then
    echo "⚠️  Skipping $target: non-regular file exists at destination." >&2
    continue
  fi
  # omarchy-agent shadows Omarchy's launcher so Antigravity can be the default
  # agent; a launcher of the user's own there is theirs and is left alone.
  if [[ "$bin_name" == "omarchy-agent" && -f "$target" ]] &&
     ! cmp -s "$bin_src" "$target" && ! has_marker "$target" "$AGENT_LAUNCHER_MARKER_RE"; then
    echo "⚠️  Skipping $target: a different omarchy-agent already exists there; Antigravity will not open as the default agent." >&2
    continue
  fi
  # omarchy-agent-usage-update shadows the stock Omarchy helper of the same
  # name on PATH; preserve a prior copy so uninstall can restore it. The
  # backup is a hidden dotfile so the collector-discovery glob
  # `omarchy-agent-usage-*` (which that helper itself uses) can never mistake
  # the backup for a collector and re-execute it recursively. On a reinstall
  # the target is the plugin's own copy, which is never backed up.
  # A helper of the user's own when that slot is already taken (by the
  # pre-install one) goes to the backup folder instead of being lost.
  if [[ "$bin_name" == "omarchy-agent-usage-update" && -f "$target" ]] &&
     ! cmp -s "$bin_src" "$target" && ! has_marker "$target" "$UPDATER_MARKER_RE"; then
    if [[ ! -e "$UPDATER_BAK" ]]; then
      cp -p "$target" "$UPDATER_BAK" 2>/dev/null || true
    elif ! cmp -s "$target" "$UPDATER_BAK"; then
      stash_file "$target"
    fi
  elif [[ -f "$target" ]]; then
    # The plugin's own copy (by name or marker): keep it if it was edited.
    keep_if_edited "$target" "$bin_src"
  fi
  cp -f "$bin_src" "$target"
  chmod +x "$target"
  manifest_set "$target" record
done

# Safely clean up legacy gemini permission-bypass shim from prior versions
if is_legacy_gemini_shim "$BIN_DIR/gemini"; then
  echo "🧹 Cleaning up legacy gemini permission-bypass shim..."
  rm -f "$BIN_DIR/gemini"
fi

# Ensure ~/.local/bin is in PATH for current subshell
export PATH="$BIN_DIR:$PATH"

if (( NATIVE_ANTIGRAVITY )); then
  echo "🤝 Omarchy supports Antigravity natively; handing usage over to it..."
  "$BIN_DIR/omarchy-antigravity" adopt-native
fi

# 3. Configure Antigravity as the default Omarchy agent (with explicit consent)
mkdir -p "$CONFIG_DIR/defaults"
AGENT_FILE="$CONFIG_DIR/defaults/agent"
CURRENT_AGENT=""
[[ -f "$AGENT_FILE" ]] && CURRENT_AGENT=$(tr -d '[:space:]' < "$AGENT_FILE")
# "antigravity" on Omarchy 4.5 as well: the plugin's launcher opens agy with
# its permission prompts, where 4.5's own "agy" default would skip them.
DEFAULT_AGENT_ID="antigravity"
# The opt-in marker is touched right after every write the plugin makes, so
# the default is still the plugin's only while the agent file is not newer.
DEFAULT_MARKER="$CONFIG_DIR/antigravity.default"
plugin_owns_default() {
  [[ -f "$DEFAULT_MARKER" && -f "$AGENT_FILE" && ! "$AGENT_FILE" -nt "$DEFAULT_MARKER" ]]
}

# Releases before the Antigravity CLI set "gemini", served by a
# ~/.local/bin/gemini shim to agy that has since been removed; Omarchy now
# opens the deprecated Gemini CLI for it. Move a "gemini" default this plugin
# set to "antigravity"; a Gemini pick of the user's own (no marker, or made
# after it) stays. Omarchy 4.5's own migration handles "gemini" there.
if (( ! NATIVE_ANTIGRAVITY )) && [[ "$CURRENT_AGENT" == "gemini" ]] && plugin_owns_default; then
  echo "⚙️  Moving the legacy 'gemini' default agent to 'antigravity'..."
  echo "antigravity" > "$AGENT_FILE"
  touch "$DEFAULT_MARKER"
  CURRENT_AGENT="antigravity"
fi

should_set_default=false
if [[ "$SET_DEFAULT" == "yes" ]]; then
  should_set_default=true
elif [[ "$SET_DEFAULT" == "no" ]]; then
  should_set_default=false
elif (( ASSUME_YES )); then
  should_set_default=true
elif [[ -n "$CURRENT_AGENT" && "$CURRENT_AGENT" != "$DEFAULT_AGENT_ID" ]]; then
  echo ""
  echo "ℹ️  Current default agent is: '$CURRENT_AGENT'"
  if command -v gum >/dev/null 2>&1 && [[ -t 0 ]]; then
    if gum confirm "Would you like to set Antigravity as your default Omarchy agent?"; then
      should_set_default=true
    fi
  elif [[ -t 0 ]]; then
    read -r -p "Would you like to set Antigravity as your default agent? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      should_set_default=true
    fi
  fi
else
  should_set_default=true
fi

if [[ "$should_set_default" == true ]]; then
  echo "⚙️  Setting default agent to Antigravity..."
  if [[ -f "$AGENT_FILE" && "$CURRENT_AGENT" != "$DEFAULT_AGENT_ID" ]]; then
    backup_file "$AGENT_FILE"
  fi
  echo "$DEFAULT_AGENT_ID" > "$AGENT_FILE"
  touch "$DEFAULT_MARKER"
else
  echo "ℹ️  Keeping '$CURRENT_AGENT' as default agent."
fi
prune_backups "$AGENT_FILE"

# 4. Enable Antigravity provider in shell.json (preserving backup). Omarchy
# 4.5's own widget lists its native "agy" provider by itself.
if [[ -f "$SHELL_CONFIG" ]] && (( ! NATIVE_ANTIGRAVITY )); then
  echo "🎨 Enabling Antigravity in Omarchy bar widget..."
  # Every agents widget (the built-in omarchy.agents or a <user>.agents
  # clone) in any bar section. Missing sections and entries without a string
  # id are skipped rather than aborting the filter.
  if ! update_json --backup "$SHELL_CONFIG" '
    (.bar.layout[]?[]? | select(type == "object" and ((.id? // "") | tostring | endswith(".agents"))))
      |= (.providers.antigravity.enabled = true)
  '; then
    echo "⚠️  Could not update $SHELL_CONFIG; left it unchanged." >&2
  fi
  prune_backups "$SHELL_CONFIG"
fi

# 5. Install UI enhancement for status bar warning & 1-click auth
# Omarchy 4.5 keeps its own agents panel: the plugin's copy is built on the
# 4.0 one and would hide 4.5's panel features.
if (( ! NATIVE_ANTIGRAVITY )); then
  USER_PLUGIN_ID="${USER:-$(id -un)}.agents"
  USER_PLUGIN_DIR="$CONFIG_DIR/plugins/$USER_PLUGIN_ID"

  echo "🖥️  Setting up interactive status bar & 1-click authentication..."
  if [[ ! -d "$USER_PLUGIN_DIR" ]]; then
    if command -v omarchy-plugin-clone >/dev/null 2>&1; then
      omarchy-plugin-clone omarchy.agents >/dev/null 2>&1 || true
    elif [[ -d "/usr/share/omarchy/shell/plugins/agents" ]]; then
      mkdir -p "$USER_PLUGIN_DIR"
      cp -r /usr/share/omarchy/shell/plugins/agents/* "$USER_PLUGIN_DIR/" 2>/dev/null || true
    fi
    # Record that this installer created the clone, so uninstall can remove
    # it again (a folder that already existed is the user's and is kept).
    if [[ -d "$USER_PLUGIN_DIR" && ! -L "$USER_PLUGIN_DIR" ]]; then
      touch "$USER_PLUGIN_DIR/$CLONE_MARKER"
    fi
  fi

  if [[ -d "$USER_PLUGIN_DIR" ]]; then
    # The first install keeps what was there as <file>.bak (uninstall puts it
    # back). On a reinstall that .bak exists already, so a file that differs
    # from both this release's copy and the .bak (edits made after the last
    # install) gets a timestamped backup of its own before it is replaced.
    install_ui_file() {
      local src="$1" dst="$2"
      if [[ -f "$dst" ]] && ! cmp -s "$src" "$dst"; then
        if [[ ! -f "$dst.bak" ]]; then
          cp -p "$dst" "$dst.bak" 2>/dev/null || true
        elif ! cmp -s "$dst" "$dst.bak"; then
          backup_file "$dst" || true
          prune_backups "$dst"
        fi
      fi
      cp -f --remove-destination "$src" "$dst"
      manifest_set "$dst" record
    }
    for ui_file in Panel.qml Main.qml; do
      install_ui_file "$SCRIPT_DIR/ui/$ui_file" "$USER_PLUGIN_DIR/$ui_file"
    done
    mkdir -p "$USER_PLUGIN_DIR/assets"
    for asset in antigravity.svg antigravity-light.svg; do
      install_ui_file "$SCRIPT_DIR/assets/$asset" "$USER_PLUGIN_DIR/assets/$asset"
    done
    if command -v omarchy-shell >/dev/null 2>&1; then
      omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    fi
  fi
fi

# 6. Configure Antigravity CLI (agy) bottom status bar
# Releases before the status line's debug switch dumped every agy context it
# received (working directory, session details) with the default 0644 mode,
# and rewriting it in place would keep that mode: make an old dump private.
LEGACY_STATUSLINE_DUMP="$HOME/.gemini/antigravity-cli/last_statusline_input.json"
if [[ -f "$LEGACY_STATUSLINE_DUMP" && ! -L "$LEGACY_STATUSLINE_DUMP" ]]; then
  chmod 600 "$LEGACY_STATUSLINE_DUMP" 2>/dev/null || true
fi
should_install_statusline=false
if [[ "$INSTALL_STATUSLINE" == "yes" ]]; then
  should_install_statusline=true
elif [[ "$INSTALL_STATUSLINE" == "no" ]]; then
  should_install_statusline=false
elif (( ASSUME_YES )); then
  should_install_statusline=true
else
  echo ""
  if command -v gum >/dev/null 2>&1 && [[ -t 0 ]]; then
    if gum confirm "Would you like to install the Omarchy status bar for Antigravity CLI (agy)?"; then
      should_install_statusline=true
    fi
  elif [[ -t 0 ]]; then
    read -r -p "Would you like to install the Omarchy status bar for Antigravity CLI (agy)? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      should_install_statusline=true
    fi
  fi
fi

if [[ "$should_install_statusline" == true ]]; then
  echo "📊 Configuring Antigravity CLI status bar..."
  AGY_CLI_DIR="$HOME/.gemini/antigravity-cli"
  STATUSLINE_SRC="$SCRIPT_DIR/bin/omarchy-antigravity-statusline"
  STATUSLINE_DST="$AGY_CLI_DIR/statusline.sh"
  mkdir -p "$AGY_CLI_DIR"
  # Back up a status line the user wrote, once. The plugin's own copy (a
  # reinstall) is never backed up: uninstall would "restore" it and leave the
  # plugin's script behind for good. A backup that is itself a plugin copy,
  # left by earlier releases, is dropped for the same reason.
  if has_marker "$STATUSLINE_DST.bak" "$STATUSLINE_MARKER_RE"; then
    rm -f "$STATUSLINE_DST.bak"
  fi
  if [[ -f "$STATUSLINE_DST" && ! -e "$STATUSLINE_DST.bak" ]] &&
     ! cmp -s "$STATUSLINE_SRC" "$STATUSLINE_DST" && ! has_marker "$STATUSLINE_DST" "$STATUSLINE_MARKER_RE"; then
    cp -p "$STATUSLINE_DST" "$STATUSLINE_DST.bak" 2>/dev/null || true
  elif has_marker "$STATUSLINE_DST" "$STATUSLINE_MARKER_RE"; then
    keep_if_edited "$STATUSLINE_DST" "$STATUSLINE_SRC"
  fi
  cp -f --remove-destination "$STATUSLINE_SRC" "$STATUSLINE_DST"
  chmod +x "$STATUSLINE_DST"
  manifest_set "$STATUSLINE_DST" record

  AGY_SETTINGS="$AGY_CLI_DIR/settings.json"
  # A statusLine entry of the user's own (pointing anywhere but the plugin's
  # script) is kept aside once, privately, so uninstall can put it back.
  STATUSLINE_PREVIOUS="$AGY_CLI_DIR/statusline.omarchy-antigravity.previous.json"
  if [[ -f "$AGY_SETTINGS" && ! -e "$STATUSLINE_PREVIOUS" ]]; then
    (
      umask 077
      prev_tmp=$(mktemp "$STATUSLINE_PREVIOUS.XXXXXX") || exit 0
      if jq -e --arg script "$STATUSLINE_DST" \
           '.statusLine | select(type == "object" and .command? != $script)' "$AGY_SETTINGS" > "$prev_tmp" 2>/dev/null; then
        mv -f "$prev_tmp" "$STATUSLINE_PREVIOUS"
      else
        rm -f "$prev_tmp"
      fi
    )
  fi
  if [[ -f "$AGY_SETTINGS" ]]; then
    if ! update_json --backup "$AGY_SETTINGS" '
      .statusLine = {
        "type": "command",
        "command": $script,
        "enabled": true
      }
    ' --arg script "$STATUSLINE_DST"; then
      echo "⚠️  Could not update $AGY_SETTINGS; left it unchanged." >&2
    fi
    prune_backups "$AGY_SETTINGS"
  else
    jq -n --arg script "$AGY_CLI_DIR/statusline.sh" '{
      "statusLine": {
        "type": "command",
        "command": $script,
        "enabled": true
      }
    }' > "$AGY_SETTINGS"
  fi
  echo "✅ Antigravity CLI status bar configured!"
fi

# 7. Install Post-Update Hook (persists across omarchy update)
echo "🔄 Installing update persistence hook..."
mkdir -p "$HOOKS_DIR"
cp -f --remove-destination "$SCRIPT_DIR/hooks/post-update.d/90-antigravity.hook" "$HOOKS_DIR/90-antigravity.hook"
chmod +x "$HOOKS_DIR/90-antigravity.hook"

# 8. Collect initial usage metrics
echo "📊 Fetching initial quota and metrics..."
if (( NATIVE_ANTIGRAVITY )); then
  "${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-agent-usage-update" --force agy >/dev/null 2>&1 || true
else
  "$BIN_DIR/omarchy-agent-usage-update" --force antigravity >/dev/null 2>&1 || true
fi

# 9. Check authentication state
echo ""
TOKEN_FILE="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
IS_AUTH=false
if [[ -f "$TOKEN_FILE" && -s "$TOKEN_FILE" ]]; then
  IS_AUTH=true
elif secret-tool lookup service gemini username antigravity >/dev/null 2>&1; then
  # Exit status only: the secret itself never lands in a shell variable.
  IS_AUTH=true
fi

if [[ "$IS_AUTH" == false ]]; then
  echo "⚠️  Antigravity is not authenticated yet."
  echo "👉 A warning indicator will appear on your bar."
  if (( ! NATIVE_ANTIGRAVITY )); then
    echo "👉 You can click 'Sign In' in the bar panel or run:"
  else
    echo "👉 Run:"
  fi
  echo "     omarchy-antigravity auth"
else
  echo "✅ Antigravity is authenticated and operational!"
fi

echo ""
echo "🚀 Installation completed successfully!"
echo "   Run 'omarchy restart shell' if your bar did not automatically reload."
