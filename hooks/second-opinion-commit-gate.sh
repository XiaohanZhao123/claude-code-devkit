#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher: Bash).
#
# When Claude is about to run `git commit`, runs `codex review --uncommitted`
# on the staged diff and surfaces findings to Claude. The idea: an
# independent second-opinion review from a non-Claude model (whatever
# the user's codex profile points at — Azure OpenAI, OpenAI direct, a
# Copilot reverse-proxy, etc.) before the commit lands, catching mistakes
# Claude can't see in its own diff.
#
# Mode (default: BLOCKING) — on any [P0] finding the hook exits 2, which makes
#   Claude Code show stderr to the model AND block the commit. Claude must
#   address the finding (or add [skip-review] to the commit message) before
#   it can retry. P1/P2 findings remain advisory (exit 1, user-visible only).
#   Set SECOND_OPINION_ADVISORY=1 to disable blocking (P0 → exit 1 like P1/P2).
#
# Latency: ~3-4 min per commit (codex review, depends on model + effort).
#
# Configuration (all env vars):
#   CODEX_PROFILE          — codex profile to use (e.g. "azure", "copilot",
#                            "openai"). If unset, codex uses its own default
#                            from ~/.codex/config.toml. Set this if you keep
#                            multiple profiles and want the gate to pick a
#                            specific one.
#   SKIP_SECOND_OPINION=1  — bypass the gate for the next commit
#   SECOND_OPINION_ADVISORY=1 — never block (P0 becomes advisory like P1/P2)
#
# Skip rules (silently exit 0 when any match):
#   - codex CLI not on PATH
#   - SKIP_SECOND_OPINION=1 in env
#   - commit message contains [skip-review] or [no-verify]
#   - rebase / cherry-pick / merge in progress
#   - branch matches wip/* explore/* propose/*
#   - empty diff (or --amend with empty staged)
#   - diff > 5000 lines
#   - all changed paths in ignore set (*.md, *.lock, data/, cache/, results/)
#
# Pair with the `commit-defense-loop` skill — when this hook blocks a
# commit with a [P0], that skill is the right tool to triage + fix.

set -uo pipefail

# Graceful no-op if `codex` CLI not installed or not on PATH.
command -v codex >/dev/null 2>&1 || exit 0

# Read hook payload (Claude Code passes JSON on stdin)
PAYLOAD=$(cat)
COMMAND=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""), end="")
except Exception:
    pass
' 2>/dev/null) || COMMAND=""

# ============================================================
# Trigger gate: only act on `git commit` invocations
# ============================================================

if ! printf '%s' "$COMMAND" | grep -qE '(^|&&[[:space:]]*|;[[:space:]]*)git[[:space:]]+commit\b'; then
    exit 0
fi

# ============================================================
# Skip rules
# ============================================================

# 0. env override
[[ "${SKIP_SECOND_OPINION:-0}" == "1" ]] && exit 0

# 1. skip markers in commit message
if printf '%s' "$COMMAND" | grep -qE '\[(skip-review|no-verify)\]'; then
    exit 0
fi

# 2. ensure we're in a git repo; if not, allow silently. Parse leading
# `cd <path> && git commit ...` to find the intended repo (PreToolUse
# hooks run BEFORE the wrapped command, so any leading cd hasn't
# happened yet).
WORKDIR=$(printf '%s' "$COMMAND" \
    | sed -nE 's|^[[:space:]]*cd[[:space:]]+"?([^"&;[:space:]]+)"?[[:space:]]*&&.*|\1|p' \
    | head -1)
if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    cd "$WORKDIR" || exit 0
fi

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0

# 3. rebase / cherry-pick / merge in progress
for marker in REBASE_HEAD CHERRY_PICK_HEAD MERGE_HEAD; do
    [[ -e "$GIT_DIR/$marker" ]] && exit 0
done
[[ -d "$GIT_DIR/rebase-merge" ]] && exit 0
[[ -d "$GIT_DIR/rebase-apply" ]] && exit 0

