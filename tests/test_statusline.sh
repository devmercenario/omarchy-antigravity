#!/bin/bash
# ==============================================================================
# Functional & Unit Tests: Antigravity CLI Statusline
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATUSLINE="$PROJECT_ROOT/bin/omarchy-antigravity-statusline"
CLI="$PROJECT_ROOT/bin/omarchy-antigravity"

# Isolated HOME (theme colours, RTK/shunt-local probes) and no inherited width.
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-test-statusline.XXXXXX")
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
unset COLUMNS OMARCHY_STATUSLINE_DEBUG

fail() {
  echo "❌ Assertion failed: $*" >&2
  exit 1
}

strip_ansi() {
  sed "s/\x1b\[[0-9;]*[a-zA-Z]//g"
}

echo "🧪 Running statusline tests..."

# 1. Verify statusline script is executable and passes syntax check
echo "  ▶ Testing statusline syntax..."
bash -n "$STATUSLINE"
grep -qx '# omarchy-antigravity: statusline' "$STATUSLINE" \
  || fail "statusline lost the marker line install/uninstall rely on."

# 2. Test statusline direct invocation
echo "  ▶ Testing direct execution..."
out=$("$STATUSLINE" </dev/null)
if ! echo "$out" | grep -q "AGY"; then
  fail "statusline did not output AGY header."
fi

# 3. Test JSON input via stdin
echo "  ▶ Testing statusline with JSON payload via stdin..."
mock_json='{"cwd":"/tmp","terminal_width":90,"model":{"id":"gemini-test","display_name":"Gemini Pro"}}'
out_json=$(echo "$mock_json" | "$STATUSLINE")
if ! echo "$out_json" | grep -q "tmp"; then
  fail "statusline did not use cwd from JSON input."
fi

# 4. Test clock trailing spacing (must have single trailing space after time for symmetry)
echo "  ▶ Testing clock trailing spacing..."
clean_out=$(printf "%s" "$out" | strip_ansi)
if [[ ! "$clean_out" =~ [0-9]{2}:[0-9]{2}[[:space:]]$ ]]; then
  fail "statusline must end with single space after clock. Got: '${clean_out}'"
fi

