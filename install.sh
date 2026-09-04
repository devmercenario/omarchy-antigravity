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
  echo "Please install them via: sudo pacman -S ${MISSING_DEPS[*]}" >&2
  exit 1
fi

if ! command -v agy >/dev/null 2>&1; then
  echo "⚠️  Antigravity CLI ('agy') was not found in PATH."
  echo "   You can install it before or after this setup."
fi

# 2. Install executable binaries to ~/.local/bin
echo "📦 Installing binaries to $BIN_DIR..."
mkdir -p "$BIN_DIR"
cp -f "$SCRIPT_DIR/bin/omarchy-agent-usage-antigravity" "$BIN_DIR/"
cp -f "$SCRIPT_DIR/bin/omarchy-agent-usage-update" "$BIN_DIR/"
cp -f "$SCRIPT_DIR/bin/omarchy-antigravity" "$BIN_DIR/"
cp -f "$SCRIPT_DIR/bin/gemini" "$BIN_DIR/"
chmod +x "$BIN_DIR/omarchy-agent-usage-antigravity" \
         "$BIN_DIR/omarchy-agent-usage-update" \
         "$BIN_DIR/omarchy-antigravity" \
         "$BIN_DIR/gemini"

# Ensure ~/.local/bin is in PATH for current subshell
export PATH="$BIN_DIR:$PATH"

# 3. Configure Antigravity as the default Omarchy agent
echo "⚙️  Configuring default agent to Antigravity (gemini)..."
mkdir -p "$CONFIG_DIR/defaults"
echo "gemini" > "$CONFIG_DIR/defaults/agent"

# 4. Enable Antigravity provider in shell.json
if [[ -f "$SHELL_CONFIG" ]]; then
  echo "🎨 Enabling Antigravity in Omarchy bar widget..."
  tmp=$(mktemp)
  jq '
    .bar.layout.right |= map(
      if .id == "omarchy.agents" or (.id | endswith(".agents")) then
        .providers.antigravity.enabled = true
      else
        .
      end
    )
  ' "$SHELL_CONFIG" > "$tmp" && mv "$tmp" "$SHELL_CONFIG"
fi

# 5. Install UI enhancement for status bar warning & 1-click auth
USER_PLUGIN_ID="${USER:-$(id -un)}.agents"
USER_PLUGIN_DIR="$CONFIG_DIR/plugins/$USER_PLUGIN_ID"

echo "🖥️  Setting up interactive status bar & 1-click authentication..."
if [[ ! -d "$USER_PLUGIN_DIR" ]]; then
  if command -v omarchy-plugin-clone >/dev/null 2>&1; then
    omarchy-plugin-clone omarchy.agents >/dev/null 2>&1 || true
  fi
fi

if [[ -d "$USER_PLUGIN_DIR" ]]; then
  cp -f "$SCRIPT_DIR/ui/Panel.qml" "$USER_PLUGIN_DIR/Panel.qml"
  mkdir -p "$USER_PLUGIN_DIR/assets"
  cp -f "$SCRIPT_DIR/assets/antigravity.svg" "$USER_PLUGIN_DIR/assets/"
  cp -f "$SCRIPT_DIR/assets/antigravity-light.svg" "$USER_PLUGIN_DIR/assets/"
  if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  fi
fi

# 6. Install Post-Update Hook (persists across omarchy update)
echo "🔄 Installing update persistence hook..."
mkdir -p "$HOOKS_DIR"
cp -f "$SCRIPT_DIR/hooks/post-update.d/90-antigravity.hook" "$HOOKS_DIR/90-antigravity.hook"
chmod +x "$HOOKS_DIR/90-antigravity.hook"

# 7. Collect initial usage metrics
echo "📊 Fetching initial quota and metrics..."
"$BIN_DIR/omarchy-agent-usage-update" --force antigravity >/dev/null 2>&1 || true

# 8. Check authentication state
echo ""
RAW_TOKEN=$(secret-tool lookup service gemini username antigravity 2>/dev/null || true)
if [[ -z "$RAW_TOKEN" ]]; then
  echo "⚠️  Antigravity is not authenticated yet."
  echo "👉 A warning indicator will appear on your bar."
  echo "👉 You can click 'Entrar' in the bar panel or run:"
  echo "     omarchy-antigravity auth"
else
  echo "✅ Antigravity is authenticated and operational!"
fi

echo ""
echo "🚀 Installation completed successfully!"
echo "   Run 'omarchy restart shell' if your bar did not automatically reload."
