#!/usr/bin/env bash
# Global Claude Code PreToolUse hook (matcher: Bash).
#
# Blocks `rm -rf` (and aliases) targeting the PR pipeline's state dirs or
# git worktree roots. Pipeline daemons legitimately need `rm -rf` only
# against `/tmp/orch-*` (worker worktree cleanup) — anything else is
# almost certainly a model error or scope-creep.
#
# Why this is separate from block-orchestrator-writes.sh:
# - block-orchestrator-writes is gated on CLAUDE_ROLE=orchestrator and
#   matches by COMMAND PATTERN (git commit, sed -i, etc.). It doesn't
#   inspect path arguments. And it doesn't fire in the reviewer window
#   (which has no CLAUDE_ROLE), so the reviewer could theoretically
#   `rm -rf` state dirs without anyone catching it.
# - This hook is path-aware and role-agnostic: ALL sessions are blocked
#   from destroying these specific paths, regardless of orchestrator/
#   reviewer/worker context.
#
# Bypass: PR_PIPELINE_RM_OK=1 (for legitimate manual cleanup).

set -uo pipefail

if [ "${PR_PIPELINE_RM_OK:-}" = "1" ]; then
    exit 0
fi

PAYLOAD=$(cat)
COMMAND=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""), end="")
except Exception:
    pass
' 2>/dev/null) || COMMAND=""

[ -z "$COMMAND" ] && exit 0

# Detect destructive `rm` patterns. We're conservative: any `rm` with -r/-R
# and -f anywhere in the flags counts. Also `rm -fr`, `rm -rf`, etc.
# `rmdir -p ...` is also dangerous on a populated dir but distinct.
is_destructive_rm() {
    local cmd="$1"
    # rm with both -r and -f flags (any combination, any order)
    if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_-])rm[[:space:]]+(-[rRfFv]*[rR][rRfFv]*[fF]|-[rRfFv]*[fF][rRfFv]*[rR]|-[rR][[:space:]]+-[fF]|-[fF][[:space:]]+-[rR]|--recursive[[:space:]]+--force|--force[[:space:]]+--recursive)'; then
        return 0
    fi
    return 1
}

# Detect dangerous PATH arguments. We block if `rm -rf` is invoked AND
# any argument matches one of these patterns.
# IMPORTANT: every "bare X / X-itself" pattern below uses
# ([[:space:]]|$) for the trailing boundary — NOT (/?|...). The latter
# alternation wrongly matched X-followed-by-anything (e.g., /tmp/foo
# was blocked because (/?|...) happily matched just the `/` of `/foo`,
# treating the whole /tmp/... as bare /tmp). Specific subpaths that we
# DO want to protect get their own explicit patterns below.
PROTECTED_PATTERNS=(
    # PR pipeline state — daemons share these and a wipe = lose all
    # review history, cron jobs, escalation flags, etc.
    'claude-pr-pipeline'

    # Bare $HOME / ~ / ~/ (would wipe entire home)
    '(^|[[:space:]])\$HOME([[:space:]]|$)'
    '(^|[[:space:]])\$HOME/([[:space:]]|$)'
    '(^|[[:space:]])~([[:space:]]|$)'
    '(^|[[:space:]])~/([[:space:]]|$)'

    # Specific Claude config / state dirs (tilde + $HOME forms; the
    # literal-home-path form `${HOME}/.claude` is also caught because
    # we expand $HOME below before matching).
    # Trailing ([[:space:]/]|$) lets us catch `~/.claude` AND `~/.claude/foo`.
    '~/\.claude([[:space:]/]|$)'
    '~/\.local/share/claude'
    '~/\.local/state/claude-pr-pipeline'
    '\$HOME/\.claude([[:space:]/]|$)'
    '\$HOME/\.local/share/claude'
    '\$HOME/\.local/state/claude-pr-pipeline'
    # And the literal-expanded-home form (covers `rm -rf $HOME/...` where
    # the shell has already substituted $HOME by the time we see the command).
    "${HOME}/\\.claude([[:space:]/]|$)"
    "${HOME}/\\.local/share/claude"
    "${HOME}/\\.local/state/claude-pr-pipeline"

    # Bare /tmp (not /tmp/anything)
    '(^|[[:space:]])/tmp([[:space:]]|$)'

    # Bare '.' or '/' as rm target (catastrophic)
    '(^|[[:space:]])\.[[:space:]]*(\||;|&|$)'
    '(^|[[:space:]])/[[:space:]]*(\||;|&|$)'
)

# Allowlist patterns — these are LEGITIMATE rm -rf targets.
# If a command's primary target matches one of these, we let it through
# even if a protected pattern coincidentally appears elsewhere.
ALLOWLIST_PATTERNS=(
    '/tmp/orch-[A-Za-z0-9_]+__[A-Za-z0-9_-]+-pr[0-9]+'   # worker worktree cleanup
    '/tmp/pr-review-tick-[0-9]+'                          # A's per-tick scratch
    '/tmp/pr-orch-tick-[0-9]+'                            # B's per-tick scratch
)

if ! is_destructive_rm "$COMMAND"; then
    exit 0
fi

# Found a destructive rm. Check if it's purely against allowlisted paths.
# Strategy: strip allowlisted paths from the command, then check if any
# protected pattern still appears in the remainder.
REMAINDER="$COMMAND"
for ok in "${ALLOWLIST_PATTERNS[@]}"; do
    REMAINDER=$(printf '%s' "$REMAINDER" | sed -E "s|$ok|<allowlisted>|g")
done

# If the original command was JUST `rm -rf <allowlisted>`, REMAINDER will
# now contain `<allowlisted>` instead of the path — protected patterns
# below shouldn't match. If the command also targets non-allowlist paths,
# they'll still be in REMAINDER and might match a protected pattern.
for proto in "${PROTECTED_PATTERNS[@]}"; do
    if printf '%s' "$REMAINDER" | grep -qE "$proto"; then
        cat >&2 <<EOF
Blocked: destructive 'rm -rf' against a protected path.

Command:    $COMMAND
Matched:    $proto

Protected paths (rm -rf forbidden):
  - ~/.local/state/claude-pr-pipeline/...   (PR pipeline state — daemons depend on it)
  - ~/.claude/                              (Claude Code config)
  - ~/.local/share/claude                   (Claude Code state)
  - /tmp itself (not a subpath)             (would wipe other tools' state)
  - bare '.' or '/'                         (catastrophic)

Allowlisted (rm -rf OK):
  - /tmp/orch-<repo-slug>-pr<N>             (worker worktree)
  - /tmp/pr-review-tick-<N>                 (A's per-tick scratch)
  - /tmp/pr-orch-tick-<N>                   (B's per-tick scratch)

If this is genuinely a one-off cleanup that needs to bypass: relaunch
the session with PR_PIPELINE_RM_OK=1 set, or run the rm manually
outside Claude.

(Hook source: ~/.claude/hooks/protect-state-from-rm.sh.)
EOF
        exit 2
    fi
done

exit 0
