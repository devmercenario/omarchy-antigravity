# 🚀 Omarchy Antigravity Integration

[![Omarchy](https://img.shields.io/badge/Omarchy-Linux-blue.svg)](https://omarchy.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Arch%20Linux%20%7C%20Hyprland-lightgrey.svg)]()

Complete integration of Google Antigravity CLI (`agy`) for [Omarchy](https://omarchy.org/) Linux:
- 📊 **Real-time Quota Meters**: 5-hour session and weekly limits for Gemini and Claude/GPT model groups directly in the Omarchy bar panel.
- ⚡ **Default Agent Shim**: Launch Antigravity anywhere via Omarchy hotkey (`SUPER + SHIFT + CTRL + A`), terminal (`omarchy agent`), or right-clicking the bar icon.
- 🔔 **Status Bar Warnings**: The bar icon lights up in warning color with a tooltip when authentication is required or expired.
- 🔑 **1-Click Authentication**: Interactive **"Entrar"** button in the dashboard opens a floating terminal to log in to Google immediately.
- 🔄 **Auto-Persistence**: Includes an `omarchy update` hook so your setup never gets wiped during system upgrades.
- 🛡️ **Zero System Pollution**: Installs entirely in user-space (`~/.local/bin`, `~/.config/omarchy/`).

---

## 📸 Overview

```
┌──────────────────────────────────────────────┐
│  󱚣 Antigravity      Pro · user@gmail.com    │
├──────────────────────────────────────────────┤
│  Gemini (5h)        [████████░░] 82% · 4h    │
│  Gemini (Weekly)    [██████████] 95% · 6d    │
│  Claude/GPT (5h)    [██████████] 100%        │
│  Claude/GPT (Weekly)[██████████] 100%        │
├──────────────────────────────────────────────┤
│  Today: 14 prompts · 1 session               │
└──────────────────────────────────────────────┘
```

When not authenticated:
- **Bar Icon**: Lights up in warning color with tooltip `"Antigravity: Waiting for auth"`.
- **Panel Banner**: Shows an alert box with a direct **[ 󰌑 Entrar ]** button that launches the Google OAuth login with 1 click.

---

## 📥 Installation

### Option 1: Quick Install (Recommended)

Clone and run the automated installer:

```bash
git clone https://github.com/devmercenario/omarchy-antigravity.git
cd omarchy-antigravity
chmod +x install.sh
./install.sh
```

### Option 2: Omarchy Plugin Manager

```bash
omarchy plugin add https://github.com/devmercenario/omarchy-antigravity.git --enable --yes
```

---

## 🛠️ CLI Management Tool

This package includes a handy `omarchy-antigravity` helper:

```bash
# Check status, token in keyring, and live quotas
omarchy-antigravity status

# Launch interactive Google authentication
omarchy-antigravity auth

# Force refresh quota from Google Cloud API and update the bar
omarchy-antigravity refresh
```

---

## ⚙️ How It Works Under the Hood

1. **Quota Extraction**:
   The collector [`omarchy-agent-usage-antigravity`](bin/omarchy-agent-usage-antigravity) securely reads the Google Cloud Code OAuth token from your system keyring via `secret-tool`. If expired, it automatically refreshes it with Google OAuth endpoints, fetches authoritative bucket quotas from Google's Cloud Code internal API, and calculates local prompt metrics from `~/.gemini/antigravity-cli/history.jsonl`.
2. **Default Agent Dispatch**:
   Installs `gemini` in `~/.local/bin/` as an executable shim that runs `agy --dangerously-skip-permissions "$@"`. Sets `~/.config/omarchy/defaults/agent` to `gemini`.
3. **Bar Widget & Status Alerts**:
   Integrates into the Quickshell bar. When quota is low or when authentication is missing, the bar button triggers an urgent visual alert.
4. **Update Hook**:
   Drops `90-antigravity.hook` into `~/.config/omarchy/hooks/post-update.d/` so every time you run `omarchy update`, your default agent and widgets remain active.

---

## 🗑️ Uninstallation

To completely remove the integration and revert to system defaults:

```bash
./uninstall.sh
omarchy restart shell
```

---

## 📄 License

MIT License © 2026 [devmercenario](https://github.com/devmercenario)
