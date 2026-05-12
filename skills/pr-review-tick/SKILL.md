---
name: pr-review-tick
description: One review cycle of the PR review pipeline (Agent A). Designed to be invoked by `/loop /pr-review-tick` inside a long-running tmux daemon session, one per repo. Each tick discovers open PRs that have explicitly opted into the pipeline (via the `[auto PR loop]` marker in title or body), dedups against the (pr_number, head_sha) → review_id map in `~/.local/state/claude-pr-pipeline/<repo>/`, and for each opted-in PR with new content runs a three-angle review — (1) codex GPT-5.5 cross-vendor adversarial, (2) `code-reviewer-opus` user-level Opus reviewer (CLAUDE.md mandated), (3) bespoke Opus PR-coherence pass covering cross-commit / scope / test-completeness / CI / arch-fit / breaking-change angles the per-commit hook can't see — then aggregates findings, posts ONE PR comment, and re-arms via ScheduleWakeup. Sibling skill is `pr-orch-tick` (Agent B, fix + verdict). Use this whenever the user says "start the review daemon", "kick off the PR review tick", "Agent A", or `/loop /pr-review-tick`. NEVER fixes code. NEVER pushes commits. NEVER merges. Read-only against the repo; only writes are PR comments and the local state directory. Deliberately avoids `pr-review-toolkit` (Anthropic-internal-poisoned prompts) and `code-review:code-review` (5× Sonnet, downgrade vs. Opus on Max).
---

# PR review tick — Agent A of the PR review pipeline

A single review cycle. Designed to be invoked by `/loop /pr-review-tick`
inside a long-running tmux Claude Code session (one per repo). Self-paces
via `ScheduleWakeup` at the end of every tick. State persists across
ticks on disk so context loss between iterations is harmless.

## Architecture context (read once, then skip)

Two-daemon pipeline, one daemon per repo:

| Daemon | Skill | Job |
|---|---|---|
| `<repo>-review` (this) | `/pr-review-tick` | Discover open PRs → multi-expert review → post ONE comment per PR per new HEAD SHA. Read-only against the codebase. |
| `<repo>-orchestrator` | `/pr-orch-tick` | Spawn fix worker on PRs that have new review comments → triage/fix/push with `[auto N/4]` tag → verdict gate (CI/diff size/path allowlist/confidence) → dry-run comment OR real merge OR @-escalate to user. |

Both daemons coordinate through the on-disk state directory + GitHub PR
comments — no direct IPC. A per-PR `flock` ensures they don't both grab
the same PR simultaneously.

This skill is **the review half**. It MUST NOT touch the codebase, push
commits, or merge anything. If you find yourself reaching for `git push`
or `gh pr merge`, you're in the wrong skill — bail and re-read this file.

## When to use

Trigger phrases:
- `/loop /pr-review-tick` (the canonical invocation)
- "start the review daemon for this repo"
- "do one PR review tick"
- "Agent A: run a tick"
- "review any open PRs that need it"

Pre-conditions:
- `gh` CLI authenticated (`gh auth status` succeeds).
- `codex` CLI authenticated (`codex --version` works) with **a working default profile** in `~/.codex/config.toml` that points at a non-Claude reviewer (gpt-5.5 or similar). The exact profile is opaque to this skill — Azure OpenAI, OpenAI direct, GitHub Copilot Enterprise via reverse proxy, all work. If you keep multiple profiles, set `CODEX_PROFILE=<name>` in the daemon env so this skill passes `--profile $CODEX_PROFILE` to codex; otherwise codex's default profile is used.
- The user-level `code-reviewer-opus` agent exists at
  `~/.claude/agents/code-reviewer-opus.md` (CLAUDE.md mandates it).

We deliberately do NOT use:
- `pr-review-toolkit@claude-plugins-official` — its prompts are
  Anthropic-internal-codebase-poisoned (hardcoded references to
  Statsig, `constants/errorIds.ts`, internal logging helpers); they
  inject false context into non-Anthropic repos. 4 of its 6
  specialists also duplicate `code-reviewer-opus` / `simplify`.
- `code-review@claude-plugins-official` (the official `/code-review`
  skill) — it spawns 5 Sonnet sub-agents. CLAUDE.md mandates Opus
  for review work on this Max subscription; Sonnet review is a
  strict downgrade.

If any pre-condition fails, surface it to the user and **do not re-arm
the loop** — that wastes ScheduleWakeup cycles on a permanently broken
daemon.

