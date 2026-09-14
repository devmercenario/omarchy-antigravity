# 🛠️ Contributing & Engineering Guide

> **Scope**: This document is the technical architecture manual for contributors extending or maintaining the `omarchy-antigravity` project.

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
├── docs/
│   └── CONTRIBUTING.md                 # Technical architecture manual for contributors
├── LICENSE                             # MIT License
├── manifest.json                       # Official Omarchy shell plugin manifest (devmercenario.antigravity)
├── preview.png                         # Root visual preview for Omarchy Marketplace listing
├── Service.qml                         # Omarchy background service for periodic checks and IPC
├── install.sh                          # Automated idempotent installer
├── uninstall.sh                        # Clean uninstaller that restores system defaults
├── assets/
│   ├── agy-agent.png                   # Visual preview screenshot of the Antigravity bar panel
│   ├── antigravity.svg                 # White/accent 4-point spark logo for dark themes
│   └── antigravity-light.svg           # Dark 4-point spark logo for light themes
├── bin/
│   ├── omarchy-agent-usage-antigravity # Python collector for Google Cloud Code / Antigravity quota
│   ├── omarchy-agent-usage-update      # Multi-provider runner (unifies /usr/share and ~/.local/bin)
│   ├── omarchy-antigravity             # User CLI helper (run | auth | status | refresh | statusline | help)
│   └── omarchy-antigravity-statusline  # Dynamic theme-aware status bar for Antigravity CLI (agy)
├── hooks/
│   └── post-update.d/
│       └── 90-antigravity.hook          # Omarchy update hook to ensure persistence
├── tests/                              # Automated test suites (unit, manifest, hook, installer, statusline)
│   ├── run_tests.sh                    # Master test runner
│   ├── test_collector.py               # Quota extraction & process polling unit tests
│   ├── test_manifest.sh                # Schema & manifest validation
│   ├── test_installer.sh               # Install & uninstall lifecycle tests
│   ├── test_hook.sh                    # Post-update hook persistence tests
│   ├── test_cli.sh                     # CLI commands & argument verification
│   └── test_statusline.sh              # Status bar rendering, clock alignment, & detection tests
├── ui/
│   ├── Main.qml                        # Usage discovery & dynamic default agent watcher
│   └── Panel.qml                       # Enhanced Agents panel (status bar warning & 1-click login)
```

---

## 3. Data & Authentication Flow

```
┌──────────────────────────────────────────────┐
│       Google Antigravity CLI ('agy')         │
└──────────────────────┬───────────────────────┘
                       │ 1. Writes token to file ~/.gemini/.../antigravity-oauth-token
                       │ 2. Writes credentials to Secret Service keyring
                       ▼
┌──────────────────────────────────────────────┐
│  Credential Resolution Order                 │
│  1. File: ~/.gemini/.../antigravity-oauth-token│
│  2. Keyring: service gemini, user antigravity│
└──────────────────────┬───────────────────────┘
                       │ Reads access/refresh tokens
                       ▼
┌──────────────────────────────────────────────┐
│  bin/omarchy-agent-usage-antigravity         │
│  1. Check token expiry (refresh if needed)   │
│  2. Fetch POST /v1internal:retrieveQuota     │
│     └─ Fallback: `agy -p /usage` on failure  │
│  3. Read local history (~/.gemini/...)       │
│  4. Emit JSON to stdout                      │
└──────────────────────┬───────────────────────┘
                       │ Writes atomic record (TTL: 30s)
                       ▼
┌──────────────────────────────────────────────┐
│  ~/.local/state/omarchy/agents/usage/        │
│  antigravity.json                            │
└──────────────────────┬───────────────────────┘
                       │ Watched by FileView in QML (60s timer)
                       ▼
┌──────────────────────────────────────────────┐
│  Omarchy Bar Widget & Agents Dashboard       │
│  - Real-time limit meters (5h & Weekly)      │
│  - Urgent bar warning on auth failure        │
│  - 1-Click "Sign In" button via Quickshell   │
└──────────────────────────────────────────────┘
```

### 3.1. Credential Resolution (File & Keyring)
The collector resolves authentication tokens in order:
1. **Token File (Primary)**:
   - Path: `~/.gemini/antigravity-cli/antigravity-oauth-token`
   - Format: JSON object containing `"token"` key with `access_token`, `refresh_token`, and `expiry`.
2. **Keyring (Fallback)**:
   - Lookup Command:
     ```bash
     secret-tool lookup service gemini username antigravity
     ```
   - Same JSON structure.

### 3.2. Automatic OAuth2 Token Refresh
If `access_token` is expired or within 120 seconds of expiration:
- **Endpoint**: `POST https://oauth2.googleapis.com/token`
- **Parameters**:
  - `client_id`: Antigravity Installed App Client ID (configurable via `ANTIGRAVITY_CLIENT_ID`)
  - `client_secret`: Standard Native Client Secret (configurable via `ANTIGRAVITY_CLIENT_SECRET`)
  - `grant_type`: `refresh_token`
  - `refresh_token`: `<stored_refresh_token>`
- **Storage**: Updates both the token file (if present) and the system keyring via `secret-tool store`.

### 3.3. Authoritative Quota Endpoint & CLI Fallback
- **Primary Endpoint**: `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`
- **CLI Fallback (`agy -p /usage`)**: If the API call fails or credentials are not yet initialized, the collector runs `agy -p /usage` and parses the tabular output:
  ```tsv
  Gemini Models	Weekly Limit Remaining	27%	2026-09-10T18:37:23Z
  Gemini Models	Five Hour Limit Remaining	52%	2026-09-09T03:56:17Z
  ```
