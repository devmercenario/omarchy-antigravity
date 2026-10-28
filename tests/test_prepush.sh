#!/bin/bash
# ==============================================================================
# Integration Test: .githooks/pre-push
#
# The hook must run the preflight against each pushed commit (in a temporary
# worktree), not against the working tree: an uncommitted file can neither
# fail nor rescue a push. Deletions are skipped and the worktree is removed.
# Uses a throwaway repository with a fake preflight, so it never runs the
# real suite recursively.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_ROOT/.githooks/pre-push"

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-test-prepush.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export TMPDIR="$TEST_DIR"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

fail() {
  echo "❌ Assertion failed: $*" >&2
  exit 1
}

echo "🧪 Running pre-push hook tests..."

REPO="$TEST_DIR/repo"
LOG="$TEST_DIR/preflight.log"
ZERO=0000000000000000000000000000000000000000
git init -q -b main "$REPO"
mkdir -p "$REPO/tests" "$REPO/.githooks"
cp "$HOOK" "$REPO/.githooks/pre-push"
# Fake preflight: records the commit and directory it ran in, and fails when
# the tree it runs in contains a file named FAIL.
cat > "$REPO/tests/preflight.sh" <<EOF
#!/bin/bash
cd "\$(dirname "\${BASH_SOURCE[0]}")/.."
echo "\$(git rev-parse HEAD) \$PWD" >> "$LOG"
[[ ! -e FAIL ]]
EOF
commit() {
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "$1"
  git -C "$REPO" rev-parse HEAD
}
push() {
  (cd "$REPO" && printf '%s\n' "$@" | ./.githooks/pre-push origin https://example.invalid/repo.git)
}

good=$(commit good)

echo "  ▶ The pushed commit is tested, not the dirty working tree..."
echo "uncommitted" > "$REPO/FAIL"
push "refs/heads/main $good refs/heads/main $ZERO" >/dev/null 2>&1 \
  || fail "an untracked file in the working tree failed the push."
read -r ran_sha ran_dir < "$LOG"
[[ "$ran_sha" == "$good" ]] || fail "preflight ran on $ran_sha instead of the pushed $good."
[[ "$ran_dir" != "$REPO" ]] || fail "preflight ran in the working tree instead of a temporary worktree."
[[ ! -e "$ran_dir" ]] || fail "temporary worktree was not removed."

echo "  ▶ A failing pushed commit blocks the push even from a clean tree..."
bad=$(commit bad)
git -C "$REPO" rm -q FAIL
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m fixed-later
if push "refs/heads/main $bad refs/heads/main $good" >/dev/null 2>&1; then
  fail "a pushed commit whose preflight fails did not block the push."
fi

echo "  ▶ Deletions are skipped and git's hook environment is ignored..."
: > "$LOG"
push "(delete) $ZERO refs/heads/old $good" >/dev/null 2>&1 || fail "a branch deletion failed the push."
[[ ! -s "$LOG" ]] || fail "preflight ran for a branch deletion."
(cd "$REPO" && printf 'refs/heads/main %s refs/heads/main %s\n' "$good" "$ZERO" |
  GIT_DIR="$REPO/.git" ./.githooks/pre-push origin x >/dev/null 2>&1) || fail "push failed with GIT_DIR exported."
read -r ran_sha _ < "$LOG"
[[ "$ran_sha" == "$good" ]] || fail "with GIT_DIR exported, preflight saw $ran_sha instead of $good."

[[ "$(git -C "$REPO" worktree list | wc -l)" -eq 1 ]] || fail "temporary worktrees are still registered."

echo "  ✅ pre-push hook passed all assertions!"
echo "🎉 Pre-push hook tests passed successfully!"