## State

Per-repo state directory under XDG state home:

```
~/.local/state/claude-pr-pipeline/
  <owner>__<repo>/                     # e.g. octocat__hello-world
    pr-<N>/
      lock                             # flock(1) — both Agent A and B respect this
      last_reviewed_sha                # head SHA of the last review we posted
      last_reviewed_id                 # GitHub review id (returned by `gh api`)
      last_reviewed_at                 # ISO timestamp
      author_association               # OWNER | MEMBER | COLLABORATOR | CONTRIBUTOR | NONE
      last_findings.jsonl              # per-finding records, for Agent B to read
    dry_run                            # repo-scoped flag file; presence = dry-run mode (Agent B reads, Agent A ignores)
```

Resolve `<owner>__<repo>` via:

```bash
gh repo view --json owner,name -q '.owner.login + "__" + .name'
```

Use `mkdir -p` liberally. `flock -n -x` (non-blocking exclusive) — if the
lock is held by Agent B, skip this PR and try the next one in the same
tick.

## Per-tick procedure

### 1. Pre-flight

```bash
# Verify dependencies; bail (no re-arm) if missing
command -v gh codex tmux flock || { echo "[pr-review-tick] missing deps"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "[pr-review-tick] gh not auth'd"; exit 1; }

# Resolve repo identity
REPO_SLUG=$(gh repo view --json owner,name -q '.owner.login + "__" + .name')
STATE_ROOT="$HOME/.local/state/claude-pr-pipeline/$REPO_SLUG"
mkdir -p "$STATE_ROOT"
```

If you can't resolve the repo (not a git dir, no `gh` remote), surface
the error and don't re-arm — the daemon was started in the wrong cwd.

### 1.5. Wake-up channel — MANDATORY at every tick

> **YOU MUST DO THIS STEP. DO NOT PROCEED TO STEP 2 UNTIL CRON IS
> VERIFIED AT `*/2 * * * *`.** Past observation: every
> review daemon defaulted to `*/10` cron because the SKILL was advisory
> on cadence. With `*/10`, new PRs and new commits sit unreviewed for
> up to 10 minutes — slow enough that downstream Agent B is starved
> waiting for review comments. Don't be that daemon.

**Cron at `*/2 * * * *` (every 2 minutes).** Reviewers don't have a
file-based wake source like the orchestrator's `notify_orch` (the
events that should wake them — new PRs, new commits — live on GitHub).
So cron is the only channel; it must be tight.

```python
# Verify the cron job exists AND has the right interval. Wrong interval
# (e.g. */10) → DELETE and recreate at */2.
existing = CronList()
correct = False
to_delete = []
for j in existing.get("jobs", []):
    if j.get("prompt") == "/loop /pr-review-tick":
        if j.get("cron") == "*/2 * * * *":
            correct = True
        else:
            to_delete.append(j["id"])
for jid in to_delete:
    CronDelete(id=jid)
if not correct:
    CronCreate(
        cron="*/2 * * * *",        # MANDATORY: every 2 minutes
        prompt="/loop /pr-review-tick",
        recurring=True,
        durable=False,
    )
```

**`*/2`, NOT `*/5` or `*/10`.** `gh pr list` is a sub-second operation
and idle ticks just hit GitHub's API (no model calls). Cron at `*/2`
gives ~1-min worst-case latency from "new commit pushed" to "review
starts"; `*/10` makes the loop feel laggy when an author is actively
iterating. If your backend bills per request and idle ticks are
expensive in your setup, dial this up — otherwise default to `*/2`.

#### Step-1.5 verification (run before exiting)

- [ ] `CronList()` shows a `/loop /pr-review-tick` entry with
      `cron="*/2 * * * *"` (NOT `*/10`)

If failed, fix it now before going to step 2.

### 2. Discover work

```bash
gh pr list --state open --json number,title,body,headRefOid,headRefName,author,authorAssociation,isDraft \
  -q '.[] | select(.isDraft == false)'
```

Skip drafts. Skip PRs whose `headRefOid == last_reviewed_sha` in state.

#### 2a. Opt-in keyword filter — `[auto PR loop]` (MANDATORY)

> **The pipeline only touches PRs the author has explicitly opted in.**
> A PR is opted in if and only if its **title** OR the **first 500
> characters of its body** contain the case-insensitive marker
> `[auto PR loop]` (with brackets, any internal whitespace OK).
> Any PR without the marker MUST be skipped, even if Agent A has
> reviewed it in a previous tick.

