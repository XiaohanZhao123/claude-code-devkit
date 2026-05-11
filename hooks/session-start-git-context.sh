#!/usr/bin/env bash
# Global Claude Code SessionStart hook.
#
# On session startup / resume / compact, prints a concise git status block
# to stdout, which Claude Code injects into the model's context. Saves the
# model from running `git status` / `git log` / `git worktree list` itself
# at the start of every turn.
#
# Output is best-effort: silently exits 0 if cwd is not a git repo or git
# is unavailable. Never blocks (SessionStart can't anyway).

set -uo pipefail

# CLAUDE_PROJECT_DIR is set by Claude Code; fall back to cwd otherwise.
DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Bail silently if not a git repo.
if ! git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

echo "## Git context"
echo ""
echo "(injected by ~/.claude/hooks/session-start-git-context.sh — current state of the repo at session start)"
echo ""
echo "Repo: $DIR"

BRANCH=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
echo "Branch: $BRANCH"

# Upstream + ahead/behind, if upstream is configured.
UPSTREAM=$(git -C "$DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
if [ -n "$UPSTREAM" ]; then
    AB=$(git -C "$DIR" rev-list --left-right --count "$UPSTREAM"...HEAD 2>/dev/null || true)
    if [ -n "$AB" ]; then
        BEHIND=$(echo "$AB" | awk '{print $1}')
        AHEAD=$(echo "$AB" | awk '{print $2}')
        echo "Tracking: $UPSTREAM (ahead $AHEAD, behind $BEHIND)"
    fi
fi
echo ""

echo "Recent commits:"
git -C "$DIR" log --oneline -5 2>/dev/null | sed 's/^/  /' || echo "  (no commits)"
echo ""

# Working tree status — only show if dirty.
STATUS=$(git -C "$DIR" status --short 2>/dev/null || true)
if [ -n "$STATUS" ]; then
    LINE_COUNT=$(printf '%s\n' "$STATUS" | wc -l | tr -d ' ')
    echo "Uncommitted changes ($LINE_COUNT files):"
    printf '%s\n' "$STATUS" | head -20 | sed 's/^/  /'
    if [ "$LINE_COUNT" -gt 20 ]; then
        echo "  ... and $((LINE_COUNT - 20)) more"
    fi
    echo ""
else
    echo "Working tree: clean"
    echo ""
fi

# Worktrees — only show if there are multiple.
WT=$(git -C "$DIR" worktree list 2>/dev/null || true)
if [ -n "$WT" ]; then
    WT_COUNT=$(printf '%s\n' "$WT" | wc -l | tr -d ' ')
    if [ "$WT_COUNT" -gt 1 ]; then
        echo "Worktrees:"
        printf '%s\n' "$WT" | sed 's/^/  /'
        echo ""
    fi
fi

exit 0
