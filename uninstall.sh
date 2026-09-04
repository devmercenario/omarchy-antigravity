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

echo "🗑️  Uninstalling Antigravity Integration for Omarchy..."

# 1. Remove binaries
rm -f "$BIN_DIR/omarchy-agent-usage-antigravity" \
      "$BIN_DIR/omarchy-antigravity" \
      "$BIN_DIR/gemini"

# 2. Remove hook
rm -f "$HOOK_FILE"

# 3. Remove cache and state
rm -f "$STATE_FILE" \
      "$CACHE_DIR/antigravity-limits.json" \
      "$CACHE_DIR/antigravity-user.json"

# 4. Remove default agent selection if Antigravity was default
rm -f "$CONFIG_DIR/antigravity.default"

# Restore previous agent backup if one exists, or remove if it was gemini
AGENT_FILE="$CONFIG_DIR/defaults/agent"
if [[ -f "$AGENT_FILE" ]] && [[ "$(cat "$AGENT_FILE")" == "gemini" ]]; then
  LATEST_BAK=$(find "$CONFIG_DIR/defaults" -name "agent.bak.*" 2>/dev/null | sort -V | tail -n 1)
  if [[ -n "$LATEST_BAK" && -f "$LATEST_BAK" ]]; then
    mv "$LATEST_BAK" "$AGENT_FILE"
    echo "Restored previous default agent from backup: $(cat "$AGENT_FILE")"
  else
    rm -f "$AGENT_FILE"
    echo "Removed Antigravity as default agent."
  fi
fi

# 5. Refresh agents
if [[ -x "$BIN_DIR/omarchy-agent-usage-update" ]]; then
  "$BIN_DIR/omarchy-agent-usage-update" >/dev/null 2>&1 || true
fi

echo "✅ Antigravity integration removed."
echo "   Run 'omarchy restart shell' to reload."