Rationale: the opt-in marker is the explicit handshake from the human
author. It says: "this PR is in a clean enough state that I want
Agent A + Agent B to drive it to convergence; you have permission to
push `[auto N/4]` commits to the branch." Without that handshake, we
can't know whether the branch is being concurrently worked elsewhere,
whether the author is mid-rebase, whether the PR title/scope reflects
the actual diff, etc. Better to do nothing than to interfere.

```python
import re
OPT_IN_RE = re.compile(r"\[\s*auto\s+PR\s+loop\s*\]", re.IGNORECASE)

def is_opted_in(pr):
    """True iff `[auto PR loop]` appears in PR title OR body[:500]."""
    title = pr.get("title", "") or ""
    body  = (pr.get("body", "") or "")[:500]
    return bool(OPT_IN_RE.search(title) or OPT_IN_RE.search(body))

opted_in = [pr for pr in prs if is_opted_in(pr)]
```

If `opted_in` is empty: log how many open PRs were skipped (so daemons
remain observable in the pane) and re-arm. No review work this tick.

```python
if not opted_in:
    print(f"Tick: {len(prs)} open PR(s); 0 opted-in (no '[auto PR loop]' marker). Idle.")
    # re-arm and exit
```

**The marker is also the off switch.** If a previously opted-in PR
has its marker removed (author edited the title/body), this tick
will silently drop it from the opt-in set — Agent A stops reviewing
new commits on it, and Agent B's sibling skill will stop fixing.

Continue per-PR processing only with `opted_in`.

For each remaining PR:
- Pull `gh pr diff --name-only <N>` and apply the **docs-only fast path**:
  if every changed path matches `^(docs/|.*\.md$|.*\.lock$|uv\.lock$|.*\.txt$|CHANGELOG)`, skip and write `last_reviewed_sha` so the next tick doesn't reconsider it.
- Pull `gh pr view <N> --json files,additions,deletions` to learn the
  diff size. **Per-reviewer caps** (don't blanket-skip the whole PR — do
  the angles that fit, drop the ones that would truncate):

  | Reviewer | Cap (additions+deletions) | Why |
  |---|---|---|
  | Codex (gpt-5.5 via Copilot Enterprise, `--profile copilot`) | 5000 PER CALL, 50000 PR total via per-commit chunking | Empirically codex degrades sharply >5000 lines/call (10–20× latency, token-counter retries). For PRs >5000 lines, `--commit`-chunk by individual commit (each ≤5K). See step 4 codex sub-section for chunking logic. |
  | code-reviewer-opus (Opus 4.7 1M) | 50000 | 1M context easily fits 50k-line diffs in token-budget terms (≈ 750k tokens). Beyond 50k you start seeing real attention-dilution / hallucination. |
  | pr-coherence (Opus 4.7 1M, bespoke) | 50000 | Same envelope as code-reviewer-opus. |

  **Hard skip threshold (whole PR)**: 50000 lines. At that size every
  reviewer is degraded enough that the noise-to-signal on the resulting
  comment actively wastes the orchestrator's downstream fix budget. Post
  a comment "diff too large (>50000 lines), please request review by
  splitting the PR" and update `last_reviewed_sha`.

  **Below 50000**: run whichever angles fit their per-reviewer cap. If
  some are skipped, aggregate the rest and add a one-line note like
  "Codex pass skipped (diff > 10000 lines)" to the final comment so
  downstream Agent B knows the review is partial.

  Rationale (history): the 5000-line blanket cap dated from the 200K-
  context era. With Copilot Enterprise + Opus 4.7 1M as the routing
  default, that cap blocked PRs in the 4-15k range that
  the Claude reviewers handle just fine. Per-reviewer + much higher
  hard skip is the right model now.

Process the remaining PRs **sequentially** (even though they're
independent — interleaved review comments confuse downstream Agent B).

### 3. Acquire the per-PR lock

```bash
PR_DIR="$STATE_ROOT/pr-$N"
mkdir -p "$PR_DIR"
exec 9>"$PR_DIR/lock"
flock -n -x 9 || { echo "[pr-review-tick] PR #$N busy, skipping"; continue; }
```

If `flock -n` fails, Agent B is mid-fix on this PR; come back next tick.

### 4. Three-angle review

