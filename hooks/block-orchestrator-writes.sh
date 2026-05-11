#!/usr/bin/env bash
# Global Claude Code PreToolUse hook (matcher: Edit|Write|Bash).
#
# Enforces the orchestrator role's read-only contract.
#
# When CLAUDE_ROLE=orchestrator, blocks ALL code-mutating actions:
#   - Edit / Write / NotebookEdit tools                      (file mutation)
#   - Bash patterns: git commit/add/push/rebase/merge/...    (vcs mutation)
#   - Bash patterns: sed -i, perl -i                         (in-place edits)
#
# Rationale: the pr-orch-tick orchestrator (Agent B) coordinates fix
# workers and posts verdicts; only workers (sub-agents spawned via
# `Agent`) are allowed to write code. Even when the orchestrator's
# prompt explicitly forbids writes, LLMs sometimes attempt them. This
# hook is the deterministic enforcement layer.
#
# When CLAUDE_ROLE is unset or != "orchestrator", this hook is a no-op,
# so it's safe to register globally.
#
# CRITICAL: sub-agents spawned by the orchestrator (via the Agent tool)
# inherit CLAUDE_ROLE from the parent process, but those sub-agents are
# the ones that LEGITIMATELY write code (workers triage findings + apply
# fixes + push). If we block them, the whole pipeline halts — the
# orchestrator gets stuck in escalation because no worker can land its
# diff. This was a real bug observed on PR #15 of top_conference_copier
#.
#
# Fix: differentiate top-level orchestrator calls from sub-agent calls
# via the PreToolUse payload's `agent_id` field. Per Claude Code hook
# docs: "Additional fields when running with --agent or in subagent:
# agent_id, agent_type". Top-level Claude payloads do NOT have these
# fields. So: presence of `agent_id` in payload == we're inside a
# sub-agent's tool call == the worker is writing code, which is allowed.
#
# Override (one-off, e.g., debugging the daemon itself): ORCHESTRATOR_WRITES_OK=1.

set -uo pipefail

# Only enforce in orchestrator role.
if [ "${CLAUDE_ROLE:-}" != "orchestrator" ]; then
    exit 0
fi

# Operator-level bypass.
if [ "${ORCHESTRATOR_WRITES_OK:-}" = "1" ]; then
    exit 0
fi

PAYLOAD=$(cat)

# Sub-agent bypass: if PreToolUse payload has agent_id, this call is
# coming from a sub-agent (e.g., the fix worker spawned via Agent tool).
# Sub-agents are explicitly the ones allowed to write code; the hook only
# protects the top-level orchestrator from writing.
AGENT_ID=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("agent_id", ""), end="")
except Exception:
    pass
' 2>/dev/null) || AGENT_ID=""

if [ -n "$AGENT_ID" ]; then
    # Sub-agent context — let writes through.
    exit 0
fi

TOOL_NAME=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_name", ""), end="")
except Exception:
    pass
' 2>/dev/null) || TOOL_NAME=""

# ============================================================
# Block file-mutation tools entirely.
# ============================================================
case "$TOOL_NAME" in
    Edit|Write|NotebookEdit)
        cat >&2 <<EOF
Blocked: orchestrator role (CLAUDE_ROLE=orchestrator) is forbidden from
modifying files. Tool: $TOOL_NAME.

The orchestrator coordinates fix workers and posts verdicts; only
workers (sub-agents) write code.

If you need to fix code: spawn a worker via
    Agent(subagent_type="general-purpose", prompt=...).
The worker has Edit/Write/Bash and is responsible for all code changes.

If you need to write orchestrator state metadata
(~/.local/state/claude-pr-pipeline/...): use Bash redirections
(echo X > file, jq ... >> file), not Edit/Write tool calls.

(This block comes from ~/.claude/hooks/block-orchestrator-writes.sh.
To bypass for one legitimate case, relaunch with
ORCHESTRATOR_WRITES_OK=1 in env.)
EOF
        exit 2
        ;;
esac

# ============================================================
# Block code-mutating Bash patterns.
# ============================================================
if [ "$TOOL_NAME" = "Bash" ]; then
    COMMAND=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""), end="")
except Exception:
    pass
' 2>/dev/null) || COMMAND=""

    if [ -z "$COMMAND" ]; then
        exit 0
    fi

    # Each entry: "human-name|extended-regex".
    # Leading boundary `(^|[^[:alnum:]_-])` ensures we don't match
    # substrings like "ungitcommit". `gh pr merge` is allowed because
    # it starts with `gh`, not `git`, so the `git merge` pattern
    # doesn't match it.
    declare -a BLOCKED=(
        "git commit|(^|[^[:alnum:]_-])git[[:space:]]+commit\b"
        "git add|(^|[^[:alnum:]_-])git[[:space:]]+add\b"
        "git push|(^|[^[:alnum:]_-])git[[:space:]]+push\b"
        "git rebase|(^|[^[:alnum:]_-])git[[:space:]]+rebase\b"
        "git merge|(^|[^[:alnum:]_-])git[[:space:]]+merge\b"
        "git revert|(^|[^[:alnum:]_-])git[[:space:]]+revert\b"
        "git reset --hard|(^|[^[:alnum:]_-])git[[:space:]]+reset[[:space:]]+(--hard|--keep|--merge)\b"
        "git cherry-pick|(^|[^[:alnum:]_-])git[[:space:]]+cherry-pick\b"
        "git am|(^|[^[:alnum:]_-])git[[:space:]]+am\b"
        "git apply|(^|[^[:alnum:]_-])git[[:space:]]+apply\b"
        "git stash|(^|[^[:alnum:]_-])git[[:space:]]+stash\b"
        "sed -i|(^|[^[:alnum:]_-])sed[[:space:]]+(-[a-zA-Z]*i|--in-place)\b"
        "perl -i|(^|[^[:alnum:]_-])perl[[:space:]]+-[a-zA-Z]*i\b"
    )

    for entry in "${BLOCKED[@]}"; do
        name="${entry%%|*}"
        pattern="${entry#*|}"
        if printf '%s' "$COMMAND" | grep -qE "$pattern"; then
            cat >&2 <<EOF
Blocked: orchestrator role (CLAUDE_ROLE=orchestrator) is forbidden
from running code-mutating Bash commands.

Matched pattern: '$name'
Command: $COMMAND

The orchestrator must NOT:
  - git commit / add / push / rebase / merge / revert
  - git reset --hard / cherry-pick / am / apply / stash
  - sed -i, perl -i (in-place edits)

The orchestrator SHOULD:
  - spawn a worker via Agent(...)            -- the worker writes code
  - post PR comments via gh pr comment / gh api
  - run gh pr merge ONLY at the verdict gate (note: 'gh pr merge',
    not 'git merge' — different commands)
  - read-only git ops: status / log / diff / show / rev-parse /
    worktree list
  - manage worktrees: git worktree add/remove (plumbing, not code
    mutation)
  - write orchestrator state metadata under
    ~/.local/state/claude-pr-pipeline/ via Bash redirections

If this fix genuinely belongs to the orchestrator (e.g. you're
debugging the daemon itself, not running a tick), relaunch with
ORCHESTRATOR_WRITES_OK=1 to bypass.

(This block comes from ~/.claude/hooks/block-orchestrator-writes.sh.)
EOF
            exit 2
        fi
    done
fi

exit 0
