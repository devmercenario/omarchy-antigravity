#!/bin/bash
# ==============================================================================
# Safety Test: install.sh must never write through an existing symlink
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🧪 Running installer symlink-safety tests..."

TEST_HOME=$(mktemp -d "/tmp/omarchy-test-symlink.XXXXXX")
cleanup() {
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

export HOME="$TEST_HOME"
export XDG_STATE_HOME="$TEST_HOME/.local/state"
export XDG_CACHE_HOME="$TEST_HOME/.cache"
export XDG_CONFIG_HOME="$TEST_HOME/.config"
export PATH="$TEST_HOME/.local/bin:$PATH"

mkdir -p "$TEST_HOME/.local/bin" "$TEST_HOME/.config/omarchy"

# Mock dependencies so install.sh runs offline (empty keyring -> no network).
printf '#!/bin/bash\nexit 0\n' > "$TEST_HOME/.local/bin/secret-tool"
chmod +x "$TEST_HOME/.local/bin/secret-tool"
printf '#!/bin/bash\necho agy\n' > "$TEST_HOME/.local/bin/agy"
chmod +x "$TEST_HOME/.local/bin/agy"

# A victim file plus a symlink sitting exactly where the installer wants to
# place a binary. A careless `cp -f` would follow the link and truncate the
# victim; the installer must instead refuse.
VICTIM="$TEST_HOME/victim.txt"
echo "victim-content" > "$VICTIM"
TARGET="$TEST_HOME/.local/bin/omarchy-antigravity"
ln -s "$VICTIM" "$TARGET"

"$PROJECT_ROOT/install.sh" --no-default --no-statusline >/dev/null 2>&1 || true

if [[ "$(cat "$VICTIM")" != "victim-content" ]]; then
  echo "❌ Assertion failed: installer followed a symlink and overwrote the victim file." >&2
  exit 1
fi
if [[ ! -L "$TARGET" ]]; then
  echo "❌ Assertion failed: installer replaced a symlink instead of skipping it." >&2
  exit 1
fi
for bin in omarchy-antigravity-statusline omarchy-agent-usage-update; do
  if [[ ! -x "$TEST_HOME/.local/bin/$bin" ]]; then
    echo "❌ Assertion failed: $bin was not installed alongside the skipped symlink." >&2
    exit 1
  fi
done

echo "  ✅ install.sh refused to follow the symlink and preserved the victim file."
echo "🎉 Installer symlink-safety tests passed successfully!"