This is the **PR-level review**, deliberately distinct from the
commit-level `second-opinion-commit-gate.sh` hook. The hook already
reviewed each individual commit at gpt-5.5 quality; PR-level review's
job is the angles the per-commit hook can't see:

- Cross-commit logic coherence (does commit 3 break what commit 1
  established?)
- Test completeness for the *PR as a whole* (not just per-commit)
- PR description ↔ actual diff alignment (scope creep, undocumented
  side effects)
- CI / build / lint status sanity at HEAD
- Architectural fit with the surrounding modules
- Migration / breaking-change detection

Run **all three angles in parallel** (single message, two `Agent` tool
calls + one Bash call):

| Angle | How to invoke | Why |
|---|---|---|
| **Cross-vendor adversarial (GPT-5.5 or similar)** | Bash: `codex ${CODEX_PROFILE:+--profile "$CODEX_PROFILE"} review --base "$BASE"` (or `--commit <SHA>` for per-commit chunking — see below) | Genuine non-Claude signal; catches Claude blind spots. The exact backend is whatever the user's codex profile points at. |
| **General Opus review (CLAUDE.md mandated)** | `Agent(subagent_type="code-reviewer-opus", ...)` | The user-level Opus reviewer with confidence ≥ 80 filter; repo-agnostic, well-tuned |
| **PR-level coherence (bespoke Opus prompt)** | `Agent(subagent_type="general-purpose", model="opus", prompt=<below>)` | Catches the cross-commit / scope / CI angles the per-commit hook can't see |

#### Bespoke PR-coherence prompt (template)

Spawn this with `subagent_type="general-purpose"`, `model="opus"`. Substitute
`{N}`, `{REPO}`, `{BASE}`, `{HEAD_SHA}` etc. before sending.

```
You are a PR-level coherence reviewer. You are NOT doing general code
review (another agent handles that) — you focus exclusively on
angles that per-commit review can't see.

Context:
- Repo: {OWNER}/{REPO}
- PR: #{N}
- Base...Head: {BASE_SHA}..{HEAD_SHA}
- PR description (the body the author wrote): {PR_BODY}

Tools available: Bash, Read, Grep, Glob. Read-only — DO NOT modify
files.

Investigate these six angles. For each, return a list of findings or
"clean". Each finding must include: file:line (or "PR-wide"), severity
(critical/important/advisory), and a one-sentence "why it matters."

1. **Cross-commit coherence.** Walk `git log --reverse {BASE}..{HEAD}
   --oneline`. For each adjacent pair, ask: does commit N+1 undo or
   conflict with commit N? Does the final state make sense given the
   incremental story? Common red flags: commit 1 adds a function,
   commit 3 removes its only caller without removing the function
   itself; commit 2 changes a contract that commit 1's tests still
   assume; final commit accidentally reverts an earlier change.

2. **Description ↔ diff alignment.** Compare PR body to actual diff.
   Are there changes the body doesn't mention (scope creep)? Are
   there claims in the body the diff doesn't actually deliver
   (overpromise)? Pay attention to "fixes #X" claims — does the diff
   actually address the linked issue?

3. **Test completeness for the PR as a whole.** Look at the new
   non-test code as a unit. For each new public function / endpoint /
   contract introduced anywhere in the PR, is there a test exercising
   it? Per-commit review can miss this when commit A adds the function
   and commit B is supposed to add tests but doesn't. Don't demand
   100% line coverage; flag genuinely-untested new behavior only.

4. **CI / build / lint status at HEAD.** Run `gh pr checks {N}` (or
   `gh run list --branch <head_branch> --limit 10 --json status,conclusion,name`).
   Surface any failed/cancelled checks. Do NOT investigate root causes
   here; just list what's red. If all green, say so.

5. **Architectural fit.** Read 2–3 representative existing files in
   each directory the PR modifies (use Grep/Glob to find peers). Does
   the PR's new code follow the surrounding patterns (config system,
   error handling style, naming, module layout)? Flag where it
   doesn't, with a one-line "the surrounding code does X; this PR does
   Y." Do NOT flag stylistic differences that are just preference;
   flag real divergence from established repo conventions.

6. **Breaking changes / migration risk.** Search the diff for: schema
   changes, public API signature changes, default-value changes for
   user-facing config, removed-but-not-deprecated symbols, changed
   on-disk formats, env var renames. For each, note whether the PR
   includes a migration path / deprecation shim, and whether the PR
   description warns about it. If a breaking change is undocumented in
   the PR body, that's a critical finding.

Output format:

```yaml
findings:
  - angle: cross-commit-coherence  # or description-alignment / test-completeness / ci-status / arch-fit / breaking-changes
    severity: critical              # critical / important / advisory
    location: src/foo/bar.py:42     # or "PR-wide" / "commit abc1234"
    issue: <one-sentence what>
    why: <one-sentence why>
