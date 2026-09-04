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

# Remove binaries
rm -f "$BIN_DIR/omarchy-agent-usage-antigravity" \
      "$BIN_DIR/omarchy-antigravity" \
      "$BIN_DIR/gemini"

# Remove hook
rm -f "$HOOK_FILE"

# Remove cache and state
rm -f "$STATE_FILE" \
      "$CACHE_DIR/antigravity-limits.json" \
      "$CACHE_DIR/antigravity-user.json"

# Reset default agent if it was gemini
if [[ -f "$CONFIG_DIR/defaults/agent" ]] && [[ "$(cat "$CONFIG_DIR/defaults/agent")" == "gemini" ]]; then
  rm -f "$CONFIG_DIR/defaults/agent"
  echo "Reset default agent."
fi

# Refresh agents
if [[ -x "$BIN_DIR/omarchy-agent-usage-update" ]]; then
  "$BIN_DIR/omarchy-agent-usage-update" >/dev/null 2>&1 || true
fi

echo "✅ Antigravity integration removed."
echo "   Run 'omarchy restart shell' to reload."
