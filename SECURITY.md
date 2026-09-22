# Security Policy

## Overview

The `omarchy-antigravity` plugin integrates the Google Antigravity CLI (`agy`) with Omarchy Linux.
Security and defense-in-depth are primary architectural priorities:

- **Strict User-Space Containment**: All plugin binaries, caches, and state files operate exclusively inside standard user directories (`~/.local/bin`, `~/.config/omarchy`, `~/.cache/omarchy`, `~/.local/state/omarchy`). No system files (`/etc`, `/usr`, `/root`) are modified or accessed.
- **Zero Elevated Privileges**: The plugin never invokes `sudo`, `su`, `pkexec`, or any privilege-escalation mechanism.
- **No Private Key Access**: The plugin has zero access to SSH keys (`~/.ssh`), GPG keys (`~/.gnupg`), or system keyrings outside its designated secret service domain (`service: gemini, username: antigravity`).
- **Standard Permission Model**: The plugin executes `agy` using its standard interactive permission confirmation model. No permission bypass flags (`--dangerously-skip-permissions`) are used or distributed.
- **Non-Conflicting Namespace**: All installed executables use explicit plugin-scoped prefixes (`omarchy-antigravity*`, `omarchy-agent-usage-*`) to prevent shadowing standard system binaries.

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
- Client credentials can be overridden anytime via environment variables:
  - `ANTIGRAVITY_CLIENT_ID`
  - `ANTIGRAVITY_CLIENT_SECRET`

### 4. Network Security
- All remote API endpoints exclusively use TLS (`https://`).
- Every network request enforces strict socket timeouts (5s to 10s) to prevent denial-of-service hanging.
- **Bounded response reads.** Every HTTP body — including `HTTPError` error bodies — is read through a single `read_bounded()` helper that checks `Content-Length` when present and never reads more than the endpoint ceiling plus one byte. This prevents a compromised or misbehaving endpoint from forcing unbounded allocation. Conservative per-endpoint ceilings are applied: 16 KiB for OAuth token refresh, 16 KiB for Google userinfo, 256 KiB for the quota summary, and 4 KiB for error diagnostics.
- No third-party trackers, telemetry, or analytics are included.

### 5. Bounded Local JSON Reads
Cache and account JSON files (`antigravity-limits.json`, `antigravity-user.json`, and `~/.gemini/google_accounts.json`) are read through the same no-follow descriptor discipline used for the OAuth token, with a 1 MiB ceiling enforced before any decoding or JSON parsing. The CLI history file (`~/.gemini/antigravity-cli/history.jsonl`) is opened with `O_NOFOLLOW`, must be a regular file owned by the current user, and is ignored entirely above a 16 MiB ceiling before it is streamed.

### 6. Bounded Helper Output
Helper processes that feed credential or quota state (`secret-tool` and `agy -p /usage`) are executed with a 512 KiB stdout ceiling and a hard timeout. A helper that exceeds either bound is terminated and treated as a failure, so it cannot force unbounded allocation or hang the collector.

---

## Reporting a Vulnerability

If you discover a security vulnerability within this project, please report it responsibly:

1. Do **not** open a public issue.
2. Submit a report through GitHub Private Vulnerability Reporting on this repository.
3. Include detailed reproduction steps, affected environment, and impact assessment.

We appreciate your assistance in keeping the Omarchy ecosystem safe!