ci_summary:
  status: green | red
  failed_checks: [list of names if red]
verdict: <one-paragraph framing of whether this PR is coherent as a
         unit, beyond per-commit correctness>
```

Be terse. We want signal not narrative. If an angle is clean, skip it
in the findings list — list only real issues. Aim for ≤ 8 findings
total across all angles for a typical PR; if you have 15+, you're
probably padding.
```

The Opus PR-coherence agent gets to read the codebase (Read/Grep/Glob)
so it can ground its findings in actual surrounding code rather than
guessing. That's the main qualitative jump over codex (which sees
only the diff) and code-reviewer-opus (which is general-purpose).

#### codex invocation (PR-level) — synthetic-commit splitting for large PRs

`codex review` (codex-cli 0.129.0) supports exactly three change-
selection flags — `--uncommitted`, `--base BRANCH`, `--commit SHA`
— **and nothing else**. There is no `--commit-range`, no
`--diff-stdin`, no file-subset arg. Don't hallucinate flags; check
`codex review --help` if in doubt.

Codex itself has a large context window (hundreds of K tokens), but
our empirical cap is **5000 lines per call**: above that, codex slows
from minutes to tens of minutes (a 5040-line single call has been
observed running 16+ minutes and still generating, sometimes with
upstream tokenization errors mixed in).

So we cap codex calls at 5000 lines each. Two paths:

1. **PR diff ≤ 5000 lines** → single call, `codex review --base "$BASE"`.
2. **PR diff > 5000 lines** → split the diff into synthetic commits,
   each ≤ 5000 lines, in a temp worktree. Call codex once per
   synthetic commit. Why not "chunk by real commit"? Because a single
   real commit can easily exceed 5000 lines (PR #3 above is 1 commit
   /5040 lines). Synthetic splitting handles every shape of PR.

##### Synthetic-commit splitting (path 2)

> **DO NOT pre-judge whether synthetic splitting is "worth it" by
> file count.** Past observation: a 5040-line / 93-file
> PR was skipped on the assumption that "93 files would produce
> >MAX_CHUNKS=10 chunks". This is wrong by an order of magnitude.
> Bin-packing groups small files together; 93 files of avg ~54 lines
> typically pack into **2 bins of ~2500 lines each**, well under the
> 10-chunk cap. **Run the bin-packing algorithm first; let its output
> decide whether to skip.** Don't reason your way out of running it.

