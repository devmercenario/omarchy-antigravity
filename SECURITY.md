# Security Policy

## Overview

The `omarchy-antigravity` plugin integrates the Google Antigravity CLI (`agy`) with Omarchy Linux.
Security and defense-in-depth are primary architectural priorities:

- **Strict User-Space Containment**: All plugin binaries, caches, and state files operate exclusively inside standard user directories (`~/.local/bin`, `~/.config/omarchy`, `~/.cache/omarchy`, `~/.local/state/omarchy`). No system files (`/etc`, `/usr`, `/root`) are modified or accessed.
- **Zero Elevated Privileges**: The plugin never invokes `sudo`, `su`, `pkexec`, or any privilege-escalation mechanism.
- **No Private Key Access**: The plugin has zero access to SSH keys (`~/.ssh`), GPG keys (`~/.gnupg`), or system keyrings outside its designated secret service domain (`service: gemini, username: antigravity`).
- **Standard Permission Model**: The plugin executes `agy` using its standard interactive permission confirmation model. No permission bypass flags (`--dangerously-skip-permissions`) are used or distributed.
- **Non-Conflicting Namespace**: Plugin-specific executables use explicit prefixes (`omarchy-antigravity*`). The one intentional exception is `omarchy-agent-usage-update`, which shadows the stock Omarchy helper of the same name on `PATH`; the installer backs up any prior copy and the uninstaller restores or removes it so the stock helper is never permanently masked.

---

## Credential & Data Protection Architecture

### 1. Descriptor-Level Token Verification (Anti-Symlink & TOCTOU Defense)
When reading authentication tokens from `~/.gemini/antigravity-cli/antigravity-oauth-token`:
- Opened with `os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC` to strictly prevent symlink traversal.
- File metadata is inspected directly on the open descriptor via `fstat(fd)`.
- Rejects non-regular files (`stat.S_ISREG`), UID mismatches (`st.st_uid != os.getuid()`), and permissive permissions (`(st.st_mode & 0o077) != 0`). Only owner-private files (`0600` or `0400`) are accepted.
- Enforces a strict 64 KiB size limit prior to in-memory decoding and JSON parsing.

### 2. Atomic & Private File Writing
All state, cache, and token files are created using atomic publish semantics:
- Temporary files are created in the target directory using `tempfile.mkstemp` with `O_CREAT | O_EXCL` and mode `0600`.
- Data is flushed and committed using `os.fsync(fd)` before closing the descriptor.
- Published via `os.replace`, ensuring atomic replacement on POSIX filesystems and safely replacing any existing symlinks without following them.

### 3. Native / Installed Application OAuth Model
In accordance with [RFC 8252 (OAuth 2.0 for Native Apps)](https://tools.ietf.org/html/rfc8252), desktop and installed CLI clients cannot protect client secrets:
- Google's OAuth 2.0 architecture treats native client secrets as non-confidential application identifiers.
- User authorization tokens (access/refresh tokens) are stored privately (`0600`) in user space or the system Secret Service keyring (`libsecret`).
- **agy's credentials are read-only to the plugin.** The collector reads `antigravity-oauth-token` (or the keyring entry) but never writes either back. When agy's own access token is stale, the collector mints one for itself and keeps it in its own `0600` cache (`~/.cache/omarchy/agent-usage/antigravity-access-token.json`, keyed by a SHA-256 fingerprint of the refresh token — the refresh token itself is never copied), so it can never race or corrupt the CLI's own token refresh.
- Client credentials can be overridden anytime via environment variables:
  - `ANTIGRAVITY_CLIENT_ID`
  - `ANTIGRAVITY_CLIENT_SECRET`
- **Strict mode (opt-in):** set `ANTIGRAVITY_STRICT_CLIENT=1` together with both variables to refuse token refresh whenever explicit credentials are absent. In strict mode the collector never falls back to the built-in default client and instead reports the requirement, so a deployment can avoid the embedded installed-application identifier entirely.

### 4. Network Security
- All remote API endpoints exclusively use TLS (`https://`).
- Every network request enforces strict socket timeouts (5s to 10s) to prevent denial-of-service hanging, and every request and helper is further cut to a 50-second budget for the whole run, so the collector always finishes inside the updater's `timeout 60` and reports a slow network instead of being killed. Authentication and other 4xx errors (except 408/429) are not retried.
- **Bounded response reads.** Every HTTP body — including `HTTPError` error bodies — is read through a single `read_bounded()` helper that checks `Content-Length` when present and never reads more than the endpoint ceiling plus one byte. This prevents a compromised or misbehaving endpoint from forcing unbounded allocation. Conservative per-endpoint ceilings are applied: 16 KiB for OAuth token refresh, 16 KiB for Google userinfo, 64 KiB for the plan lookup (`loadCodeAssist`), 256 KiB for the quota summary, and 4 KiB for error diagnostics.
- **Redirects refused.** A process-wide no-redirect opener rejects every HTTP redirect, so a credential-bearing request (OAuth client secret + refresh token, or a quota bearer token) can never be replayed to an attacker-chosen host.
- No third-party trackers, telemetry, or analytics are included.

### 5. Bounded Local JSON Reads
The collector's cache and state JSON files (`antigravity-limits.json`, `antigravity-agy-usage.json`, `antigravity-access-token.json`, `antigravity-account.json`, `antigravity-groups.json`, `antigravity-alert.json`, `antigravity-history.json`) are read through the same no-follow descriptor discipline used for the OAuth token, with a 1 MiB ceiling enforced before any decoding or JSON parsing. Credentials or caches holding valid JSON of the wrong shape are rejected instead of crashing the collector, and any unexpected error still produces a record (`Collector error`) so the panel never silently freezes on stale numbers. The CLI history file (`~/.gemini/antigravity-cli/history.jsonl`) is opened with `O_NOFOLLOW`, must be a regular file owned by the current user, and is ignored entirely above a 16 MiB ceiling before it is streamed.

### 6. Bounded Helper Output
Helper processes that feed credential or quota state (`secret-tool`, `agy -p /usage`, and `notify-send`) are executed with a hard timeout, and the first two with a 512 KiB stdout ceiling. A helper that exceeds either bound is terminated and treated as a failure, so it cannot force unbounded allocation or hang the collector. Helpers run in their own process group and the whole group is killed (also when the collector itself receives `SIGTERM`), so the MCP servers `agy` starts are never left orphaned. Desktop notification bodies are escaped, since notification daemons render them as Pango markup. The Antigravity status line additionally bounds stdin to 256 KiB, and the usage-update helper wraps every collector in `timeout 60` so one hung collector cannot stall a full refresh.

### 6b. Trusted Helper Resolution
In the Python collector, `agy`, `secret-tool`, `pgrep`, and `notify-send` are resolved to an absolute path and rejected when the binary is not an executable regular file, or when any ancestor directory in its path is world-writable or owned by neither root nor the current user. A poisoned `PATH` entry therefore cannot silently substitute an attacker-controlled helper. The shell scripts (installer, CLI helper, status line, updater) resolve `agy`, `jq`, `git`, and `secret-tool` through `PATH` like any other user command, so they trust the user's `PATH`. The status line additionally probes only loopback addresses, so a configured endpoint cannot be used to probe arbitrary hosts, and it treats the JSON agy sends on stdin as untrusted: the width must be a plain number before it reaches shell arithmetic, folder and branch names are stripped of control characters and printed with `%s` (no terminal escape injection), and `git status` runs with `GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=`, so it never writes `.git/index` (no `index.lock` races with the agent's own commits) and never runs a repository's fsmonitor hook.