# 4. branch is WIP / exploratory
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$BRANCH" in
    wip/*|explore/*|propose/*) exit 0 ;;
esac

# 5. determine diff scope (handle -a / --all)
if printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+commit\b[^"'"'"']*[[:space:]]-[A-Za-z]*a([A-Za-z]|\b|[[:space:]])' \
   || printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+commit\b[^"'"'"']*--all\b'; then
    DIFF=$(git diff HEAD 2>/dev/null)
else
    DIFF=$(git diff --cached 2>/dev/null)
fi

# 6. amend with no new staged content
if printf '%s' "$COMMAND" | grep -qE -- '--amend' && [[ -z "$DIFF" ]]; then
    exit 0
fi

# 7. truly empty diff
[[ -z "$DIFF" ]] && exit 0

# 8. diff size cap
DIFF_LINES=$(printf '%s\n' "$DIFF" | wc -l)
if (( DIFF_LINES > 5000 )); then
    echo "[second-opinion: skipped, diff too large ($DIFF_LINES lines); review manually if needed]" >&2
    exit 0
fi

# 9. all changed paths are in ignore set
CHANGED=$(printf '%s\n' "$DIFF" | grep -E '^\+\+\+ ' | sed -e 's|^+++ b/||' -e 's|^+++ a/||' -e 's|^+++ ||' | grep -v '^/dev/null$' || true)
SUBSTANTIVE=$(printf '%s\n' "$CHANGED" | grep -vE '(^|/)(\.gitignore|.*\.md|.*\.lock|uv\.lock)$' | grep -vE '^(data|cache|results)/' || true)
if [[ -z "$SUBSTANTIVE" ]]; then
    exit 0
fi

# ============================================================
# Run codex review --uncommitted
# ============================================================
#
# Note: --uncommitted reviews staged + unstaged + untracked. For a
# pre-commit hook we ideally want staged-only, but codex review has
# no --staged flag. The mismatch is: if the user has unstaged work,
# it gets reviewed too. In practice the working tree is usually clean
# except for staged content at commit time, so this is fine. If false
# positives become a problem, wrap with `git stash push --keep-index -u`
# before the call and `git stash pop` after.

PROFILE_ARGS=()
if [[ -n "${CODEX_PROFILE:-}" ]]; then
    PROFILE_ARGS=(--profile "$CODEX_PROFILE")
    echo "[second-opinion: reviewing $DIFF_LINES-line diff with codex review (--profile $CODEX_PROFILE), ~3-4min expected]" >&2
else
    echo "[second-opinion: reviewing $DIFF_LINES-line diff with codex review (default profile from ~/.codex/config.toml), ~3-4min expected]" >&2
fi

REVIEW_OUTPUT=$(timeout 300 codex "${PROFILE_ARGS[@]}" review --uncommitted 2>/dev/null) || REVIEW_OUTPUT=""

# Extract findings: lines like `- [P0] ...`, `- [P1] ...`, `- [P2] ...`
FINDINGS=$(printf '%s\n' "$REVIEW_OUTPUT" | grep -E '^[[:space:]]*-[[:space:]]*\[P[0-2]\]' || true)

# All clean = silent exit 0
if [[ -z "$FINDINGS" ]]; then
    exit 0
fi

# Decide exit code: any [P0] → blocking, else advisory.
#
# Claude Code hook exit-code contract:
#   exit 0 — stdout/stderr NOT shown
#   exit 1 — show stderr to USER only, continue with tool call (advisory)
#   exit 2 — show stderr to MODEL AND block tool call           (blocking)
HAS_P0=0
printf '%s\n' "$FINDINGS" | grep -q '\[P0\]' && HAS_P0=1

if (( HAS_P0 == 1 )) && [[ "${SECOND_OPINION_ADVISORY:-0}" != "1" ]]; then
    MODE_BANNER="=== second-opinion BLOCKING (P0 found; address or add [skip-review] to retry) ==="
    EXIT_CODE=2
else
    MODE_BANNER="=== second-opinion advisory (commit will proceed) ==="
    EXIT_CODE=1
fi

{
    echo ""
    echo "$MODE_BANNER"
    printf '%s\n' "$REVIEW_OUTPUT"
    echo "=== suppress: [skip-review] in msg, SKIP_SECOND_OPINION=1, or SECOND_OPINION_ADVISORY=1 ==="
    echo ""
} >&2

exit "$EXIT_CODE"