Worked example (the PR #3 case from the observation above):
- 5040 total lines, 93 files
- Bin-packing first-fit-decreasing → ~2 bins of ~2500 lines
- 2 codex calls, each ≤ 5000 lines → fast regime
- Aggregate findings into one PR comment → 2-reviewer note becomes 3-reviewer note

Algorithm (the bash below implements this exactly — don't reinvent it):
- Make a temp git worktree checked out at `$BASE_SHA`.
- Bin-pack the PR's changed files by line count into bins ≤ 5000
  lines (first-fit-decreasing). Skip binary files.
- **AFTER bin-packing**, count bins. If `nbins > MAX_CHUNKS`, THEN
  skip codex with a note. Not before.
- For each bin: reset worktree to BASE, apply the bin's file diffs,
  commit with `[skip-review]` (so `second-opinion-commit-gate.sh`
  doesn't recurse), then `codex review --commit <syn-sha>`.
- Cleanup worktree.

```bash
BASE=$(gh pr view "$N" --json baseRefName -q .baseRefName)
HEAD_SHA=$(gh pr view "$N" --json headRefOid -q .headRefOid)
BASE_SHA=$(git rev-parse "origin/$BASE")
TOTAL=$(gh pr view "$N" --json additions,deletions \
            -q '.additions + .deletions')

CHUNK_CAP=5000               # codex per-call line cap
MAX_CHUNKS=10                # bail if PR needs >10 chunks (too noisy)

CODEX_OUT="/tmp/pr-review-tick-${N}-codex.txt"
: > "$CODEX_OUT"

if [ "$TOTAL" -le "$CHUNK_CAP" ]; then
    # Path 1: single-call. --base reviews HEAD's full diff against the base branch.
    codex ${CODEX_PROFILE:+--profile "$CODEX_PROFILE"} review --base "$BASE" >> "$CODEX_OUT" 2>&1
else
    # Path 2: synthetic-commit splitting in a temp worktree.
    CHUNK_WT="/tmp/pr-review-tick-${N}-chunks"
    git worktree remove --force "$CHUNK_WT" 2>/dev/null || true
    git worktree add --detach "$CHUNK_WT" "$BASE_SHA" >/dev/null

    # Bin-pack files via Python (first-fit-decreasing).
    python3 - "$BASE_SHA" "$HEAD_SHA" "$CHUNK_CAP" > "/tmp/pr-review-tick-${N}-bins.txt" <<'PYEOF'
import subprocess, sys
base, head, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])
out = subprocess.check_output(['git', 'diff', '--numstat', f'{base}..{head}'], text=True)
files = []
for line in out.strip().splitlines():
    parts = line.split('\t')
    if len(parts) < 3: continue
    add, dele, fname = parts[0], parts[1], parts[2]
    if add == '-' or dele == '-': continue   # skip binary files
    files.append((int(add) + int(dele), fname))
files.sort(reverse=True)
bins = []   # list of (total_lines, [fnames])
for count, fname in files:
    if count > cap:
        # A single file exceeds cap. Put it alone in its own bin and
        # tag it so reviewer knows we may exceed there.
        bins.append((count, [fname]))
        continue
    placed = False
    for i, (total, fnames) in enumerate(bins):
        if total + count <= cap:
            bins[i] = (total + count, fnames + [fname])
            placed = True
            break
    if not placed:
        bins.append((count, [fname]))
for total, fnames in bins:
    print(f'{total}\t' + ' '.join(fnames))
PYEOF

    NBINS=$(wc -l < "/tmp/pr-review-tick-${N}-bins.txt")
    if [ "$NBINS" -gt "$MAX_CHUNKS" ]; then
        echo "SKIP codex: $NBINS chunks needed, exceeds MAX_CHUNKS=$MAX_CHUNKS" \
            >> "$CODEX_OUT"
    else
        echo "synthetic-commit splitting: $NBINS bins, cap=$CHUNK_CAP lines each" \
            >> "$CODEX_OUT"
        ( cd "$CHUNK_WT" && \
          while IFS=$'\t' read -r total files; do
            echo ""                                                  >> "$CODEX_OUT"
            echo "===== synthetic chunk: $total lines, files: $files =====" >> "$CODEX_OUT"
            git reset --hard "$BASE_SHA" -q 2>/dev/null
            # Apply only this bin's file diffs (handles add/modify/delete uniformly)
            git -C "$CHUNK_WT" diff "$BASE_SHA..$HEAD_SHA" -- $files | git apply --index 2>/dev/null
            git commit -m "synthetic codex chunk [skip-review]" -q --allow-empty --no-verify
            SYN_SHA=$(git rev-parse HEAD)
            codex ${CODEX_PROFILE:+--profile "$CODEX_PROFILE"} review --commit "$SYN_SHA" >> "$CODEX_OUT" 2>&1
          done < "/tmp/pr-review-tick-${N}-bins.txt"
        )
    fi

    # Cleanup worktree (don't leak tmp state).
    git worktree remove --force "$CHUNK_WT" 2>/dev/null || true
    /bin/rm -f "/tmp/pr-review-tick-${N}-bins.txt"
fi
```

> Note on `[skip-review]` in synthetic commits: the user-level
> `second-opinion-commit-gate.sh` PreToolUse hook fires on every
> `git commit`. It treats `[skip-review]` in the message as a
> bypass signal, otherwise it'd recurse into another codex review
> (≈ 60s) on each synthetic commit. The tag is mandatory here.

After all chunks complete, parse `[P0]`/`[P1]`/`[P2]` findings
across the whole `$CODEX_OUT` file (same regex as
`second-opinion-commit-gate.sh`):
`grep -E '^[[:space:]]*-[[:space:]]*\[P[0-2]\]'`. Dedupe identical
findings if a path/line range was hit by multiple chunks.

Cap rationale:
- **5000 lines/call**: codex stays in the "fast" regime. Larger
  diffs hit token-counter retries that 10x latency.
- **10 chunks/PR**: prevents runaway cost on PRs with 30+ commits.
  At 10 chunks we've covered up to 50K lines (each ≤ 5K) which is
  the same hard cap as Opus reviewers.
- **Skip individual commit** if it alone exceeds 5K. Note in the
  aggregated comment so Agent B knows that commit's review is
  partial.

If `codex review` fails (transient backend errors — rate limits, OAuth
token expiry, upstream model outage), record the failure, post the
other reviewers' findings, and note codex was skipped. If codex
consistently fails, the daemon should NOT try to restart the backend
(out of scope) — just report so the operator can investigate.

#### Specialist agent prompts

Each agent gets the SAME inputs:
- PR number, repo slug, base...head SHA range
- The diff (`gh pr diff <N>` output)
- Path to the PR description (`gh pr view <N> --json body -q .body`)
- The PR's CLAUDE.md / AGENTS.md (read from the working tree at HEAD)

And specialty-specific instructions ("focus on test completeness", etc.).

Use Opus for all of them — CLAUDE.md mandates Opus for review work and
the user is on Max. Pass `model: "opus"` to the Agent tool if the
sub-agent's frontmatter doesn't already pin it.

### 5. Aggregate and dedupe findings

The three angles return their findings. Merge them:

1. Tag each finding with its source: `codex`, `code-reviewer-opus`, or
   `pr-coherence` (the bespoke Opus pass). Show attribution in the
   PR comment.
2. Dedupe **by file:line + issue type** — two angles flagging the same
   issue is signal, not noise. Mark such findings as `[2/3 angles]`
   to give them weight; that's the adversarial-review consensus the
   per-commit hook can't compute.
3. Drop low-confidence findings:
   - codex `[P2]` findings → drop (advisory only).
   - code-reviewer-opus findings with confidence < 80 → drop (per
     that agent's own filter).
   - `pr-coherence` `advisory` severity findings → keep but bucket
     them in "Suggestions"; only `critical` and `important` go in the
     blocking buckets.

### 6. Post the review comment

One comment per tick per PR. Format:

```markdown
## PR review pipeline — Agent A round @ <HEAD_SHA short>

<one-line summary: "N findings across M reviewers" or "All clear">

<if there are findings, group by severity then by source>

### Critical (must fix)
- **[codex/P0]** `path/file.py:42` — <description>
- **[code-reviewer-opus/95]** `path/file.py:88` — <description>
- **[2/3 angles]** `path/other.py:12` — <description>
  - codex/P0: <description>
  - pr-coherence/critical: <description>

### Important
- **[pr-coherence/important]** PR-wide — <description>
- ...

### Suggestions (advisory; not blocking auto-merge)
- **[pr-coherence/advisory]** — <description>
- ...

### CI status at <HEAD_SHA short>
- <green / list of red checks from pr-coherence's ci_summary>

---
*Posted by `pr-review-tick` daemon. Angles: codex (gpt-5.5), code-reviewer-opus (Opus), pr-coherence (Opus, PR-level). cc Agent B for triage.*
```

Post via:

```bash
gh pr comment "$N" --body-file /tmp/pr-review-tick-$N.md
```

If there are zero findings, **still post a comment** but a short
"All clear at <HEAD_SHA>" — Agent B keys on the comment, not on
findings count, so a missing comment looks like the review never
happened.

### 7. Persist state

```bash
echo "$HEAD_SHA"     > "$PR_DIR/last_reviewed_sha"
echo "$REVIEW_ID"    > "$PR_DIR/last_reviewed_id"
date -Iseconds       > "$PR_DIR/last_reviewed_at"
echo "$AUTHOR_ASSOC" > "$PR_DIR/author_association"
# Write findings.jsonl for Agent B to consume
jq -c '.[]' < /tmp/pr-review-tick-$N-findings.json > "$PR_DIR/last_findings.jsonl"

# A→B fast-handoff signal (Phase 1 lightweight test).
# Touch a repo-level marker file so Agent B's next tick sees a fresh
# "A just reviewed something" hint and uses 60s cadence instead of 1200s.
# Agent B compares this file's mtime against $STATE_ROOT/last_orch_tick_at.
# If this experiment proves fix-loop latency drops meaningfully, we
# upgrade to a real daemon; if not, this whole mechanism is 1 line to
# revert here and ~5 lines in pr-orch-tick.
date -Iseconds       > "$STATE_ROOT/notify_orch"
```

Release the lock (close fd 9 by exiting the subshell or `flock -u 9`).

### 8. Re-arm

After all PRs are processed (or there were no PRs to process), call
ScheduleWakeup to come back. Cadence:

| Situation | delaySeconds | Reason |
|---|---|---|
| Found PRs to review (just did work) | 270 | stay in cache, push window often comes within 5 min |
| No PRs needed review (idle) | 1200 | save cache misses; idle is the common case |
| Pre-condition failure (gh/codex not auth'd) | n/a — DO NOT re-arm | broken daemon shouldn't keep waking up |

```python
ScheduleWakeup(
    delaySeconds=270,  # or 1200 if idle
    prompt="/loop /pr-review-tick",
    reason="next PR review tick — reviewed PR #N, idle PRs queued"
)
```

## External contributor PRs

`authorAssociation` from `gh pr view` distinguishes:

| Value | Treatment |
|---|---|
| OWNER, MEMBER, COLLABORATOR | Internal — full review, normal pipeline |
| CONTRIBUTOR, FIRST_TIME_CONTRIBUTOR, NONE, MANNEQUIN | External — review yes, but **mark the comment with an explicit "external contributor" header**. Agent B will refuse to auto-fix unless `maintainerCanModify=true` AND will refuse to auto-merge regardless of dry-run state. |

Persist `author_association` in state so Agent B can read it without
re-querying the API.

## Anti-patterns

- **Don't run reviewers sequentially.** They're independent — parallelize
  with one tool-call message containing N `Agent` calls + the codex Bash
  call. Sequential is 5× slower for no gain.
- **Don't post per-reviewer comments.** Agent B keys on "is there a new
  review comment from me on this SHA?" — multiple comments per tick
  break that. One aggregated comment per tick.
- **Don't review the same SHA twice.** That's the whole point of
  `last_reviewed_sha`. If you find yourself wanting to "do a deeper
  pass," update the skill — don't add a special-case re-review.
- **Don't review draft PRs.** They're not ready. Skip silently.
- **Don't review your own auto-fix commits with extra suspicion.**
  Agent B's commits are tagged `[auto N/4]` in the message, but they're
  still real changes — review them on their merits. The `max_rounds=4`
  cap in Agent B is what stops the loop, not pre-emptive distrust here.
- **Don't run the codex pass synchronously inside the Agent-tool call
  for code-reviewer-opus.** They go in parallel. Codex is a Bash call;
  the others are Agent calls; same message.
- **Don't proactively `rm -rf` "stale" or "old" files.** You're a
  read-only reviewer. The only writes you do are PR comments + the
  state files step 7 lists. If you notice old PR state dirs from
  closed PRs, `/tmp/orch-*` from previous orchestrator rounds,
  scratch files in `/tmp/pr-review-tick-*` from earlier ticks —
  leave them alone. An external janitor process handles cleanup.
  The `protect-state-from-rm.sh` hook will block your attempt
  anyway, but treat that as a SAFETY NET, not a permission to try.

- **Don't write to the codebase.** Not even `git fetch`. This skill is
  read-only against the working tree. The only writes are: state files
  under `~/.local/state/...` and PR comments via `gh pr comment`.

## First-run setup checklist

When the user starts the daemon for the first time on a new repo:

1. Check `gh auth status` and `codex --version`.
2. Confirm `code-reviewer-opus` agent loads (it's user-level at
   `~/.claude/agents/code-reviewer-opus.md`).
3. Confirm `~/.local/state/claude-pr-pipeline/<repo>/` is creatable.
4. Run one tick manually (don't `/loop` yet) to verify a real PR gets
   a real comment posted. Inspect the comment — does each of the three
   angles (codex / code-reviewer-opus / pr-coherence) actually appear
   with attributable findings? If one angle is silently missing,
   debug before going daemon.
5. Once the manual tick works, switch to `/loop /pr-review-tick` to
   start the daemon.

We deliberately do NOT depend on any third-party plugin for the
review angles. The skill is self-contained — `codex` CLI + the
user-level `code-reviewer-opus` agent + the bespoke Opus prompt
inlined in this skill. That makes the skill portable across machines
without a plugin-install step.

## Termination

The daemon doesn't terminate by itself — it's a long-running review
service. The user terminates by:
- `tmux kill-session -t <repo>-review` (preferred)
- Or `/cancel-loop` inside the session if the loop skill supports it
- Or just hitting Ctrl+C in the tmux session

If the daemon hits a permanent error (gh logged out, plugin missing
even after a re-check), surface the error in the tick output and
**don't re-arm** — let the daemon idle in the tmux session for the
user to inspect.
