---
name: pr-defense-loop
description: Defend a GitHub PR against automated code-review bots (Codex / chatgpt-codex-connector, Claude Code Review, etc.) by triaging each round of comments into worth-fixing / wrong-analysis / not-worth-fixing, applying fixes for the worth-fixing ones, committing, pushing to retrigger review, and looping until the bots stop raising new actionable comments. Use this whenever the user asks to "run a defense loop", "fix all the bot comments", "loop until Codex is happy", "babysit a PR through review", or anything that implies polling a PR, addressing review feedback, and pushing fixes on a cadence. Self-paces via /loop ScheduleWakeup; survives multi-bot setups; handles Codex's re-anchored false positives without chasing them forever.
---

# PR defense loop

A self-paced loop that polls a GitHub PR, triages new automated-review
comments, fixes the real ones, and re-pushes — until the bots go silent.

This skill captures a workflow refined on a real PR (#16 on a synth
pipeline repo) where Codex and Claude Code each posted multiple rounds
over ~2 hours; 13 real bugs got fixed, 5 false positives identified, 9
rounds total before Codex's review went silent. The procedure below is
the contract that worked.

## When to use

Trigger phrases:
- "do a defense PR commit loop on PR #N"
- "loop until Codex is happy"
- "triage and fix all the review bot comments on this PR"
- "babysit PR #N through automated review"
- a bare `/loop ...` invocation whose body describes the above

The user's PR must be open on GitHub and have at least one auto-review
bot installed (Codex / Claude Code Review action / similar). If the
user just opened the PR a moment ago, the first round's reviews may
not exist yet — that's fine, the loop will idle and re-check.

## Identity of the reviewers

| Bot | Posts as | Mechanism |
|---|---|---|
| ChatGPT Codex (Cloud) | `chatgpt-codex-connector[bot]` | GitHub App, NOT a workflow file; not visible in `gh run list` |
| Claude Code Review | `github-actions[bot]` (workflow runs) → posts inline review comments | GitHub Actions workflow `.github/workflows/claude-code-review.yml` using `anthropics/claude-code-action@v1`; clean run prints `No buffered inline comments` |
| Generic CI / linters | `github-actions[bot]` | Workflow file |

**Termination is gated on the bot the user names.** Default to Codex
because it's the most prolific. If the user names a different gating
reviewer, use that.

## Pre-flight: confirm the workflows can fire

A common gotcha: if the PR head branch was forked off `master` *before*
the `.github/workflows/<bot>.yml` file was added on `master`, GitHub
Actions can't see the workflow on the head and the bot never runs.
Symptom: `gh run list --branch <pr-branch>` returns `[]` even though
master has the workflow file. Fix by either merging master into the
PR branch or cherry-picking the workflow file. **Do not silently make
this change** — surface it to the user first because a merge is a
non-trivial PR mutation.

Codex (the GitHub App route) is unaffected by missing workflow files —
it works regardless. So a "Codex active, Claude Code never fires"
asymmetry is the canonical symptom of this gotcha.

## State

Use a per-PR state directory on `/tmp` so concurrent loops on different
PRs don't collide:

```
/tmp/pr<N>-loop/
  last_seen_sha                 # head SHA seen at end of last round
  last_seen_review_count        # len(/pulls/N/reviews) at end of last round
  last_seen_review_comment_count
  last_seen_issue_comment_count
  round                         # 1-based round counter
```

The state lets you (a) detect "no new reviews since last push" without
re-querying detailed bodies, and (b) restart the loop after a process
restart without losing context.

## Per-round procedure

### 1. Snapshot current state

```bash
gh pr view <N> --json headRefOid,updatedAt
gh api repos/<OWNER>/<REPO>/pulls/<N>/reviews
gh api repos/<OWNER>/<REPO>/pulls/<N>/comments     # inline review comments
gh api repos/<OWNER>/<REPO>/issues/<N>/comments    # PR-level (issue) comments
gh api repos/<OWNER>/<REPO>/issues/<N>/reactions   # bot 👀 / 👍 reactions
gh run list --repo <OWNER>/<REPO> --branch <branch> --limit 5 --json status,conclusion,event,headSha,name
```

If counts are unchanged from the saved state AND the latest review
isn't on the current head SHA, it's "still cooking" — go to step 5
without committing.

### 2. Pull only NEW comments

The set of new comments is:

- review comments whose `commit_id == <current head>` AND whose `id`
  was not seen in any prior round.

Codex re-anchors old comments to new commits when the file content
shifts. Use the comment `id` (not line number) to deduplicate. If a
comment id was seen and addressed in an earlier round, treat any
re-appearance on the new head as a re-anchored false positive (or a
stale anchor) and skip it.

### 3. Triage: (a) worth fixing / (b) wrong / (c) not worth fixing

For each NEW comment, decide a bucket and write the reasoning into the
running log. Concrete heuristics:

- **(a) worth fixing** — concrete bug with clear repro path; affects
  correctness, security, data integrity, or stated contracts; cost to
  fix is reasonable.
- **(b) wrong analysis** — bot misread the code (e.g. variable name
  collision, stale anchor, didn't see the binding above the line it
  cited). Verify by reading the code carefully — DO NOT trust the bot's
  description on its face. False positives WILL recur; track them.
- **(c) not worth fixing** — trivial nit, scope-creep, style preference
  that doesn't match the project's conventions, redundant given the
  test suite.

When in doubt between (a) and (c), lean (a). When in doubt between (a)
and (b), read the code and the test, then decide. Never silently
"address" a (b) by pretending it's real — that wastes a commit and
muddles the audit trail.

### 4. Fix the (a) bucket

Constraints:

