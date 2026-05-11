---
name: pr-orch-tick
description: One orchestration cycle of the PR review pipeline (Agent B). Designed to be invoked by `/loop /pr-orch-tick` inside a long-running tmux daemon session, sibling to `/pr-review-tick` (Agent A). Each tick discovers PRs that have a new review comment from Agent A, spawns a fix worker sub-agent (in an isolated git worktree at `/tmp/orch-<slug>-pr<N>`) following the `pr-defense-loop` triage discipline, applies fixes with `[auto N/4]` tagged commits, and after the worker reports "no more actionable findings" runs the merge-gate verdict — either posting a "would auto-merge" dry-run comment, executing `gh pr merge`, or @-mentioning the user with a summary. Use this whenever the user says "start the orchestrator daemon", "Agent B", "kick off the orch tick", or `/loop /pr-orch-tick`. NEVER reviews PRs (that's Agent A's job). Caps at `max_rounds=4` per PR; refuses to auto-merge external contributor PRs regardless of dry-run state; respects per-PR `flock` so it never collides with Agent A.
---

# PR orchestration tick — Agent B of the PR review pipeline

A single orchestration cycle. Designed to be invoked by `/loop /pr-orch-tick`
in a long-running tmux Claude Code session (one per repo, sibling to the
`/pr-review-tick` daemon). Self-paces via `ScheduleWakeup` at the end of
every tick. State persists across ticks on disk; context loss between
iterations is harmless.

## Architecture context

See `pr-review-tick/SKILL.md` for the full pipeline diagram. This skill
is the **fix + verdict** half:

- Agent A reviews → posts ONE comment per PR per new HEAD SHA.
- **This skill** triages that comment → spawns a fix worker → after the
  worker says "no more findings worth fixing" → runs the merge-gate
  verdict → either dry-run comment / real merge / escalate to user.

This skill MUST NOT review PRs. Reviewing is Agent A's job. If you
find yourself wanting to "double-check Agent A's findings against the
actual code," stop — that's a fix-worker concern (the worker triages
into (a) worth fixing / (b) wrong analysis / (c) not worth), not an
orchestrator concern.

## Orchestrator role: read-only contract