- **Cache TTL**: In-memory cache is persisted to `~/.cache/omarchy/agent-usage/antigravity-limits.json` with a 30-second TTL (`CACHE_TTL_SECONDS = 30`) to balance responsiveness and rate-limiting.
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

### 5.3. Dynamic Default Agent Synchronization
Antigravity is designed as a first-class, **optional** agent that coexists with all other Omarchy agents (Claude, Codex, Fireworks, etc.). Users can freely change their default agent at any time (`omarchy default agent <name>`), and the bar/panel dynamically reflects the change in real-time:

- `defaultAgentWatcher` (`FileView` in `ui/Panel.qml`) watches `~/.config/omarchy/defaults/agent`.
- When `defaults/agent` changes:
  - If set to `claude`: `Panel.qml` switches its active provider to Claude, displaying Claude's rate limits and tokens.
  - If set to `gemini` or `antigravity`: `Panel.qml` switches to Antigravity, displaying Gemini/Claude quota windows and prompt metrics.
  - Right-clicking the bar button executes `omarchy-agent --pick`, which always invokes the user's current default agent.
  - In the panel tab strip, users can still click or middle-click to browse any other enabled provider tabs.

### 5.4. Multi-Provider Runner & Refresh Cadence
- **Multi-Collector Runner (`omarchy-agent-usage-update`)**:
  - Scans both `/usr/share/omarchy/bin/omarchy-agent-usage-*` and `~/.local/bin/omarchy-agent-usage-*` to execute all available collectors.
  - Supports `--limits-only` (rapid quota polling), `--force` (cache bypass), and `--except <id>` (skip providers disabled in `shell.json`).
  - Writes atomically to `~/.local/state/omarchy/agents/usage/<id>.json` using temporary files and `jq` validation before replacement.
- **Refresh Intervals**:
  - `ui/Main.qml` defaults to `refreshIntervalSec: 60` (1 minute), configurable in `shell.json`.
  - The optional systemd user service and timer (`omarchy-agent-usage.service` / `.timer`) run every minute (`OnUnitActiveSec=1m`) to guarantee background freshness regardless of desktop shell state.
- **Session-Aware Inactivity Suspension**:
  - The collector checks `pgrep -x agy` before polling remote Google endpoints. If no active Antigravity session is found in the OS process table and a local state file already exists, it cleanly exits with code 0 without stdout output.
  - This prevents unnecessary network bandwidth, quota polling, and disk writes when the agent is idle.
  - Manual refreshes (`--force`) bypass this check to provide on-demand sync anytime.

---

## 6. Testing & Validation Checklist

The project includes an automated test suite with 100% functional test coverage. Always run the test suite before submitting pull requests or committing changes.

### Automated Test Suite:
```bash
# Run all 5 test suites
./tests/run_tests.sh
```

The test runner executes:
1. **Collector Unit & Integration Tests** (`tests/test_collector.py`):
   - Quota parsing and fraction conversion (`remainingFraction` -> `percent used`).
   - Priority sorting (Gemini 5h -> Gemini Weekly -> Claude/GPT 5h -> Claude/GPT Weekly).
   - System keyring extraction and error handling (empty keyring, corrupt JSON).
   - OAuth2 token auto-refresh flow and expiration checking.
   - Local stats aggregation (`history.jsonl` prompts parsing, date mapping, brain sessions).
   - Edge cases: CLI not installed in PATH, unauthenticated state, API network errors, stale cache fallback.
2. **Plugin Manifest Validation** (`tests/test_manifest.sh`):
   - Validates `manifest.json` against Omarchy's official `omarchy-plugin-validate` registry schema.
3. **Installer & Uninstaller Lifecycle** (`tests/test_installer.sh`):
   - Executes `install.sh` and `uninstall.sh` in an isolated sandbox environment.
   - Verifies all plugin-specific binaries are copied with `+x` permissions to `~/.local/bin`.
   - Verifies non-conflicting behavior (no hijacking of generic `gemini` executable).
   - Verifies `defaults/agent` is set to `antigravity`.
   - Verifies `shell.json` enables the `antigravity` provider.
   - Verifies `uninstall.sh` removes binaries, cache, state, and restores system defaults.
4. **Post-Update Hook Persistence** (`tests/test_hook.sh`):
   - Simulates `omarchy update` having modified user defaults.
   - Executes `90-antigravity.hook` to verify automatic restoration of settings without creating conflicting shims.
5. **CLI Functional Commands** (`tests/test_cli.sh`):
   - Verifies `omarchy-antigravity help`, `status`, and invalid command handling.

### Individual Test Execution:
```bash
# Run Python tests directly
python3 -m unittest tests/test_collector.py

# Run manifest validation
./tests/test_manifest.sh

# Run installer test
./tests/test_installer.sh
```

### GitHub Actions CI:
Every push and pull request to `main` automatically triggers `.github/workflows/test.yml` to ensure continuous regression protection.

---

## 7. Roadmap & Potential Improvements

- [ ] **Native Dedicated Bar Widget**:
  Add an alternative standalone widget (`bar-widget` in `manifest.json`) for users who want an isolated Antigravity icon with circular quota rings instead of grouping inside `omarchy.agents`.
- [ ] **Granular Model Usage Breakdowns**:
  Parse individual model session records if `agy` exports prompt/completion tokens per model into local logs.
- [ ] **Multi-Account Support**:
  Detect and support switching between multiple Google accounts stored in `google_accounts.json`.
- [ ] **Arch User Repository (AUR) Package**:
  Prepare a `PKGBUILD` for `omarchy-antigravity-git` for distribution via `yay` / `paru`.
