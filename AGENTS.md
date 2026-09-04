# 🤖 AGENTS.md — Contributor & AI Agent Engineering Guide

> **Scope**: This document is the authoritative engineering manual for AI agents (and human engineers) extending or maintaining the `omarchy-antigravity` project. Read this before modifying or proposing architectural changes.

---

## 1. Project Mission & Core Tenets

`omarchy-antigravity` integrates the **Google Antigravity CLI** (`agy`) seamlessly into the [Omarchy](https://omarchy.org/) Linux environment (Arch Linux + Hyprland + Quickshell).

### Cardinal Principles:
1. **Exclusively English**: All code, docstrings, user-facing UI labels, log messages, commit messages, and documentation MUST be written in English.
2. **Never Edit `/usr/share/omarchy`**: `/usr/share/omarchy` is system-owned and overwritten on every `omarchy update`. All modifications must reside in user-space (`~/.local/bin/`, `~/.config/omarchy/`, `~/.local/state/omarchy/`).
3. **Idempotency & Non-Destructive Operation**: Install and uninstall scripts must be strictly idempotent and safe to run multiple times.
4. **Follow Omarchy Conventions**: Respect Quickshell styling tokens (`Style.*`, `Color.*`), shell plugin manifest specifications, and CLI dispatch patterns (`omarchy <group> <action>`).

---

## 2. Architecture & File Layout

```
omarchy-antigravity/
├── README.md                           # Public documentation & user guide
├── AGENTS.md                           # Technical reference for AI agents and maintainers
├── LICENSE                             # MIT License
├── manifest.json                       # Official Omarchy shell plugin manifest (devmercenario.antigravity)
├── Service.qml                         # Omarchy background service for periodic checks and IPC
├── install.sh                          # Automated idempotent installer
├── uninstall.sh                        # Clean uninstaller that restores system defaults
├── assets/
│   ├── antigravity.svg                 # White/accent 4-point spark logo for dark themes
│   └── antigravity-light.svg           # Dark 4-point spark logo for light themes
├── bin/
│   ├── omarchy-agent-usage-antigravity # Python collector for Google Cloud Code / Antigravity quota
│   ├── omarchy-agent-usage-update      # Multi-provider runner (unifies /usr/share and ~/.local/bin)
│   ├── omarchy-antigravity             # User CLI helper (auth | status | refresh | help)
│   └── gemini                          # Executable shim: agy --dangerously-skip-permissions "$@"
├── hooks/
│   └── post-update.d/
│       └── 90-antigravity.hook          # Omarchy update hook to ensure persistence
└── ui/
    └── Panel.qml                       # Enhanced Agents panel (status bar warning & 1-click login)
```

---

## 3. Data & Authentication Flow

```
┌──────────────────────────────────────────────┐
│       Google Antigravity CLI ('agy')         │
└──────────────────────┬───────────────────────┘
                       │ Writes OAuth credentials on login
                       ▼
┌──────────────────────────────────────────────┐
│  Linux Secret Service (System Keyring)       │
│  service: gemini  |  username: antigravity   │
└──────────────────────┬───────────────────────┘
                       │ Reads access/refresh tokens
                       ▼
┌──────────────────────────────────────────────┐
│  bin/omarchy-agent-usage-antigravity         │
│  1. Check token expiry (refresh if needed)   │
│  2. Fetch POST /v1internal:retrieveQuota     │
│  3. Read local history (~/.gemini/...)       │
│  4. Emit JSON to stdout                      │
└──────────────────────┬───────────────────────┘
                       │ Writes atomic record
                       ▼
┌──────────────────────────────────────────────┐
│  ~/.local/state/omarchy/agents/usage/        │
│  antigravity.json                            │
└──────────────────────┬───────────────────────┘
                       │ Watched by FileView in QML
                       ▼
┌──────────────────────────────────────────────┐
│  Omarchy Bar Widget & Agents Dashboard       │
│  - Real-time limit meters (5h & Weekly)      │
│  - Urgent bar warning on auth failure        │
│  - 1-Click "Sign In" button via Quickshell   │
└──────────────────────────────────────────────┘
```

### 3.1. Keyring Credential Extraction
- **Lookup Command**:
  ```bash
  secret-tool lookup service gemini username antigravity
  ```
- **Structure**: JSON object containing:
  ```json
  {
    "token": {
      "access_token": "ya29...",
      "refresh_token": "1//0...",
      "token_type": "Bearer",
      "expiry": "2026-09-04T13:45:00.000Z"
    }
  }
  ```

### 3.2. Automatic OAuth2 Token Refresh
If `access_token` is expired or within 120 seconds of expiration:
- **Endpoint**: `POST https://oauth2.googleapis.com/token`
- **Parameters**:
  - `client_id`: `1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com`
  - `client_secret`: `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`
  - `grant_type`: `refresh_token`
  - `refresh_token`: `<stored_refresh_token>`
- **Storage**: Updates the system keyring via:
  ```bash
  secret-tool store --label="Password for 'antigravity' on 'gemini'" service gemini username antigravity
  ```

### 3.3. Authoritative Quota Endpoint
- **URL**: `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`
- **Headers**:
  - `Authorization: Bearer <access_token>`
  - `Content-Type: application/json`
  - `User-Agent: antigravity`
- **Payload**: `{"project": "default-cli-project"}`
- **Bucket Semantics**:
  - `remainingFraction`: Decimal (e.g. `0.9467` for 94.67% remaining).
  - **Omarchy Schema Expectation**: `percent` in `limits` MUST be the fraction **USED** (`0.0` to `1.0`), calculated as:
    ```python
    used_pct = round(max(0.0, min(1.0, 1.0 - remaining_fraction)), 4)
    ```
  - Windows:
    - `"5h"` or `"Five Hour"` -> Session Window (`label: "Session"`).
    - `"weekly"` or `"Weekly"` -> Weekly Window (`label: "Weekly"`).

### 3.4. Local Transcript Metrics
- **History File**: `~/.gemini/antigravity-cli/history.jsonl`
- **Brain Sessions**: `~/.gemini/antigravity-cli/brain/*/`
- Counts: Total prompts, prompts today, active days in the last 7 days, daily prompt activity histogram.

---

## 4. Omarchy Usage JSON Schema (`antigravity.json`)

```json
{
  "schemaVersion": 1,
  "id": "antigravity",
  "name": "Antigravity",
  "updatedAt": "2026-09-04T15:22:05.030262+00:00",
  "ready": true,
  "hasLocalStats": true,
  "tierLabel": "Pro · devmercenario@gmail.com",
  "usageStatusText": "",
  "authHelpText": "",
  "limits": [
    {
      "title": "Gemini (5h)",
      "label": "Session",
      "percent": 0.5454,
      "resetsAt": "2026-09-04T17:35:27Z"
    },
    {
      "title": "Gemini (Weekly)",
      "label": "Weekly",
      "percent": 0.1093,
      "resetsAt": "2026-09-10T18:37:23Z"
    },
    {
      "title": "Claude/GPT (5h)",
      "label": "Session",
      "percent": 0.0,
      "resetsAt": "2026-09-04T20:22:04Z"
    },
    {
      "title": "Claude/GPT (Weekly)",
      "label": "Weekly",
      "percent": 0.0,
      "resetsAt": "2026-09-11T15:22:04Z"
    }
  ],
  "todayPrompts": 23,
  "todaySessions": 1,
  "todayTotalTokens": 0,
  "todayTokensByModel": {},
  "recentDays": [
    { "date": "2026-09-04", "messageCount": 23 }
  ],
  "totalPrompts": 572,
  "totalSessions": 36,
  "activeDays": 5,
  "activeDates": ["2026-09-04"],
  "modelUsage": {}
}
```

### Field Rules:
- `usageStatusText`: Reserved for error or status messages (e.g. `"Waiting for auth"`, `"Not installed"`). **Keep empty (`""`) when healthy**. If non-empty, Omarchy renders the red/urgent warning card.
- `authHelpText`: Explanatory message displayed inside the red status card when `usageStatusText` is present.
- `tierLabel`: Subtitle for the hero card (e.g. `"Pro · user@domain.com"`).

---

## 5. UI Integration & Quickshell Rules

### 5.1. Status Bar Alarming & Tooltip
In `ui/Panel.qml`:
- `authNeeded` inspects all enabled providers for non-empty `usageStatusText`.
- `alarming` is computed as:
  ```qml
  readonly property bool alarming: (!!headline && headline.percent >= 0.9) || balanceAlarming || authNeeded
  ```
- When `alarming` is `true`, `BarIconButton` lights up in `Color.urgent` (orange/red).
- The button tooltip shows the provider and reason: `"Antigravity: Waiting for auth (Click to resolve)"`.

### 5.2. 1-Click Interactive Sign-In Button
In `ui/Panel.qml`:
Inside the `BorderSurface` status banner, an action row presents the error and an interactive `Button`:
```qml
Button {
  id: authActionBtn
  text: "Sign In"
  iconText: "󰌑"
  bordered: true
  onClicked: {
    if (root.bar) root.bar.run("omarchy-launch-tui --app-id=org.omarchy.agent agy")
    root.close()
  }
}
```
This ensures zero friction for unauthenticated users.

---

## 6. Testing & Validation Checklist

When modifying this repository, execute the following validation steps:

1. **Manifest Validation**:
   ```bash
   omarchy-plugin-validate .
   ```
   Must return code `0`.

2. **Collector Execution**:
   ```bash
   ./bin/omarchy-agent-usage-antigravity --force | jq .
   ```
   Verify:
   - Valid JSON output.
   - `percent` fields are between `0.0` and `1.0`.
   - `usageStatusText` is `""` when authenticated.
   - User email is present in `tierLabel`.

3. **Status CLI Tool**:
   ```bash
   ./bin/omarchy-antigravity status
   ```

4. **Installer Test**:
   ```bash
   ./install.sh
   ```

5. **Shell Rescan & Hot Reload**:
   ```bash
   omarchy-shell shell rescanPlugins
   ```

---

## 7. Roadmap & Potential Improvements for Future Agents

- [ ] **Native Dedicated Bar Widget**:
  Add an alternative standalone widget (`bar-widget` in `manifest.json`) for users who want an isolated Antigravity icon with circular quota rings instead of grouping inside `omarchy.agents`.
- [ ] **Granular Model Usage Breakdowns**:
  Parse individual model session records if `agy` exports prompt/completion tokens per model into local logs.
- [ ] **Multi-Account Support**:
  Detect and support switching between multiple Google accounts stored in `google_accounts.json`.
- [ ] **Arch User Repository (AUR) Package**:
  Prepare a `PKGBUILD` for `omarchy-antigravity-git` for distribution via `yay` / `paru`.