The orchestrator (this skill, running as the top-level Claude in the
daemon's tmux session) is **strictly read-only with respect to code**.
Only the worker (sub-agent spawned via `Agent`) is allowed to modify
files or commit code.

**The orchestrator NEVER:**
- Modifies code (no `Edit`, `Write`, `NotebookEdit`)
- Runs `git commit` / `git add` / `git push` / `git rebase` /
  `git merge` / `git revert` / `git reset --hard` / `git cherry-pick` /
  `git stash` / `git apply` in any repo
- Modifies CLAUDE.md / AGENTS.md / specs / source files / tests /
  configs
- Stages anything in any repo

**The orchestrator ONLY:**
- Reads PR / repo state via `gh` and read-only `git` ops
  (`status` / `log` / `diff` / `show` / `rev-parse` / `worktree list`)
- Manages worktrees: `git worktree add` / `git worktree remove`
  (plumbing, not code mutation)
- Spawns workers via `Agent(subagent_type="general-purpose", ...)` —
  the worker does ALL the writing
- Posts PR comments via `gh pr comment` / `gh api`
- Runs `gh pr merge` at the verdict gate (note: `gh pr merge`, NOT
  `git merge` — different commands; the latter is forbidden)
- Writes orchestrator state metadata under
  `~/.local/state/claude-pr-pipeline/` via Bash redirections
  (`echo X > file`, `jq ... >> file`)

**Enforcement (two layers):**

1. **Layer 0 (this prose):** the prompt-level prohibition above.
   LLMs sometimes attempt forbidden actions despite explicit rules,
   so this layer alone is not sufficient.

2. **Layer 2 (hook):** `~/.claude/hooks/block-orchestrator-writes.sh`,
   gated on the env var `CLAUDE_ROLE=orchestrator`. The hook runs in
   `PreToolUse` and **deterministically blocks** Edit/Write/NotebookEdit
   tools and the forbidden `git` / `sed -i` / `perl -i` Bash patterns.
   This is the equivalent of "removing those tools" for a top-level
   Claude — Claude Code does not natively support per-role tool
   removal for top-level sessions, so a hook gated on env var is the
   cleanest available mechanism.

   (Layer 1 — physically removing the tools — only applies cleanly to
   sub-agents, where `subagent_type` determines the tool set. Top-level
   Claude reads tools from `settings.json`, which has no env-var
   conditional. The hook is the practical equivalent.)

**To launch the daemon with the role correctly set:**

```bash
CLAUDE_ROLE=orchestrator claude --resume <session>
# or if starting fresh:
CLAUDE_ROLE=orchestrator claude
```

If the daemon is launched without `CLAUDE_ROLE=orchestrator`, the hook
is a no-op and the orchestrator can write code — **this is a bug in
the launch, not a feature**. Verify with:

```bash
echo "$CLAUDE_ROLE"  # should print "orchestrator" inside the daemon
```

**One-off bypass:** if you genuinely need the orchestrator to write
something (e.g., debugging the daemon itself, not running a tick),
relaunch with `ORCHESTRATOR_WRITES_OK=1` set. Don't bypass casually.

## When to use

Trigger phrases:
- `/loop /pr-orch-tick` (the canonical invocation)
- "start the orchestrator daemon for this repo"
- "do one PR orch tick"
- "Agent B: run a tick"

Pre-conditions (in addition to Agent A's):
- `git worktree` is available (it always is on git 2.5+).
- The current working directory of the daemon is a git worktree of
  the target repo (we'll spawn temp worktrees from it via
  `git worktree add`).
- Branch protection rules on the repo allow `gh pr merge` from the
  authenticated user, **OR** the user has set up auto-merge admin
  override.

## State

Shares the per-repo state directory with Agent A:

```
~/.local/state/claude-pr-pipeline/
  <owner>__<repo>/
    pr-<N>/
      lock                      # shared with Agent A — flock(1)
      last_reviewed_sha         # Agent A writes; Agent B reads
      last_reviewed_id          # Agent A writes; Agent B reads
      author_association        # Agent A writes; Agent B reads
      last_findings.jsonl       # Agent A writes; Agent B reads

      last_orch_round           # this skill writes: 0..4
      last_orch_action_at       # ISO timestamp of last commit/push by worker
      consecutive_no_actionable # this skill writes: 0..2
      escalated_at              # ISO timestamp; if set, this skill stops touching the PR until cleared
      verdict_log.jsonl         # one record per verdict gate evaluation
    dry_run                     # repo-scoped flag file; presence = dry-run mode
```

The `dry_run` flag file is at the **repo level**, not per-PR. New repos
should have it created on daemon startup; user `rm`s it after ~7 days
of observed sane verdicts to flip to real-merge mode.

## The hard cap: max_rounds = 4

After 4 rounds of fix-and-push on the same PR, **stop**. Don't run a 5th.
Either:
- The worker has been chasing false positives (check `verdict_log.jsonl`
  for a pattern of low-confidence rounds) → escalate to user with the
  triage history.
- The worker is making real progress but the PR is genuinely complex
  → escalate; Agent B is not designed to ship arbitrarily-complex
  refactors autonomously.

`last_orch_round` is the canonical counter. Worker commit messages
embed `[auto N/4]` so the cap is auditable from `git log` alone.

## Per-tick procedure

### 1. Pre-flight

Same dependency checks as `pr-review-tick` plus:

```bash
# Verify we can git worktree
git worktree --help >/dev/null 2>&1 || { echo "[pr-orch-tick] git too old"; exit 1; }
```

Resolve `REPO_SLUG` and `STATE_ROOT` identically to Agent A.

If `STATE_ROOT/dry_run` doesn't exist on first run for a new repo,
**create it**. New repos default to dry-run mode per the pipeline
design.

### 1.5. Wake-up channels — MANDATORY at every tick

> **YOU MUST DO THIS STEP. DO NOT PROCEED TO STEP 2 UNTIL BOTH CHANNELS
> ARE VERIFIED RUNNING.** This is not optional, not "set up once and
> forget", not "if convenient". Every tick verifies both, repairs any
> that died.
>
> Past observation: daemons that skipped this step ended
> up with 10-minute cron + no Monitor at all, missing every fast A→B
> handoff. The user had to manually intervene to fix the cadence after
> noticing the staleness. Don't be that daemon.

Two wake channels. Without BOTH, the daemon either misses fast events
(Channel 2 dead) or has no liveness guarantee (Channel 1 dead).

**`/loop` dynamic ScheduleWakeup is unavailable** — the harness rejects
it with "/loop dynamic gate off" inside cron-driven daemons. So
ScheduleWakeup is NOT a substitute for either channel below. Don't
attempt it as a fallback.

#### Channel 1: cron heartbeat (every 2 minutes — MANDATORY)

```python
# Verify the cron job exists AND has the right interval. If it has the
# wrong interval (e.g., */10), DELETE it and recreate with */2.
existing = CronList()
correct = False
to_delete = []
for j in existing.get("jobs", []):
    if j.get("prompt") == "/loop /pr-orch-tick":
        if j.get("cron") == "*/2 * * * *":
            correct = True
        else:
            to_delete.append(j["id"])  # wrong interval

for jid in to_delete:
    CronDelete(id=jid)

if not correct:
    CronCreate(
        cron="*/2 * * * *",        # MANDATORY: every 2 minutes
        prompt="/loop /pr-orch-tick",
        recurring=True,
        durable=False,
    )
```

**`*/2`, NOT `*/5` or `*/10`.** The user expects PR fixes to land
within minutes of Agent A's review, not within 10–15 minutes. Idle
ticks just hit GitHub's API (sub-second, no model calls), so 5× more
ticks costs essentially nothing in either time or backend tokens.

#### Channel 2: Monitor on `notify_orch` (event-driven, ~2s latency — MANDATORY)

Agent A writes `$STATE_ROOT/notify_orch` after posting any review
comment. We watch its mtime via a python3 polling loop and emit one
stdout line per change → arrives as a notification → daemon wakes for
an immediate tick.

> **CRITICAL: `Monitor` is a deferred tool.** Past observation
>: daemons claimed "no Monitor tool available in this
> harness" and skipped Channel 2 entirely. The fix is to call
> `ToolSearch(query="select:Monitor")` first to load Monitor's
> schema into this session — only after that can `Monitor()` be
> invoked. **Do this even if you've never seen Monitor before; it's
> always available, just lazy-loaded.**

```python
import os

# Step 0 of Channel 2: load Monitor's schema. WITHOUT this, Monitor()
# below will silently fail / be reported as unavailable.
ToolSearch(query="select:Monitor")

notify_path = f"{STATE_ROOT}/notify_orch"
marker = f"{STATE_ROOT}/.monitor_pid"

# Verify the existing Monitor is alive via PID-marker check.
already_alive = False
if os.path.exists(marker):
    try:
        pid = int(open(marker).read().strip())
        os.kill(pid, 0)  # signal 0 = existence check; raises if dead
        already_alive = True
    except (ProcessLookupError, ValueError, FileNotFoundError):
        pass

if not already_alive:
    Monitor(
        persistent=True,
        description=f"notify_orch mtime change for {REPO_SLUG}",
        command=f'''
python3 -c '
import os, time
with open("{marker}", "w") as f: f.write(str(os.getpid()))
last = 0
while True:
    try:
        m = os.stat("{notify_path}").st_mtime
        if m > last:
            if last != 0:
                print(f"NOTIFY_ORCH_MODIFIED ts={{int(m)}}", flush=True)
            last = m
    except FileNotFoundError:
        pass
    time.sleep(2)
'
        ''',
        timeout_ms=3600000,
    )
```

When a `NOTIFY_ORCH_MODIFIED` line arrives as notification, run another
`/pr-orch-tick` IMMEDIATELY. Don't wait for the next 2-minute cron fire.

#### Step-1.5 verification checklist (run before exiting step 1.5)

- [ ] `CronList()` shows a `/loop /pr-orch-tick` entry with `cron="*/2 * * * *"`
- [ ] `~/.local/state/.../$REPO_SLUG/.monitor_pid` exists and points at a live PID
- [ ] If either is missing, fix it now before going to step 2

If both green, proceed to step 2.

### 2. Discover work

For each open non-draft PR:

```bash
PR_DIR="$STATE_ROOT/pr-$N"
[[ -d "$PR_DIR" ]] || continue   # Agent A hasn't seen this PR yet
[[ -f "$PR_DIR/escalated_at" ]] && continue   # already escalated, hands off
```

A PR needs orchestrator attention if:
- `last_reviewed_sha` exists (Agent A reviewed it)
- AND (`last_orch_round` doesn't exist OR `last_orch_round < 4`)
- AND the most recent issue/review comment from us (the daemon's
  GitHub identity) on this PR is OLDER than `last_reviewed_at` —
  i.e., Agent A has posted a comment we haven't responded to yet.

If no PR needs attention this tick, re-arm and exit.

### 3. Acquire the per-PR lock

```bash
exec 9>"$PR_DIR/lock"
flock -n -x 9 || { echo "[pr-orch-tick] PR #$N busy with Agent A, retry next tick"; continue; }
```

### 4. Spawn the fix worker

The worker runs in an **isolated git worktree** so the daemon's tmux
session's git state stays untouched.

```bash
WORKTREE=/tmp/orch-${REPO_SLUG}-pr${N}
rm -rf "$WORKTREE"  # clean slate; the previous worker should have removed it
git worktree add --detach "$WORKTREE"
(
  cd "$WORKTREE"
  gh pr checkout "$N"   # handles fork remotes automatically
  # The worker Agent operates here; see prompt below.
)
git worktree remove "$WORKTREE" --force
```

Spawn the worker via the `Agent` tool:

```python
Agent(
    description=f"PR #{N} fix worker round {round_n}/4",
    subagent_type="general-purpose",
    prompt=<<see "Worker prompt" below>>
)
```

#### Worker prompt (template — substitute concrete values)

```
You are the fix worker for the PR review pipeline (Agent B's
sub-agent). Your job for this round only:

1. cwd is `{WORKTREE}`. The PR branch is checked out. Verify with
   `git status` + `git log --oneline -5` before doing anything.

2. Read these files in this order:
   - `~/.claude/skills/pr-defense-loop/SKILL.md` — the triage discipline
     (a) worth fixing / (b) wrong analysis / (c) not worth fixing.
     Apply this exactly. Don't reinvent it.
   - The PR description: `gh pr view {N} --json body -q .body`
   - The repo's CLAUDE.md / AGENTS.md (read from `{WORKTREE}`).
   - Agent A's latest review comment:
     `gh api repos/{OWNER}/{REPO}/issues/{N}/comments | jq '...latest from us'`
   - Local findings cache: `{PR_DIR}/last_findings.jsonl`

3. Triage every finding into (a) / (b) / (c) per the
   pr-defense-loop discipline. Be honest about (b) — false positives
   are real; don't paper over them by shuffling code.

4. Fix the (a) bucket. Constraints:
   - Honor the repo's CLAUDE.md / AGENTS.md (package manager, config
     system, storage discipline, language conventions).
   - One regression test per real bug fixed.
   - **Run the test suite locally before pushing. DO NOT push if it
     fails.** How to run:
       * Read the repo's CLAUDE.md / AGENTS.md / pyproject.toml /
         package.json to find the canonical command (typical:
         `uv run pytest`, `npm test`, `cargo test`, `go test ./...`).
       * Run unit tests for modules you touched. If your diff is broad
         (>3 modules) or you can't tell which tests cover the change,
         run the full unit suite, except groups requiring missing deps
         (e.g. `--ignore=tests/rollout` if the rollout dep group isn't
         installed in the worktree).
       * For E2E / smoke / integration tests that the repo's runbook
         calls out as part of the merge bar: **run them inline, in
         your own context.** Yes, the test output may be heavy — that
         is intentional. You ARE a sub-agent; you do NOT have the
         `Agent` tool, so you cannot delegate tests to a sibling
         sub-agent. Conversely, the orchestrator (Agent B) is
         strictly read-only and cannot run tests for you. Tests are
         your responsibility, top to bottom.
       * Failed-test context staying inside your context window is
         actually useful: if the orchestrator triggers another round
         on the same PR, you'll inherit no memory by default — but
         the failure trace going into your commit message (or your
         `blocked` reason) preserves the signal across rounds.
   - If tests fail and you cannot fix without out-of-scope changes:
     do NOT push. Return with `blocked: "<test name> fails after fix
     attempt; need wider scope: <one-line specifics>"`. Include the
     first ~20 lines of the failure trace in the blocked reason —
     the orchestrator escalates to the user with this verbatim, so
     specificity here saves a round trip.
   - English code/comments. No emojis unless the repo already uses them.

5. Commit and push. ONE commit per round. Format:

   ```
   fix(<scope>): address Agent A round-{round_n} [auto {round_n}/4]

   <one-paragraph framing>

   1. <severity> — <file:line>: <what was wrong, what was fixed>
   2. ...

   Tests: <names of regression tests added>. Suite: <result>.

   Also: <if any (b) false positives — name them, why they're wrong,
   no code change>.

   Co-Authored-By: <model> <noreply@anthropic.com>
   ```

   The `[auto {round_n}/4]` tag is REQUIRED — it's how the daemon
   recognizes its own work and how the cap is auditable.

6. `git push origin <branch>`.

7. Return a structured summary as your final message:

   {
     "round": {round_n},
     "actionable_count": <count of (a) findings>,
     "fixed_count": <count actually fixed and committed>,
     "false_positives": [<comment ids confirmed (b)>],
     "not_worth": [<comment ids triaged (c)>],
     "tests_added": [<test names>],
     "head_sha": "<new HEAD after push>",
     "self_confidence": <0.0..1.0 — see calibration below>,
     "blocked": <null OR a string explaining what blocked you>
   }

   "blocked" examples: "tests fail and I can't fix without breaking
   PR scope", "fix requires schema migration I'm not authorized to
   touch", "AGENTS.md forbids modifying this path".

8. If `actionable_count == 0`, do NOT commit. Return the summary
   with `fixed_count: 0` and a high `self_confidence` reflecting "all
   remaining findings are (b) or (c)."

Self-confidence calibration:
- 0.95+ — All findings cleanly addressed; tests pass; (b)/(c) buckets
  well-justified; no surprises in the diff.
- 0.85–0.94 — All findings addressed but one or more required
  judgment calls you're slightly unsure about.
- 0.70–0.84 — Worked but flagged at least one issue you're uneasy
  about; would prefer a human glance.
- < 0.70 — Don't auto-merge regardless of gate. Set `blocked` if
  appropriate.

Anti-patterns:
- DO NOT amend or rebase past commits — one new commit per round.
- DO NOT push if tests fail.
- DO NOT silently address a (b) finding to make the bot happy. Push
  back via the commit message's "Also:" paragraph.
- DO NOT skip the `[auto N/4]` tag — it's load-bearing.
```

### 5. Read the worker's return value

If the worker returned with `blocked: <reason>` → escalate immediately
(jump to step 8 with `gate_reason="worker blocked: <reason>"`).

Otherwise update state:

```bash
echo "$((round_n))"          > "$PR_DIR/last_orch_round"
date -Iseconds                > "$PR_DIR/last_orch_action_at"
echo "$worker_summary"       >> "$PR_DIR/verdict_log.jsonl"
```

If `actionable_count == 0`:

```bash
n=$(cat "$PR_DIR/consecutive_no_actionable" 2>/dev/null || echo 0)
echo $((n + 1)) > "$PR_DIR/consecutive_no_actionable"
```

Else reset:

```bash
echo 0 > "$PR_DIR/consecutive_no_actionable"
```

### 6. Decide: continue, verdict, or escalate

| Condition | Action |
|---|---|
| `consecutive_no_actionable >= 2` | Worker is converged → **enter verdict gate** (step 7) |
| `last_orch_round >= 4` AND worker still found actionable | Hit the cap → **escalate** (step 8) with reason "max_rounds reached" |
| Worker pushed a fix this round | Release lock, re-arm; Agent A will review the new SHA next tick, then come back |
| Worker returned `blocked` | **Escalate** (step 8) with the worker's reason |

### 7. Verdict gate

Compute the gate. ALL of the following must be true to be eligible
for auto-merge:

```python
ci_green = all(
    check["conclusion"] == "success"
    for check in gh_api(f"repos/{OWNER}/{REPO}/commits/{HEAD_SHA}/check-runs")["check_runs"]
)
diff_ok = (lines_changed < 200 and files_changed < 5)
paths_ok = not any(
    re.match(r"^(\.github/|migrations/|.*\.lock|secrets/|auth/|crypto/|config/)", p)
    for p in changed_paths
)
no_test_deletions = no diff hunks remove lines from test files
confidence_ok = worker_self_confidence >= 0.85
codex_clean = the most recent codex review on this PR (from Agent A's
              last_findings.jsonl) reports zero [P0] findings
internal_author = author_association in ("OWNER", "MEMBER", "COLLABORATOR")
```

Note `internal_author` is REQUIRED for auto-merge. External
contributor PRs ALWAYS escalate to the user, regardless of dry-run
state. This is non-negotiable per the pipeline design.

`gate_pass = ci_green AND diff_ok AND paths_ok AND no_test_deletions
             AND confidence_ok AND codex_clean AND internal_author`

Three branches:

#### 7a. `gate_pass == True` AND `dry_run` flag file present

Post a comment on the PR (do NOT merge):

```markdown
## PR review pipeline — Agent B verdict @ <HEAD_SHA short>

**Would auto-merge** (dry-run mode active; no action taken).

Gate: PASS
- CI: ✓ all checks green
- Diff size: ✓ <lines> lines, <files> files
- Path safety: ✓ no security/migration/config changes
- Test deletions: ✓ none
- Worker confidence: ✓ <conf>
- codex: ✓ no [P0]
- Author: ✓ internal

cc @{user} — when you're ready to flip out of dry-run mode for this
repo, `rm ~/.local/state/claude-pr-pipeline/{REPO_SLUG}/dry_run`.

Worker rounds: {last_orch_round}/4. Total commits this loop: {N}.
```

Write to `verdict_log.jsonl`. Don't escalate further (the comment IS
the escalation, and the user opted into dry-run for exactly this
reason).

#### 7b. `gate_pass == True` AND no `dry_run` flag file

Real merge:

```bash
gh pr merge "$N" --squash --delete-branch=false  # repo-policy dependent
```

Post a confirmation comment after merge succeeds:

```markdown
## PR review pipeline — Agent B verdict @ <HEAD_SHA>

**Auto-merged.** Gate PASS.

[same gate breakdown as 7a]

Worker rounds: {last_orch_round}/4.
```

#### 7c. `gate_pass == False`

Escalate (step 8) with a reason listing which gate items failed.

### 8. Escalation

Post a PR comment with `@{user}` mention:

```markdown
## PR review pipeline — Agent B escalation @ <HEAD_SHA short>

@{user} — this PR needs your judgment. Agent B will not auto-merge.

**Reason:** {gate_reason}

**Gate breakdown:**
- CI: {✓/✗} {detail if failed}
- Diff size: {✓/✗} <lines> lines, <files> files
- Path safety: {✓/✗} {paths matched if failed}
- Test deletions: {✓/✗} {deleted tests if any}
- Worker confidence: <conf> (threshold 0.85)
- codex: {✓/✗ N [P0] findings remaining}
- Author: {OWNER/MEMBER/COLLABORATOR/CONTRIBUTOR/...}

**Round history:**
{worker summary table from verdict_log.jsonl}

**Outstanding findings (worker triaged but didn't fix):**
{(b) and (c) buckets — comment ids and reasons}

When you've decided, either:
- Merge manually if you accept the risk Agent B flagged.
- Push a fix and `rm {PR_DIR}/escalated_at` to re-engage Agent B.
- Close the PR.
```

```bash
date -Iseconds > "$PR_DIR/escalated_at"
```

The `escalated_at` flag stops Agent B from touching the PR until the
user clears it. Agent A keeps reviewing new pushes (which is fine —
the user can use those to decide).

### 9. Cleanup and re-arm

```bash
git worktree remove "$WORKTREE" --force 2>/dev/null || true
flock -u 9 2>/dev/null  # release the lock
exec 9>&-

# Touch repo-level "B just ticked" timestamp. Used by the
# notify_orch fast-handoff check below — this is how we know whether
# A's notify is NEW relative to our last tick.
date -Iseconds > "$STATE_ROOT/last_orch_tick_at"
```

**Re-arm: nothing to do.** Channel 1 (cron 2-min) and Channel 2
(Monitor on notify_orch) from step 1.5 are already in place and will
wake the daemon at the right time. Just exit and let them fire.

If you have NOT yet set up channels 1/2 (e.g., this is the first tick
of a new session): go back and do it now per step 1.5.

The historical Phase 1 ScheduleWakeup cadence table is preserved
below as a fallback for the rare case where neither cron nor Monitor
is available — but in practice the harness rejects ScheduleWakeup
("/loop dynamic gate off"), so this code path is dead. Keep for
documentation only.

<details>
<summary>Phase 1 ScheduleWakeup cadence (deprecated; kept for reference)</summary>

| Situation | delaySeconds | Note |
|---|---|---|
| `notify_orch` mtime > `last_orch_tick_at` mtime | **60** | A just posted a review since our last tick |
| Just spawned a worker that pushed a fix | 270 | Agent A will review the new SHA in its next tick |
| Just escalated | 1800 | Nothing to do until user clears `escalated_at` |
| No PR needed orchestration this tick | 1200 | Idle |

```bash
NOTIFY_TS=$(stat -c %Y "$STATE_ROOT/notify_orch" 2>/dev/null || echo 0)
LAST_TICK_TS=$(stat -c %Y "$STATE_ROOT/last_orch_tick_at" 2>/dev/null || echo 0)
if [ "$NOTIFY_TS" -gt "$LAST_TICK_TS" ]; then
    DELAY=60; REASON="A posted since our last tick"
elif [[ <just spawned a worker that pushed> ]]; then
    DELAY=270; REASON="just pushed a fix"
elif [[ <just escalated> ]]; then
    DELAY=1800; REASON="escalated"
else
    DELAY=1200; REASON="idle"
fi

ScheduleWakeup(delaySeconds=DELAY, prompt="/loop /pr-orch-tick", reason=REASON)
```

</details>

## External contributor PRs

`author_association` in `("CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR", "NONE", "MANNEQUIN")`:

- Check `gh pr view <N> --json maintainerCanModify`.
- If `maintainerCanModify == False`: **don't even spawn the worker.**
  Post an escalation comment immediately: "External PR without
  maintainer-edit permission; cannot auto-fix. cc @{user}".
- If `maintainerCanModify == True`: spawn the worker normally
  (`gh pr checkout` and push will work). But at the verdict step,
  ALWAYS escalate — never auto-merge external contributions
  regardless of dry-run state.

This is a hard rule. Do not allow it to be overridden by a config flag
in the first 6 months of operating this pipeline. External-contributor
PRs are the canonical place where automated merge decisions go wrong;
the cost of an unwanted merge there is bigger than the convenience of
auto-merging.

## Anti-patterns

- **Don't auto-merge external PRs.** See above.
- **Don't run more than one fix worker concurrently per PR.** The
  per-PR `flock` enforces this — don't try to "optimize" by spawning
  parallel workers; they'll race-push and confuse Agent A.
- **Don't skip the dry-run flag check.** The user opted into dry-run
  for a reason. Trust the file's presence; don't second-guess.
- **Don't escalate the same finding twice.** If `escalated_at` is
  already set, you've already pinged the user — sit on it.
- **Don't forget to remove the temp worktree.** A failed worker that
  doesn't clean up will accumulate `/tmp/orch-*` directories.
  `git worktree remove --force` in a `trap` is the disciplined way.
- **Don't squash worker commits across rounds.** Each round commit is
  an audit artifact. The user will squash on real merge if they want.
- **Don't run the worker in the daemon's tmux session's working
  directory.** Always use `git worktree add` to a temp path. Otherwise
  `gh pr checkout` switches the daemon's branch and breaks state.

- **Don't proactively `rm -rf` "stale" or "old" files. Ever.**
  Observed habit: the daemon notices old files in `/tmp/orch-*-prN/`
  from a closed PR, or stale entries under `~/.local/state/...`, and
  tries to "tidy up" with `rm -rf`. **DON'T.** An external janitor
  process handles GC — that's not your job. The ONLY `rm -rf` /
  `git worktree remove` you do per tick is the explicit one in step
  9 against your OWN current-round worktree (`$WORKTREE` =
  `/tmp/orch-<slug>-pr<N>` for the PR you JUST processed).

  Specifically forbidden, even when they look "obviously stale":
    - Other PRs' worker worktrees (`/tmp/orch-*-pr<other-N>`)
    - State dirs under `~/.local/state/claude-pr-pipeline/...`
    - `~/.claude/` (or any sibling Claude config dir the user maintains)
    - Anything that you didn't create within THIS tick

  If you genuinely think something old needs cleaning, surface it in
  the verdict_log entry as a `housekeeping_note` field and let the
  user decide. The `protect-state-from-rm.sh` hook will block most
  such attempts at the system level, but treat that as a SAFETY NET,
  not a permission to try.

## First-run setup checklist

1. Verify `pr-review-tick` is also running for the same repo (or has
   been run at least once) — Agent B without Agent A has nothing to do.
2. Verify `git worktree` is available.
3. Verify the user has merge permissions on the repo (or has set up
   admin override) — `gh pr merge --dry-run` doesn't exist; the only
   way to test is to actually attempt a merge, which is unsafe to do
   in setup. Trust the user's judgment.
4. Confirm `~/.local/state/claude-pr-pipeline/<repo>/dry_run` exists
   (create it if not). New repos should always start in dry-run.
5. Run one tick manually (don't `/loop` yet) on a real PR to verify
   the worker spawn + worktree management + verdict comment flow.
   Inspect every artifact.
6. Once the manual tick works, switch to `/loop /pr-orch-tick`.

## Termination

Same as Agent A — long-running, kill the tmux session to stop:

```bash
tmux kill-session -t <repo>-orchestrator
```

If the daemon hits a permanent error, surface it and don't re-arm.