- **Honor the repo's conventions** read from `AGENTS.md` / `CLAUDE.md`
  / `.cursorrules` / similar. Common ones: package manager (`uv add`
  vs `uv pip install`), config system (Hydra vs argparse vs YAML),
  storage discipline (where big files go), spec workflow (OpenSpec /
  similar).
- **Tests for every fix.** Add a regression test that fails before the
  fix and passes after. Pin the contract — for non-contiguous step
  ids, race conditions, signature gates, etc. — so the bot can't
  re-flag the same shape later.
- **Run the full unit suite** (skipping any group that requires extra
  deps the local env doesn't have, e.g. `--ignore=tests/rollout` if
  the rollout dependency-group isn't installed). Don't push if tests
  fail.
- **English code/comments**, even if the dialogue is in another
  language. Do NOT add emojis to code unless explicitly requested.

### 5. Commit and push (only if the round produced fixes)

One commit per round, never amend. Commit message structure:

```
fix(<scope>): address <bot> round-<N> (<short list of issues>)

<one-paragraph framing of the round and why these fixes matter
together>

1. <severity> — <file:line>: <what was wrong, what was fixed>
2. <severity> — <file:line>: <what was wrong, what was fixed>

Tests: <names of regression tests added>. Full unit suite (excl.
<excluded groups>): <N> passed.

Also: <if any (b) false positives were re-flagged, name them and
say which prior commit fixed them and which test pins the contract>.
No code change.

Co-Authored-By: <model> <noreply@anthropic.com>
```

The "Also: ... No code change." paragraph is critical when bots
re-flag the same issue: it documents that a human-in-the-loop already
considered the comment and rejected it, so future readers (and future
loop iterations) don't get confused into chasing a phantom.

After commit:
```bash
git push origin <branch>
echo <new HEAD SHA> > /tmp/pr<N>-loop/last_seen_sha
# update other counts
```

**Empty rounds are not commits.** If every comment was (b) or (c),
update state but do NOT push an empty fix commit.

### 6. Re-arm the wakeup

Self-paced via `/loop` dynamic mode. Choose a `delaySeconds` that puts
the next wake just past the slowest reviewer's typical cycle:

| Reviewer | Typical eyes→review | Suggested wake |
|---|---|---|
| Codex (chatgpt-codex-connector) | 5–8 min | 270s if first try, 480s after a slow round |
| Claude Code Review action | 8–12 min | 540s |
| Both in flight | max of the two | 540–600s |

Avoid 300s exactly (cache-miss without amortization — see
ScheduleWakeup tool docs). Re-arm at the END of every turn so the loop
keeps running.

### 7. Termination

Stop the loop when the gating reviewer (Codex by default) has been
silent for one full cycle past its typical eyes→review window after
the latest push.

Concrete check:
- Latest push was at time T.
- Gating reviewer's typical cycle is C minutes (track this from past
  rounds — early rounds calibrate it).
- At T + 1.8 × C with no new review/comment from the gating reviewer
  on the latest head SHA, declare termination.

When you terminate:
- DO NOT call `ScheduleWakeup`.
- Surface a summary to the user: rounds run, real bugs fixed, false
  positives identified, total commits, total tests added.
- Ask the user how to proceed (merge / rebase / further changes).

## Anti-patterns to avoid

- **Don't trust the bot's "Use foo not bar" prescription verbatim.**
  Read the code yourself. The bot's diagnosis can be right while its
  prescription is wrong.
- **Don't squash the round commits.** Each round commit is an audit
  artifact: which round, which bot, which comment, what changed. The
  user can squash on merge if they want.
- **Don't push partial fixes.** If a fix needs a follow-up to be
  safe, finish it within the round or don't include it.
- **Don't paper over a (b) by changing variable names or shuffling
  lines.** That just moves the bot's anchor and doesn't fix anything.
  Push back via the commit message instead.
- **Don't loop forever on re-anchored false positives.** If the same
  comment id reappears 3 rounds in a row, treat its presence as
  background noise (count it toward "no new actionable" for
  termination purposes).
- **Don't merge `master` into the PR branch silently to fetch missing
  workflow files.** Surface the gotcha and the trade-off to the user
  first; merging brings ALL of master's changes, not just `.github/`.

## Optional helpers

If the loop runs long enough that you'd benefit from a state-summary
helper, you can write a small `bash` snippet that prints
`/tmp/pr<N>-loop/*` plus the latest reviews / comments / reactions in
one go. Don't over-engineer it — `gh api` + `jq` is enough.

## Observation log from the reference run (PR #16, 9 rounds)

- Round 1: 2 P1 (snapshot SHA, client rotation race)
- Round 2: 2 P1/P2 (canonical step_id, load_dataset kwargs)
- Round 3: 1 P1 (b) + 1 P1 (a) input revalidation + 1 P2 (a) use_client TOCTOU
- Round 4: 2 (a) (normalize cache, hard-rule undercount) + 1 (b) re-anchored
- Round 5: 1 (a) skip-list+merge + 1 (b) re-anchored
- Round 6: 1 (a) screen_path resolution + 2 (b) re-anchored
- Round 7: 1 (a) merge signature gate + 2 (b) re-anchored
- Round 8: 1 (a) skip-only round bypass + 1 (b) re-anchored
- Round 9: 0 actionable (Codex silent past window) → terminate

Total: 13 real fixes, 6 regression tests added, 9 commits + 1 master
merge. Claude Code Review consistently silent (clean), so termination
was gated on Codex.

A discovered ndarray-vs-list bug (numpy parquet roundtrip silently
breaking the input-signature gate) showed up post-loop when the user
ran the code — a reminder that the bots catch a lot but not
everything. The loop is a forcing function, not a substitute for
running the code.
