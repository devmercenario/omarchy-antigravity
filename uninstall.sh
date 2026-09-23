#!/bin/bash
# ==============================================================================
# Omarchy Antigravity Integration Uninstaller
# ==============================================================================

set -euo pipefail

BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/omarchy"
HOOK_FILE="$CONFIG_DIR/hooks/post-update.d/90-antigravity.hook"
CACHE_DIR="$HOME/.cache/omarchy/agent-usage"
STATE_FILE="$HOME/.local/state/omarchy/agents/usage/antigravity.json"
USER_PLUGIN_ID="${USER:-$(id -un)}.agents"
USER_PLUGIN_DIR="$CONFIG_DIR/plugins/$USER_PLUGIN_ID"

echo "🗑️  Uninstalling Antigravity Integration for Omarchy..."

# 1. Remove binaries
rm -f "$BIN_DIR/omarchy-agent-usage-antigravity" \
      "$BIN_DIR/omarchy-antigravity" \
      "$BIN_DIR/omarchy-antigravity-statusline"

# Clean up Antigravity CLI statusline if installed
AGY_CLI_DIR="$HOME/.gemini/antigravity-cli"
AGY_SETTINGS="$AGY_CLI_DIR/settings.json"
if [[ -f "$AGY_SETTINGS" ]]; then
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT INT TERM
  if jq 'del(.statusLine)' "$AGY_SETTINGS" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$AGY_SETTINGS"
  else
    rm -f "$tmp"
  fi
  trap - EXIT INT TERM
fi
if [[ -f "$AGY_CLI_DIR/statusline.sh.bak" ]]; then
  mv "$AGY_CLI_DIR/statusline.sh.bak" "$AGY_CLI_DIR/statusline.sh"
else
  rm -f "$AGY_CLI_DIR/statusline.sh"
fi

# If a legacy gemini permission-bypass shim exists from a prior install, clean it up safely
if [[ -f "$BIN_DIR/gemini" ]] && grep -q -- '--dangerously-skip-permissions' "$BIN_DIR/gemini" 2>/dev/null; then
  rm -f "$BIN_DIR/gemini"
fi

# 2. Remove hook
rm -f "$HOOK_FILE"

# 2b. Restore user UI edits backed up by the installer, if any.
if [[ -d "$USER_PLUGIN_DIR" ]]; then
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

# 3. Remove cache and state
rm -f "$STATE_FILE" \
      "$CACHE_DIR/antigravity-limits.json" \
      "$CACHE_DIR/antigravity-user.json"

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

# 5. Refresh agents (use the installed helper while it is still present)
if [[ -x "$BIN_DIR/omarchy-agent-usage-update" ]]; then
  "$BIN_DIR/omarchy-agent-usage-update" >/dev/null 2>&1 || true
elif command -v omarchy-agent-usage-update >/dev/null 2>&1; then
  omarchy-agent-usage-update >/dev/null 2>&1 || true
fi

# 6. Remove (or restore) the update helper we shadow-installed, so the stock
# Omarchy helper is no longer masked by a stale plugin copy.
if [[ -f "$BIN_DIR/.omarchy-agent-usage-update.bak" ]]; then
  mv -f "$BIN_DIR/.omarchy-agent-usage-update.bak" "$BIN_DIR/omarchy-agent-usage-update"
else
  rm -f "$BIN_DIR/omarchy-agent-usage-update"
fi

echo "✅ Antigravity integration removed."
echo "   Run 'omarchy restart shell' to reload."