# 5. The line fills exactly the requested width (padding computed from the
# visible text, separators and icons included).
echo "  ▶ Testing width padding..."
for width in 90 120; do
  line=$(printf '{"cwd":"/tmp","width":%d}' "$width" | "$STATUSLINE" | strip_ansi)
  [[ ${#line} -eq $width ]] || fail "rendered ${#line} columns for width $width."
done

# 6. WIDTH from agy's JSON or COLUMNS reaches arithmetic; a crafted value
# must be ignored, never evaluated.
echo "  ▶ Testing that a crafted width is inert..."
SENTINEL="$TEST_HOME/width-pwned"
payload="a[\$(touch $SENTINEL)]"
jq -nc --arg w "$payload" '{cwd:"/tmp", width:$w}' | "$STATUSLINE" >/dev/null 2>&1 || true
echo '{"cwd":"/tmp"}' | COLUMNS="$payload" "$STATUSLINE" >/dev/null 2>&1 || true
COLUMNS="$payload" "$STATUSLINE" </dev/null >/dev/null 2>&1 || true
[[ ! -e "$SENTINEL" ]] || fail "a crafted width executed a command."
line=$(jq -nc --arg w "$payload" '{cwd:"/tmp", width:$w}' | COLUMNS=100 "$STATUSLINE" | strip_ansi)
[[ ${#line} -eq 100 ]] || fail "invalid JSON width did not fall back to COLUMNS (got ${#line} columns)."

# 7. Folder (and branch) names are printed literally with control characters
# and backslashes removed, so a crafted directory cannot drive the terminal.
echo "  ▶ Testing that control characters in the folder name are stripped..."
evil_dir="$TEST_HOME/evil"$'\e]0;owned\a\e[2J'"name\\c%s"
mkdir -p "$evil_dir"
raw=$(jq -nc --arg d "$evil_dir" '{cwd:$d, width:100}' | "$STATUSLINE")
visible=$(printf '%s' "$raw" | strip_ansi)
[[ "$visible" != *$'\e'* && "$visible" != *$'\a'* ]] || fail "control characters from the folder name reached the terminal."
[[ "$visible" == *"evil]0;owned[2Jnamec%s"* ]] || fail "folder name was not printed literally: $visible"

# 8. Git status: counts match the working tree, and rendering never writes
# the repository's index (GIT_OPTIONAL_LOCKS=0).
echo "  ▶ Testing git branch, change counts and that .git/index is not written..."
repo="$TEST_HOME/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'a\n' > "$repo/tracked"
printf 's\n' > "$repo/same"
git -C "$repo" add tracked same
git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m tracked
clean=$(jq -nc --arg d "$repo" '{cwd:$d, width:100}' | "$STATUSLINE" | strip_ansi)
[[ "$clean" == *" main "* ]] || fail "branch name missing: $clean"
[[ "$clean" != *"?"[0-9]* && "$clean" != *"+"[0-9]* && "$clean" != *"~"[0-9]* ]] \
  || fail "a clean repository must show no change counts: $clean"
printf 'b\n' >> "$repo/tracked"
printf 'n\n' > "$repo/staged"; git -C "$repo" add staged
printf 'u\n' > "$repo/untracked1"; printf 'u\n' > "$repo/untracked2"
before=$(stat -c '%Y.%y' "$repo/.git/index")
# Same content, new mtime: a plain `git status` would refresh the stat data
# and rewrite the index.
touch -d '2001-01-01' "$repo/same"
dirty=$(jq -nc --arg d "$repo" '{cwd:$d, width:100}' | "$STATUSLINE" | strip_ansi)
[[ "$dirty" == *"repo +1 ~1 ?2"* ]] || fail "wrong change counts: $dirty"
[[ "$(stat -c '%Y.%y' "$repo/.git/index")" == "$before" ]] || fail "rendering rewrote .git/index."
git -C "$repo" checkout -q --detach HEAD 2>/dev/null
detached=$(jq -nc --arg d "$repo" '{cwd:$d, width:100}' | "$STATUSLINE" | strip_ansi)
short=$(git -C "$repo" rev-parse HEAD); short=${short:0:7}
[[ "$detached" == *" $short "* ]] || fail "detached HEAD did not show the short commit: $detached"
nogit=$(jq -nc --arg d "$TEST_HOME" '{cwd:$d, width:100}' | "$STATUSLINE" | strip_ansi)
[[ "$nogit" == *"no-git"* && "$nogit" != *"?"[0-9]* ]] || fail "non-repository rendering is wrong: $nogit"

# 9. Test CLI helper statusline subcommands
echo "  ▶ Testing omarchy-antigravity statusline subcommands..."
cli_status=$("$CLI" statusline status)
if ! echo "$cli_status" | grep -q "Antigravity CLI Status Bar"; then
  fail "omarchy-antigravity statusline status failed."
fi

# `disable` must not invent a partial statusLine entry when there is none.
mkdir -p "$HOME/.gemini/antigravity-cli"
echo '{"theme":"dark"}' > "$HOME/.gemini/antigravity-cli/settings.json"
"$CLI" statusline disable >/dev/null
jq -e 'has("statusLine") | not' "$HOME/.gemini/antigravity-cli/settings.json" >/dev/null \
  || fail "statusline disable created a statusLine entry."

# A repository's own clean filter must never run because the status line
# rendered inside it (an untrusted checkout would otherwise run its commands
# through `git status`), and the branch must still show.
echo "  ▶ Testing that a repository's own filter commands never run..."
evil="$TEST_HOME/evil-repo"
git init -q -b main "$evil"
printf 'data\n' > "$evil/f.txt"
printf '* filter=x\n' > "$evil/.gitattributes"
git -C "$evil" add -A
git -C "$evil" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$evil" config filter.x.clean "sh -c 'touch $TEST_HOME/FILTER_RAN; cat'"
touch -d '2 minutes ago' "$evil/f.txt"
rm -f "$TEST_HOME/FILTER_RAN"
evil_out=$(echo "{\"cwd\": \"$evil\", \"width\": 100}" | bash "$STATUSLINE" | strip_ansi)
[[ ! -e "$TEST_HOME/FILTER_RAN" ]] || fail "rendering ran the repository's clean filter."
[[ "$evil_out" == *" main "* ]] || fail "the branch was not shown for a repository with its own filters: $evil_out"

echo "  ✅ All statusline assertions passed!"
echo "🎉 Statusline tests passed successfully!"
