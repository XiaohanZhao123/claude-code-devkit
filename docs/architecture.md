# Architecture — the PR review pipeline

This doc explains the autonomous PR review/fix pipeline (the largest
piece of the kit). For the smaller pieces (individual hooks, the commit
gate, the defense-loop skills), the source code is the doc — each file's
header comment is enough.

## Big picture

```
                    GitHub repo with open PRs
                              │
                              │ gh pr list
                              ▼
   ┌────────────────────────────────────────────────────────┐
   │  ONE tmux session per repo: <repo>-pr                  │
   │                                                        │
   │  ┌──────────────────────┐    ┌──────────────────────┐  │
   │  │ window "review"      │    │ window "orchestrator"│  │
   │  │ /loop /pr-review-tick│    │ /loop /pr-orch-tick  │  │
   │  │ Agent A              │    │ Agent B              │  │
   │  │                      │    │ CLAUDE_ROLE=orch     │  │
   │  └──────────────────────┘    └──────────────────────┘  │
   │     │                              │                   │
   │     │ posts review comment         │ reads comment     │
   │     │ writes notify_orch flag      │ spawns worker     │
   │     ▼                              ▼                   │
   └────────────────────────────────────────────────────────┘
              │                              │
              ▼                              ▼
     PR comment on GitHub          /tmp/orch-<slug>-pr<N>/
     ("Agent A round @ <sha>")     (worker worktree;
                                    sub-agent does the fixes,
                                    commits with [auto N/4],
                                    pushes back to PR branch)
                                          │
                                          ▼
                                 GitHub PR head moves
                                 → Agent A sees new sha
                                 → next review round starts
```

## Agent A — pr-review-tick

**Job**: discover open PRs, dedup against `(pr_number, head_sha) → review_id`
state, and for each PR with new content run a three-angle review then post
a single aggregated comment.

**Three angles, in parallel** (one Bash + two `Agent` calls in one message):

1. **Cross-vendor adversarial** — `codex review` against the PR diff.
   This is genuinely non-Claude signal. The user's codex profile
   determines the backend model (gpt-5, gpt-4o, etc.). Catches Claude
   blind spots that Claude-only review can't.
2. **General Opus review** — `Agent(subagent_type="code-reviewer-opus", ...)`.
   The kit's user-level Opus reviewer, with a confidence ≥ 80 filter so
   it only surfaces high-conviction findings.
3. **PR-level coherence** — `Agent(subagent_type="general-purpose", model="opus", ...)`.
   A bespoke prompt covering things the other two miss: cross-commit
   consistency, scope creep, test completeness, CI status, breaking-change
   detection.

**Output**: one PR comment per round, formatted as:

```
## PR review pipeline — Agent A round N @ <short_sha>

### Critical (must fix)
- [angle/P0] file:line — what + why

### Important
- [angle/P1] ...

### Suggestions (advisory)
- [angle/P2] ...

### CI status at <short_sha>
- ...

---
*Posted by `pr-review-tick` daemon. Angles: codex (...), code-reviewer-opus (...), pr-coherence (...). cc Agent B for triage.*
```

**Big-PR handling**: codex degrades sharply above 5000 lines/call (10–20×
latency, token-counter retries). For PRs larger than that, the skill
synthetic-commit-splits the diff into bins of ≤5000 lines each
(first-fit-decreasing bin packing), commits each bin as a synthetic
commit on a temp worktree with `[skip-review]` in the message, and runs
`codex review --commit <syn_sha>` per bin. The `[skip-review]` marker
keeps the second-opinion-commit-gate hook from recursing.

## Agent B — pr-orch-tick

**Job**: triage Agent A's findings, spawn a sub-agent to fix them, and
gate auto-merge.

**Tick logic**:

1. List PRs that have a new comment from Agent A since the last orch tick.
2. For each: read the comment, parse into `[P0]` / `[P1]` / `[P2]` findings.
3. Spawn a `general-purpose` Agent in a fresh worktree at
   `/tmp/orch-<slug>-pr<N>`. The worker follows the `pr-defense-loop`
   triage discipline: a/b/c split (worth-fixing / wrong-analysis /
   not-worth-fixing), fix the a's, push back on b's with a comment.
   The worker is the only thing that writes code — Agent B itself never
   does. The `block-orchestrator-writes.sh` hook enforces this.
