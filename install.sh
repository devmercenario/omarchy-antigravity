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

ASSUME_YES=0
SET_DEFAULT=""

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
    -h|--help)
      cat <<EOF
Usage: ./install.sh [options]

Options:
  -y, --yes          Automatic yes to prompts (non-interactive)
  --set-default      Explicitly set Antigravity as the default Omarchy agent
  --no-default       Keep existing default agent intact
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
elif [[ -n "$CURRENT_AGENT" && "$CURRENT_AGENT" != "gemini" ]]; then
  echo ""
  echo "ℹ️  Current default agent is: '$CURRENT_AGENT'"
  if command -v gum >/dev/null 2>&1 && [[ -t 0 ]]; then
    if gum confirm "Would you like to set Antigravity (gemini) as your default Omarchy agent?"; then
      should_set_default=true
    fi
  elif [[ -t 0 ]]; then
    read -r -p "Would you like to set Antigravity (gemini) as your default agent? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      should_set_default=true
    fi
  fi
else
  should_set_default=true
fi

if [[ "$should_set_default" == true ]]; then
  echo "⚙️  Setting default agent to Antigravity (gemini)..."
  if [[ -f "$AGENT_FILE" && "$CURRENT_AGENT" != "gemini" ]]; then
    cp "$AGENT_FILE" "$AGENT_FILE.bak.$(date +%s)"
  fi
  echo "gemini" > "$AGENT_FILE"
  touch "$CONFIG_DIR/antigravity.default"
else
  echo "ℹ️  Keeping '$CURRENT_AGENT' as default agent."
fi

# 4. Enable Antigravity provider in shell.json (preserving backup)
if [[ -f "$SHELL_CONFIG" ]]; then
  echo "🎨 Enabling Antigravity in Omarchy bar widget..."
  cp "$SHELL_CONFIG" "$SHELL_CONFIG.bak.$(date +%s)"
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
  echo "👉 You can click 'Sign In' in the bar panel or run:"
  echo "     omarchy-antigravity auth"
else
  echo "✅ Antigravity is authenticated and operational!"
fi

echo ""
echo "🚀 Installation completed successfully!"
echo "   Run 'omarchy restart shell' if your bar did not automatically reload."
