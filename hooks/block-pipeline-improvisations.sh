#!/usr/bin/env bash
# Global Claude Code PreToolUse hook (matcher: Bash).
#
# Deterministically blocks Bash patterns the PR-pipeline daemons have
# been observed improvising — patterns NOT documented in the SKILL and
# that consistently leak resources / poison state when invented.
#
# Gating: only fires on Bash commands that touch the pipeline state
# directory (`claude-pr-pipeline`). Avoids false positives elsewhere.
#
# Bypass: PIPELINE_IMPROVISATION_OK=1 env (set only when legitimately
# debugging the daemon itself, never inside a tick).

set -uo pipefail

if [ "${PIPELINE_IMPROVISATION_OK:-}" = "1" ]; then
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

# Only act on commands referencing the pipeline state directory.
# If the command doesn't touch claude-pr-pipeline, this hook doesn't care.
if ! printf '%s' "$COMMAND" | grep -q 'claude-pr-pipeline'; then
    exit 0
fi

# ============================================================
# Pattern 1: high-fd redirect to a pipeline state file
# ============================================================
#
# Canonical flock pattern in SKILL step 3 uses fd 9. fd numbers ≥ 30
# are improvisations. The observed incident used fd 200 to keep the
# lock open across an orphan `sleep 7200` process.
#
# We match: `exec FD>` or `FD>...claude-pr-pipeline...` where FD ≥ 30.
# Two-digit fds (10-29) are still suspicious but might appear in legit
# code; we allow them. Three-digit fds and 30-99 are blocked.

if printf '%s' "$COMMAND" | grep -qE '\bexec[[:space:]]+([3-9][0-9]|[1-9][0-9]{2,})>'; then
    cat >&2 <<EOF
Blocked: high-fd redirect (fd ≥ 30) in a pipeline-state command.

Command:    $COMMAND

The canonical flock pattern in pr-orch-tick SKILL step 3 uses fd 9:

    exec 9>"\$PR_DIR/lock"
    flock -n -x 9

Improvising with high fds (e.g. fd 200) is the signature of the
'background-sleep-holding-flock' anti-pattern that has previously
leaked orphan processes holding pipeline locks for hours. Don't.

If you genuinely need to read/write a different file with a different
fd, use fd 3-29 (and don't put pipeline state behind it).

(Hook: ~/.claude/hooks/block-pipeline-improvisations.sh)
EOF
    exit 2
fi

# ============================================================
# Pattern 2: long backgrounded sleep in pipeline-context command
# ============================================================
#
# The observed incident: `sleep 7200 &` to keep a flock-holding fd
# open after the parent tick exited. Long sleeps (≥ 100 seconds)
# combined with `&` are the signature of "outlive the parent" tricks.
#
# We allow short polling sleeps (e.g. `sleep 2` in a `while; do; done`
# loop) — only ≥ 100s with `&` gets blocked.

if printf '%s' "$COMMAND" | grep -qE '\bsleep[[:space:]]+[0-9]{3,}([^0-9].*)?&'; then
    cat >&2 <<EOF
Blocked: long backgrounded sleep (≥ 100s with '&') in a pipeline-state command.

Command:    $COMMAND

This is the signature of the 'orphan sleep holds the flock cross-tick'
anti-pattern. The pipeline lock is per-tick by design — it auto-releases
when the tick exits. DO NOT try to extend it via background sleeps,
disown, or nohup.

If you think you need cross-tick coordination: that's what the on-disk
state files (last_orch_round_sha, last_escalated_sha, etc.) are for.

(Hook: ~/.claude/hooks/block-pipeline-improvisations.sh)
EOF
    exit 2
fi

# ============================================================
# Pattern 3: flock on high fd
# ============================================================
#
# Sometimes Pattern 1's `exec FD>` is split into a separate command
# and only `flock -x FD` lands in a later command. Catch the flock
# side too. SKILL uses fd 9; anything ≥ 30 is improvisation.

if printf '%s' "$COMMAND" | grep -qE '\bflock\b[^|;&]*[[:space:]]-[xsuw]+[[:space:]]+([3-9][0-9]|[1-9][0-9]{2,})\b'; then
    cat >&2 <<EOF
Blocked: flock invoked on a high fd (≥ 30) in a pipeline-state command.

Command:    $COMMAND

Canonical pattern is fd 9 (SKILL pr-orch-tick step 3). If you're seeing
this in a flock command that follows an earlier high-fd `exec`, that
combination is the orphan-sleep-flock anti-pattern; switch to fd 9 and
release the lock at tick exit.

(Hook: ~/.claude/hooks/block-pipeline-improvisations.sh)
EOF
    exit 2
fi

# ============================================================
# Pattern 4: write to deprecated state-file name `escalated_at`
# ============================================================
#
# escalated_at is the deprecated per-PR permanent-freeze marker.
# Replaced by per-SHA last_escalated_sha. The daemon has repeatedly
# tried to revive it. Block writes to that specific filename.
#
# Matches:  > .../escalated_at
#           >> .../escalated_at
#           echo ... > escalated_at  (in a cd'd state dir context)

if printf '%s' "$COMMAND" | grep -qE '>[[:space:]]*"?[^"]*[/]escalated_at(["[:space:]]|$)'; then
    cat >&2 <<EOF
Blocked: write to deprecated state file 'escalated_at'.

Command:    $COMMAND

escalated_at is the OLD permanent-freeze marker. It has been replaced
by per-SHA 'last_escalated_sha' which auto-invalidates when head moves.

If you reach this hook, your SKILL view is stale or your reasoning has
fallen back to pre-rewrite patterns. Re-read pr-orch-tick step 7d /
step 8 — escalation now stamps last_escalated_sha, not escalated_at.

(Hook: ~/.claude/hooks/block-pipeline-improvisations.sh)
EOF
    exit 2
fi

exit 0