### 7. Installation, Removal, and User Consent
The installer never overwrites user or stock files without a recoverable backup:
- `shell.json`, the agy `settings.json`, and the default-agent file get a timestamped backup only when a change is actually written, and only the 3 newest backups of each are kept. A pre-existing Antigravity CLI `statusline.sh` and `omarchy-agent-usage-update` are backed up once (single-slot `.bak`); the update-helper backup is a hidden dotfile (`.omarchy-agent-usage-update.bak`) so the collector-discovery glob can never mistake it for a collector.
- The plugin's own `statusline.sh` and `omarchy-agent-usage-update` carry a marker line (`# omarchy-antigravity: ...`). A reinstall never backs up the plugin's own copy as if it were the user's, so uninstalling can never "restore" the plugin copy and leave the stock helper masked.
- Config files are rewritten through a temporary file in the same directory (atomic `mv`, original mode kept), and only when the JSON content changes, so the bar's file watcher never sees a partial `shell.json` and an unchanged file keeps its inode and mtime.
- Plugin UI files (`Panel.qml`, `Main.qml`, and assets in the user's cloned agents plugin) are backed up before replacement.
- The installer refuses to write plugin binaries through an existing symlink, and copies use `--remove-destination` so symlinks are replaced rather than followed.
- The uninstaller only undoes what is recognizably the plugin's: it removes the status line and its `statusLine` entry only when the script carries the marker and the entry points at it (a user's own status line is left alone, and a user backup is restored with its entry kept); it removes `providers.antigravity` only when it is exactly `{"enabled": true}`; it removes the agents plugin folder only when the installer created it (marker file), through `omarchy-plugin-remove`; and it restores the shadowed update helper, agent selection, and UI files. It also deletes the collector's `~/.cache/omarchy/agent-usage/antigravity-*` caches, including its private access-token cache.
- The usage updater refuses to recurse (an environment guard, plus skipping any discovered id starting with `update` and any id that is not a plain lowercase name), runs collectors in parallel, takes a per-collector lock so overlapping refreshes (bar timers, a systemd timer, the plugin service) never run one collector twice, and reports collector failures on stderr with a non-zero exit instead of silently keeping stale records.
- The post-update hook only fills in a **missing** antigravity provider preference; an explicit `providers.antigravity.enabled = false` is left untouched, and the user's chosen default agent is never overwritten.

### 8. Shell Plugin Data Hardening
Data derived from synced snapshots is aggregated into null-prototype maps, so an untrusted key such as `__proto__` becomes an ordinary own property instead of mutating an object prototype in the Quickshell runtime. Synced snapshot values are coerced through `String()`/numeric helpers before use. Because the sync folder is shared and parsed on the GUI thread, the scan skips snapshots larger than 1 MiB, reads at most 64 of them, and merges at most 16 agents; paths and limits reach the scan script as argv, never interpolated into it. Commands the panel runs (`bar.run()`, `Process`) are constant strings or argv arrays and never include data read from records.

---

## Reporting a Vulnerability

If you discover a security vulnerability within this project, please report it responsibly:

1. Do **not** open a public issue.
2. Submit a report through GitHub Private Vulnerability Reporting on this repository.
3. Include detailed reproduction steps, affected environment, and impact assessment.

We appreciate your assistance in keeping the Omarchy ecosystem safe!
