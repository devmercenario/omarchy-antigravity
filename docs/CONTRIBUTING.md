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
│   ├── omarchy-agent                   # Launcher: opens agy for the antigravity default, else Omarchy's own
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
│  1. Read token (never writes agy's creds)    │
│  2. Quota API, then `agy -p /usage` for the  │
│     pools it leaves out (cached 10 min)      │
│  3. Read local history (~/.gemini/...)       │
│  4. Emit JSON to stdout                      │
└──────────────────────┬───────────────────────┘
                       │ Writes atomic record (TTL: 60s)
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
- **Storage**: agy's token file and keyring entry are never written. The refreshed access token goes to the collector's own `0600` cache, `~/.cache/omarchy/agent-usage/antigravity-access-token.json`, keyed by a SHA-256 fingerprint of the refresh token so another account never reuses it.

### 3.3. Quota API with CLI Supplement
- **Quota API (first)**: `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`. Cheap, and the source for every pool it reports. Since October 2026 it returns only the `Claude and GPT models` group. 401/403 and other 4xx errors (except 408/429) are not retried.
- **CLI supplement (`agy -p /usage --output-format json`)**: consulted only when the API result lacks a shared pool (`Gemini`, `Claude/GPT`) or a pool seen in the last week. The collector reads `command.data.groups[].buckets[]` (`name`, `window`, `remaining_fraction`, `reset_time`) and adds only the pools the API left out. Every `agy -p` call starts the user's MCP servers, so its answer (failures included) is cached for 10 minutes in `antigravity-agy-usage.json`; `--force` bypasses that cache. The call is a slash command (no model turn, no history entry), `--log-file /dev/null` keeps it from rotating the user's session logs, and it runs in its own process group so a timeout kills agy's MCP servers too. The two shared pools are shortened to `Gemini` and `Claude/GPT`; any other pool keeps its own name (for example `Gemini 4 Argon (Weekly)`). When an older CLI prints only the table, its tab-separated rows are parsed by shape:
  ```tsv
  Gemini Models	Weekly Limit Remaining	27%	2026-09-10T18:37:23Z
  Gemini 4 Argon	Gemini 4 Argon Weekly Limit	88%	2026-11-04T14:02:51Z
  ```
- **Completeness Check**: pools are remembered for a week in `antigravity-groups.json`. A pool reported during that week that is now missing, or an empty result, sets `usageStatusText: "Usage incomplete"` with an explanation in `authHelpText`; a pool unseen for longer is treated as retired. A plan that never had a pool is never flagged.
- **Notifications**: `notify-send` fires when the same problem status shows up on two consecutive runs, once per status (remembered in `antigravity-alert.json`, re-armed when it clears). The body is markup-escaped. `authRequired` is `true` only for `Waiting for auth`, which is the only status that shows the panel's Sign In button.
- **Failures**: every run has a 50-second budget shared by all requests and helpers. Any unexpected exception still prints a record with `usageStatusText: "Collector error"` (keeping the last limits), so the panel never freezes silently on stale data.
- **Account label**: `tierLabel` is `"<plan> · <email>"`: the plan from `loadCodeAssist` (`paidTier.name`, else `currentTier.name`, e.g. `Google AI Pro`) and the email from userinfo, cached in `antigravity-account.json` per account fingerprint so switching accounts in agy is picked up.
- **Cache TTL**: the merged limits are cached for 60 seconds (`CACHE_TTL_SECONDS`), doubled for `--limits-only`.
- **Fallback endpoint headers**:
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
  - Right-clicking the bar button executes `omarchy-agent --pick`, which always invokes the user's current default agent. Omarchy's stock launcher has no `antigravity` entry, so the plugin installs `~/.local/bin/omarchy-agent` (on 4.0 and 4.5 alike) (ahead of `/usr/bin` on `PATH`): for the `antigravity` default it runs `omarchy-launch-tui --app-id=org.omarchy.agent agy` (or `agy` with `--inline`, `agy -i <prompt>` with `--prompt`), with no permission bypass; for any other default it `exec`s `${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-agent` with the arguments untouched. Omarchy 4.5 (`quattro`, omacom/omarchy#6900) adds Antigravity natively under the id `agy`: the panel maps `agy` to the Antigravity provider, and the launcher fills in for `agy` only while the stock launcher has no `agy)` entry, so on 4.5 Omarchy's own behaviour (`agy --dangerously-skip-permissions`) applies.
  - **Omarchy 4.5 native mode** (detected by `${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-agent-usage-agy`): 4.5's updater only runs collectors from `$OMARCHY_PATH/bin`, and its panel runs `omarchy-agent-usage-update` through `PATH`, so the plugin's collector would add a second tab and its updater would shadow 4.5's (losing features such as account auto-switching). `install.sh` then installs `omarchy-antigravity`, the status line and the `omarchy-agent` launcher, skips the provider switch and the panel copy, and runs `omarchy-antigravity adopt-native`. That command (also run once by the post-update hook when 4.5 arrives, recorded in `~/.config/omarchy/antigravity.native-adopted`, with a desktop notification) removes `omarchy-agent-usage-antigravity`, the `antigravity.json` record and the marked `omarchy-agent-usage-update` (edited copies go to the backup folder; a pre-install helper backup is left for uninstall), and switches only the `<user>.agents` widget holding the plugin's panel (`authActionBtn`) back to `omarchy.agents` with its settings (or drops it if the bar already has Omarchy's widget), taking one `shell.json` backup. It never changes the default agent or removes the launcher: 4.5's own `agy` default launches with `--dangerously-skip-permissions`, so moving the user there is their call. It is idempotent and a no-op without native support. Covered by `tests/test_native_mode.sh`.
  - **Install manifest and backups**: `install.sh` records the SHA-256 of every file it installs in `~/.config/omarchy/antigravity.installed`; `keep_if_edited` copies a plugin file edited since install (or, without a record, one that differs from the shipped copy) to `~/.local/share/omarchy-antigravity/backups/` before a reinstall, uninstall or 4.5 hand-over replaces or removes it. `backup_file` never overwrites a same-second backup.
  - **Default-agent ownership**: the plugin touches `~/.config/omarchy/antigravity.default` right after writing the default agent; the default is the plugin's only while the agent file is not newer than that marker and holds `antigravity` (or a legacy `gemini`). Anything else is the user's and is never overwritten or reverted.
  - `omarchy default agent` only accepts Omarchy's built-in agents; `omarchy-antigravity default` sets `antigravity` (with a backup and the `antigravity.default` opt-in marker). `gemini` means Omarchy's Gemini CLI: a `gemini` default with the opt-in marker is a leftover from releases that shipped a `gemini` shim to agy, and install and the post-update hook move it to `antigravity`.
  - In the panel tab strip, users can still click or middle-click to browse any other enabled provider tabs.

### 5.4. Multi-Provider Runner & Refresh Cadence
- **Multi-Collector Runner (`omarchy-agent-usage-update`)**:
  - Scans both `/usr/share/omarchy/bin/omarchy-agent-usage-*` and `~/.local/bin/omarchy-agent-usage-*` to execute all available collectors.
  - Supports `--limits-only` (rapid quota polling), `--force` (cache bypass), and `--except <id>` (skip providers disabled in `shell.json`).
  - Writes atomically to `${XDG_STATE_HOME:-~/.local/state}/omarchy/agents/usage/<id>.json` using temporary files and `jq` validation before replacement. Exit 0 with no output is a deliberate skip that keeps the previous record.
  - Runs collectors in parallel from `${OMARCHY_PATH:-/usr/share/omarchy}/bin` and `~/.local/bin` (local wins), each under `timeout 60` and a non-blocking per-collector `flock` (`.<id>.lock`), so overlapping refreshes skip a collector that is still running.
  - Only plain lowercase ids (`^[a-z0-9][a-z0-9-]*$`) not starting with `update` are run, and an `OMARCHY_AGENT_USAGE_UPDATE_ACTIVE` guard turns nested invocations into no-ops: a stray copy of the updater can never recurse.
  - Forwards each collector's stderr as `<id>: ...` (control characters stripped, 50 lines max) and exits non-zero when a collector fails, times out, or prints invalid JSON.
  - Keep the `# omarchy-antigravity: agent-usage-update` marker line (and the status line's `# omarchy-antigravity: statusline`, and the launcher's `# omarchy-antigravity: agent-launcher`) verbatim: install and uninstall use it to tell the plugin's copy from the user's.
- **Refresh Intervals**:
  - `ui/Main.qml` runs the full refresh of every collector every `refreshIntervalSec` (default 900, matching stock Omarchy) and a limits-only refresh of Antigravity every `limitsRefreshIntervalSec` (default 120, minimum 60); both are set in `shell.json`. Opening the panel also refreshes limits.
  - An optional systemd user timer (`omarchy-agent-usage.timer`, not installed by `install.sh`) may also run `omarchy-agent-usage-update --limits-only`; the updater's per-collector locks keep overlapping runs from colliding.
- **Session-Aware Inactivity Suspension**:
  - The collector checks `pgrep -x agy` before polling remote Google endpoints. If no active Antigravity session is found in the OS process table and a local state file already exists, it cleanly exits with code 0 without stdout output.
  - This prevents unnecessary network bandwidth, quota polling, and disk writes when the agent is idle.
  - Manual refreshes (`--force`) bypass this check to provide on-demand sync anytime.

---

## 6. Testing & Validation Checklist

The project includes an automated test suite with 100% functional test coverage. Always run the test suite before submitting pull requests or committing changes.

### Automated Test Suite:
```bash
# Run all 8 test suites
./tests/run_tests.sh
```

The test runner executes:
1. **Collector Unit & Integration Tests** (`tests/test_collector.py`):
   - Quota parsing and fraction conversion (`remainingFraction` -> `percent used`) plus the shared bucket classifier used by both quota sources.
   - Priority sorting (Gemini 5h -> Gemini Weekly -> Claude/GPT 5h -> Claude/GPT Weekly).
   - System keyring extraction and error handling (empty keyring, corrupt JSON, oversized output).
   - OAuth2 token auto-refresh, expiration checking, strict-client mode, and redirect refusal.
   - Bounded HTTP reads (success, oversized, `HTTPError`, invalid JSON) and descriptor/symlink hardening for token, cache, and history files.
   - Trusted helper resolution (world-writable/WRONG-OWNER/non-executable rejection).
   - Local stats aggregation (`history.jsonl` prompts parsing, date mapping, capped brain-session counting).
   - Edge cases: CLI not installed in trusted PATH, unauthenticated state, API network errors, and stale cache handling.
2. **Plugin Manifest Validation** (`tests/test_manifest.sh`):
   - Validates `manifest.json` against Omarchy's official `omarchy-plugin-validate` registry schema.
3. **Installer & Uninstaller Lifecycle** (`tests/test_installer.sh`):
   - Executes `install.sh` and `uninstall.sh` in an isolated sandbox environment.
   - Verifies all plugin-specific binaries are copied with `+x` permissions to `~/.local/bin`.
   - Verifies user UI edits, the shadowed update helper, and the status line are backed up and restored, and that `defaults/agent`/`shell.json` are set correctly.
   - Verifies `uninstall.sh` removes binaries, cache, state, and restores system defaults.
4. **Installer Symlink Safety** (`tests/test_installer_safety.sh`):
   - Proves `install.sh` refuses to write through an existing symlink and never truncates the linked victim file.
5. **Post-Update Hook Persistence** (`tests/test_hook.sh`):
   - Simulates `omarchy update` having modified user defaults.
   - Verifies restoration of consented settings without creating conflicting shims, and that an explicit `enabled = false` is respected.
6. **CLI Functional Commands** (`tests/test_cli.sh`):
   - Verifies `omarchy-antigravity help`, `status`, and invalid command handling, plus bash syntax for the `bin/` scripts.
7. **Antigravity CLI Status Bar Tests** (`tests/test_statusline.sh`):
   - Verifies status line syntax, stdin payload handling, and the `statusline` subcommands.
8. **CI & Static Gates** (`tests/test_ci.sh`):
   - Asserts the workflow keeps least-privilege permissions, a job timeout, concurrency, and full-SHA action pinning, and syntax-checks every shipped shell/Python file.

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
Every push and pull request to `main` automatically triggers `.github/workflows/test.yml` to ensure continuous regression protection. The job is pinned to immutable action SHAs, runs with `permissions: contents: read`, and has a 20-minute timeout plus cancel-in-progress concurrency.

### Staying in Sync with Upstream `omarchy.agents`

`ui/Main.qml` and `ui/Panel.qml` are vendored copies of the official Omarchy `omarchy.agents` plugin with a small set of plugin-specific changes. To avoid missing upstream fixes, periodically diff them against the packaged copy and reconcile:

```bash
diff -u /usr/share/omarchy/shell/plugins/agents/Main.qml  ui/Main.qml
diff -u /usr/share/omarchy/shell/plugins/agents/Panel.qml ui/Panel.qml
```

Local (intentional) changes to preserve when reconciling:
- `Main.qml`: dynamic default-agent sync, retry handling, `expandPath` rejecting `..`, and null-prototype maps in `aggregateSnapshots`/`localSnapshot` (prototype-pollution defense).
- `Panel.qml`: default-agent watcher and the antigravity-only Sign-In button.

Wherever possible, offer the generic security fixes (null-prototype maps, `..` rejection) upstream to Omarchy so future vendored copies inherit them.

---

## 7. Observability, Caching & Packaging

### Observability
Diagnostics are opt-in and always go to `stderr`, keeping `stdout` reserved for the JSON record:

```bash
# One-off verbose run
omarchy-agent-usage-antigravity --debug --force

# Persistent debug for a session
export OMARCHY_ANTIGRAVITY_DEBUG=1
```

`--debug` sets `OMARCHY_ANTIGRAVITY_DEBUG` for the process; `log_debug()` emits `[debug]` lines only when that variable is truthy, while `log_warn()` always emits operational warnings.

### History Cache
The local `history.jsonl` scan is cached in `~/.cache/omarchy/agent-usage/antigravity-history.json` (mode `0600`, atomic). The cache key is `(mtime_ns, size, local-date)`, so it is reused only while the file is unchanged and the day has not rolled over — the “today” counters can never be served from a stale day. Byte counts are validated through the same no-follow private reader as every other cache file.

### Packaging
`omarchy plugin add <git-url>` / `install.sh` are the supported install paths for this user-space plugin. An AUR package is intentionally not shipped: Arch packaging must not write into `$HOME`, and a correct package would need a maintainer decision on a `/usr/share` layout plus a post-install user-space step. Documenting this avoids shipping a packaging artifact that violates Arch guidelines.

### Deferred: QML runtime smoke test
`qmllint` cannot type-check the vendored QML on a plain CI runner because the `Quickshell`/`qs.*` import paths only exist on an installed Omarchy system. QML changes are therefore validated locally with `qmllint` (and by inspection); the CI gates cover syntax of all shipped shell/Python files instead.

---

## 8. Roadmap & Potential Improvements

- [ ] **Native Dedicated Bar Widget**:
  Add an alternative standalone widget (`bar-widget` in `manifest.json`) for users who want an isolated Antigravity icon with circular quota rings instead of grouping inside `omarchy.agents`.
- [ ] **Granular Model Usage Breakdowns**:
  Parse individual model session records if `agy` exports prompt/completion tokens per model into local logs.
- [ ] **Multi-Account Support**:
  Detect and support switching between multiple Google accounts stored in `google_accounts.json`.
- [ ] **Arch User Repository (AUR) Package**:
  Prepare a `PKGBUILD` for `omarchy-antigravity-git` for distribution via `yay` / `paru`.
