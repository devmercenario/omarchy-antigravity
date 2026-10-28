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
  if (( backup )); then
    cp -p "$file" "$file.bak.$(date +%s)" || return 1
  fi
  mv -f "$tmp" "$file"
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
# is useless (and was what the collector glob re-executed); a genuine stock or
# user helper moves to the hidden name.
if [[ -f "$LEGACY_UPDATER_BAK" && ! -L "$LEGACY_UPDATER_BAK" ]]; then
  if has_marker "$LEGACY_UPDATER_BAK" "$UPDATER_MARKER_RE"; then
    rm -f "$LEGACY_UPDATER_BAK"
  elif [[ ! -e "$UPDATER_BAK" ]]; then
    mv "$LEGACY_UPDATER_BAK" "$UPDATER_BAK"
  fi
fi
# A backup that is itself a plugin copy (an earlier reinstall backed up the
# plugin's own helper) would be "restored" over the stock helper on uninstall.
if has_marker "$UPDATER_BAK" "$UPDATER_MARKER_RE"; then
  rm -f "$UPDATER_BAK"
fi
for bin_src in "$SCRIPT_DIR/bin/omarchy-agent-usage-antigravity" \
               "$SCRIPT_DIR/bin/omarchy-agent-usage-update" \
               "$SCRIPT_DIR/bin/omarchy-antigravity" \
               "$SCRIPT_DIR/bin/omarchy-antigravity-statusline"; do
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
  # omarchy-agent-usage-update shadows the stock Omarchy helper of the same
  # name on PATH; preserve a prior copy so uninstall can restore it. The
  # backup is a hidden dotfile so the collector-discovery glob
  # `omarchy-agent-usage-*` (which that helper itself uses) can never mistake
  # the backup for a collector and re-execute it recursively. On a reinstall
  # the target is the plugin's own copy, which is never backed up.
  if [[ "$bin_name" == "omarchy-agent-usage-update" && -f "$target" && ! -e "$UPDATER_BAK" ]] &&
     ! cmp -s "$bin_src" "$target" && ! has_marker "$target" "$UPDATER_MARKER_RE"; then
    cp "$target" "$UPDATER_BAK" 2>/dev/null || true
  fi
  cp -f "$bin_src" "$target"
  chmod +x "$target"
done

# Safely clean up legacy gemini permission-bypass shim from prior versions
if [[ -f "$BIN_DIR/gemini" ]] && grep -q -- '--dangerously-skip-permissions' "$BIN_DIR/gemini" 2>/dev/null; then
  echo "🧹 Cleaning up legacy gemini permission-bypass shim..."
  rm -f "$BIN_DIR/gemini"
fi

# Ensure ~/.local/bin is in PATH for current subshell
export PATH="$BIN_DIR:$PATH"

# 3. Configure Antigravity as the default Omarchy agent (with explicit consent)
mkdir -p "$CONFIG_DIR/defaults"
AGENT_FILE="$CONFIG_DIR/defaults/agent"
CURRENT_AGENT=""
[[ -f "$AGENT_FILE" ]] && CURRENT_AGENT=$(cat "$AGENT_FILE")

should_set_default=false
if [[ "$SET_DEFAULT" == "yes" ]]; then
  should_set_default=true
elif [[ "$SET_DEFAULT" == "no" ]]; then
  should_set_default=false
elif (( ASSUME_YES )); then
  should_set_default=true
elif [[ -n "$CURRENT_AGENT" && "$CURRENT_AGENT" != "antigravity" ]]; then
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
  if [[ -f "$AGENT_FILE" && "$CURRENT_AGENT" != "antigravity" ]]; then
    cp "$AGENT_FILE" "$AGENT_FILE.bak.$(date +%s)"
  fi
  echo "antigravity" > "$AGENT_FILE"
  touch "$CONFIG_DIR/antigravity.default"
else
  echo "ℹ️  Keeping '$CURRENT_AGENT' as default agent."
fi
prune_backups "$AGENT_FILE"

# 4. Enable Antigravity provider in shell.json (preserving backup)
if [[ -f "$SHELL_CONFIG" ]]; then
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
  # Preserve any pre-existing user UI edits (idempotent single-slot backups)
  # before installing this plugin's Panel/Main and assets.
  for ui_file in Panel.qml Main.qml; do
    if [[ -f "$USER_PLUGIN_DIR/$ui_file" && ! -f "$USER_PLUGIN_DIR/$ui_file.bak" ]]; then
      cp "$USER_PLUGIN_DIR/$ui_file" "$USER_PLUGIN_DIR/$ui_file.bak" 2>/dev/null || true
    fi
    cp -f --remove-destination "$SCRIPT_DIR/ui/$ui_file" "$USER_PLUGIN_DIR/$ui_file"
  done
  mkdir -p "$USER_PLUGIN_DIR/assets"
  for asset in antigravity.svg antigravity-light.svg; do
    if [[ -f "$USER_PLUGIN_DIR/assets/$asset" && ! -f "$USER_PLUGIN_DIR/assets/$asset.bak" ]]; then
      cp "$USER_PLUGIN_DIR/assets/$asset" "$USER_PLUGIN_DIR/assets/$asset.bak" 2>/dev/null || true
    fi
    cp -f --remove-destination "$SCRIPT_DIR/assets/$asset" "$USER_PLUGIN_DIR/assets/$asset"
  done
  if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  fi
fi

# 6. Configure Antigravity CLI (agy) bottom status bar
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
    cp "$STATUSLINE_DST" "$STATUSLINE_DST.bak" 2>/dev/null || true
  fi
  cp -f --remove-destination "$STATUSLINE_SRC" "$STATUSLINE_DST"
  chmod +x "$STATUSLINE_DST"

  AGY_SETTINGS="$AGY_CLI_DIR/settings.json"
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
"$BIN_DIR/omarchy-agent-usage-update" --force antigravity >/dev/null 2>&1 || true

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
  echo "👉 You can click 'Sign In' in the bar panel or run:"
  echo "     omarchy-antigravity auth"
else
  echo "✅ Antigravity is authenticated and operational!"
fi

echo ""
echo "🚀 Installation completed successfully!"
echo "   Run 'omarchy restart shell' if your bar did not automatically reload."