4. Worker commits with `[auto N/4]` suffix and pushes to the PR branch.
   Each commit triggers the second-opinion-commit-gate hook (since
   `[auto N/4]` is not `[skip-review]`); if the gate blocks, the worker
   loops on its own `commit-defense-loop`.
5. After the worker reports "no more actionable findings" (or
   `max_rounds=4` hits), Agent B runs the **verdict gate**:
   - If `dry_run` flag exists: post a "would auto-merge" comment instead
     of merging.
   - If the PR author is an external contributor: refuse to auto-merge
     regardless of dry-run state; @-mention the user.
   - Otherwise: `gh pr merge` (squash by default).

**Concurrency**: per-PR `flock` lock files prevent Agent A and Agent B
from racing on the same PR.

## Why orchestrator is read-only

The orchestrator can spawn sub-agents that do anything (worker writes
code, commits, pushes; review writes comments). But the orchestrator
itself never directly invokes Edit, Write, `git commit`, etc.

The reason: an orchestrator that can both make decisions AND mutate code
will, under load, accidentally try to fix things directly instead of
delegating. We've seen it. The `block-orchestrator-writes.sh` hook
makes "delegate to a worker" the ONLY viable code-fix path. The
orchestrator that can't write code can't shortcut delegation.

The hook is gated on `CLAUDE_ROLE=orchestrator` (env var set by the
launcher) and bypasses when the PreToolUse payload has an `agent_id`
(meaning the call is coming from a sub-agent, not the orchestrator
itself). Sub-agents inherit the env var but are intended to write —
the `agent_id` field is how the hook distinguishes them.

## State directory

Lives at `~/.local/state/claude-pr-pipeline/<owner>__<repo>/`:

```
dry_run                       # presence = Agent B posts "would auto-merge" instead of merging
last_review_tick_at           # ISO timestamp of last Agent A run
last_orch_tick_at             # ISO timestamp of last Agent B run
notify_orch                   # touched by Agent A to wake Agent B early (if Monitor is set up)
pr-<N>/
    head_sha                  # last reviewed sha for PR N
    review_comment_id         # last review-comment id (for dedup)
    fix_round                 # how many auto-fix rounds happened (caps at 4)
```

The state directory is **shared between Agent A and Agent B** within a
repo. Cross-repo state is fully isolated (different subdirs).

## Cron + Monitor (two wake channels)

The skills set up two ways to wake on each tick:

1. **Cron `*/2 * * * *`** (mandatory, primary). Created by the skill's
   step 1.5 on first tick using Claude Code's `CronCreate` tool. The
   skill DELETES + recreates if it finds a wrong interval.
2. **Monitor on `notify_orch` file** (optional, for orchestrator only).
   Watches for Agent A to touch the file, gives sub-minute wake latency.
   Not critical when cron is `*/2` — but useful if you dial cron up to
   `*/10` for some reason.

Cron + Monitor are both in-process in Claude Code (no external cron
daemon). They survive session resume but not session kill.

## Tear-down

```bash
tmux kill-session -t <repo>-pr     # stop the daemons
# Optionally:
rm -rf ~/.local/state/claude-pr-pipeline/<owner>__<repo>/   # wipe state
# Per-PR worker worktrees clean themselves up after each tick, but
# leftovers at /tmp/orch-<slug>-pr<N>/ are safe to remove manually.
```

The `protect-state-from-rm.sh` hook blocks `rm -rf` against the state
dir to prevent accidental wipes inside a Claude session. To bypass for
a legitimate cleanup, run the `rm` outside Claude or set
`PR_PIPELINE_RM_OK=1` for that session.

## Caveats

- **dry_run by default for ~7 days.** The kit assumes you want to watch
  Agent B's verdicts on real PRs for a while before letting it actually
  merge. The first bring-up creates `dry_run`; you `rm` it when you trust
  the verdicts.
- **External contributors are never auto-merged.** Agent B refuses to
  `gh pr merge` if the PR author isn't in the repo's collaborator set,
  regardless of dry_run state.
- **`max_rounds=4` per PR.** If the worker can't close findings in 4
  rounds, Agent B escalates to the operator instead of looping forever.
- **No support for monorepos with selective path triggers.** The pipeline
  reviews the full PR diff every round. If you have a big monorepo with
  per-team CODEOWNERS, you'll want to add a path-filter step yourself.
- **The cross-vendor adversarial angle requires a working codex
  profile.** Without one, the skill falls back to 2 angles and notes the
  miss. The kit doesn't tell you which codex profile to use — any
  non-Claude reviewer model works.
