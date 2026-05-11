---
name: commit-quality-pipe
description: Three-stage quality pipeline for landing commits cleanly. Runs Claude's own multi-perspective Opus review, then a `simplify` pass for reuse/quality/efficiency, then runs the Codex / gpt-5.5 second-opinion review as the final gate. Operates in two modes — **Mode A (pre-commit)** runs against a staged diff and ends with `git commit`; **Mode B (post-commit audit)** runs against already-landed commits via `codex review --commit <SHA>` and lands fixes as a follow-up commit. Trigger phrases for Mode A include "ship this commit", "do the pre-commit ritual", "make this commit ready"; Mode B triggers on "audit those commits", "did our commits go through review?", "replay the gate on the recent commits", "run quality pipe on the apply work" (i.e. anything implying retrospective check after commits already landed). Do NOT use when the hook has already blocked a fresh commit — go straight to `commit-defense-loop` for that reactive case.
---

# Commit quality pipe

A three-phase pipeline that gets work from "code is written" (or "code is committed but not yet shipped") to "commit graph is reviewed clean" with maximum first-pass cleanliness at the Codex gate.

This skill is the **proactive** sibling of `commit-defense-loop`. The defense loop is reactive — it runs after the hook has already blocked a fresh `git commit`. The pipe runs first and tries to make the hook a no-op (Mode A) OR replays the gate retrospectively over commits that already landed without ceremony (Mode B). All three modes (A, B, defense) share the same triage vocabulary ((a)/(b)/(c) buckets) and the same fix-and-retry rhythm.

## Operating modes

The pipe runs in one of two modes; pick based on context.

### Mode A — pre-commit (the original pipeline)

Triggers when:
- User explicitly asks BEFORE committing ("run the commit quality pipe", "ship this commit", "do the pre-commit ritual", "make this commit ready to land", "run a full commit-quality check before committing").
- Proactive ask before any non-trivial commit whose code the second-opinion hook would not skip.

Pre-condition: a **staged diff** exists (or the user stages one when prompted). Phase 3 ends with `git commit`, which fires the second-opinion-commit-gate.sh hook automatically.

### Mode B — post-commit retrospective audit

Triggers when:
- User explicitly asks AFTER commits landed ("did our commits go through review?", "audit the apply work", "run the quality pipe on those commits", "replay the gate on the recent commits", "review the last N commits").
- User asked to "run the commit-quality-pipe" but the staged diff is empty AND there are recent commits on the branch that warrant retrospective review (typically the branch ahead of `master` / `main`). Don't auto-pick Mode B from a generic "I want quality" ask — only when the intent is clearly retrospective.

Pre-condition: a **commit range** is identifiable (by SHA list, by `<base>..HEAD`, or by the branch's commits-ahead). Phase 3 invokes `codex review --commit <SHA>` directly per commit (mirroring what the hook does for fresh commits but post-hoc); fixes land as a single follow-up commit, NOT by amending or rebasing the audited commits (don't rewrite landed history without explicit user ACK).

Common Mode B entry point: the apply phase of an OpenSpec change committed in 3-6 stages and the user wants a final "are these clean?" check before opening a PR.

## NOT for either mode

- The hook just blocked a fresh `git commit` (Mode A's Phase 3 outcome). Hand off to `commit-defense-loop` — re-running Phase 1+2 after Codex already gated the same diff is wasted compute.
- Trivial commits the hook would skip silently (`*.md`-only, lockfile bumps, `data/`/`cache/`/`results/`-only). The pipe is overkill; just commit (Mode A) or note "all commits are hook-skipped, no audit needed" (Mode B).
- WIP-prefixed branches (`wip/*`, `explore/*`, `propose/*`). The hook skips these; if quality matters less, the pipe matters less too. Use judgment.
- Mode B on a 10 000+-line diff range. The hook caps individual commits at 5 000 lines (it skips beyond) for cost reasons; honor the same budget when picking the audit scope. Surface the size and propose splitting (e.g. "review just the §3 driver-refactor commit, not the full apply range").

## Pre-conditions

### Mode A pre-conditions (pre-commit)

1. **A staged diff exists.** Run `git diff --staged --stat` first. If it's empty, check whether the user actually meant Mode B (commits already landed and they want a retrospective audit) — that's a different pre-condition set, see below. Otherwise ask what they want staged before continuing — don't infer from the working tree, that turns into scope creep.
2. **Working-tree changes that aren't staged are surfaced, not silently included.** If `git status --short` shows unstaged modifications, tell the user: "you have unstaged changes in {files}; the pipe reviews ONLY the staged diff. Stage them first if they should be in this commit." Then wait or proceed per their answer.
3. **Repo conventions are read.** Open `CLAUDE.md` and `AGENTS.md` at the repo root, plus any directory-level `CLAUDE.md` files in the diffed paths, plus any `openspec/specs/` referenced by the change. The reviewers will need these.

### Mode B pre-conditions (post-commit audit)

1. **A commit range is identified.** Three common shapes — pick what matches the user's intent:
   - **Commits-ahead range**: `git rev-list --reverse master..HEAD` (or substitute `main` / appropriate base). Standard when the user asks "audit the work on this branch". Show the user the resolved SHA list before proceeding.
   - **Explicit SHA list**: user names the commits ("audit `a8096c7`, `7ced03f`, `fb8b17d`, `8450862`").
   - **Last-N**: `git log --format=%H -N HEAD`. Use only when the user is explicit about N; don't guess.
2. **Working tree is clean** (`git status --short` empty). If not, surface the unstaged changes — Mode B's Phase 2 simplify would otherwise pollute the audit (the simplify pass uses the working tree as its scratchpad). Either commit/stash the unstaged work or skip Phase 2.
3. **No in-progress rebase / merge / cherry-pick** (`git status` clean of those markers). Same reasoning as the hook's filter — don't audit during history rewrites.
4. **Repo conventions are read.** Same as Mode A.
5. **Each commit in scope passes the hook's substantive-change filter.** A commit that's `*.md`-only, lockfile-only, or `data/`/`cache/`-only would have been hook-skipped on its way in; Phase 3 will skip it here too. Surface the filtered list ("auditing 4 of 5 commits — `ca93046` is markdown-only and would have been hook-skipped").

## Phase 1: internal multi-perspective review

**Goal**: catch bugs / convention violations / DRY problems that Claude can see in its own diff before the Codex gate does.

**Input by mode**:

| Mode | Diff source |
|---|---|
| Mode A | `git diff --staged` |
| Mode B | `git diff <base>..HEAD` (the cumulative range diff, NOT per-commit). Cumulative is preferred for Mode B because cross-commit issues (e.g. "§3 setup conflicts with §5 use") surface at the unified-view level; per-commit review here is redundant with Phase 3. |

**Action**: launch **3 parallel `code-reviewer-opus` subagents**, each with a different focus, all looking at the same diff. Always Opus; never substitute Sonnet — see the user's policy in `~/.claude/agents/code-reviewer-opus.md`.

The three agents (use exactly this division of labor; don't add more):

| Agent | Focus | Prompt seed |
|---|---|---|
| **A — Conventions** | Project-rule adherence | "Review the diff against the repo's CLAUDE.md / AGENTS.md / OpenSpec specs. Flag explicit-rule violations (uv vs pip, Hydra vs raw YAML, storage discipline, English code, no emojis, OpenSpec workflow). Confidence ≥ 80." |
| **B — Bugs** | Logic / correctness / contracts | "Review the diff for actual bugs: logic errors, off-by-one, null/undefined handling, race conditions, broken contracts vs docstrings, security holes, error-path gaps. Confidence ≥ 80." |
| **C — Quality** | DRY / abstractions / readability | "Review the diff for code-quality issues: duplication, leaky abstractions, dead code, misleading names, missing regression tests for the new behavior. Confidence ≥ 80." |

Brief each agent in plain English — no formal schema — but include:
- The diff (paste short ones inline; for big diffs save to `/tmp/<scope>_diff.txt` and pass the path)
- The relevant CLAUDE.md / AGENTS.md content
- The instruction to return findings in the `[severity] file:line — claim` format that downstream triage expects
- For Mode B: include the SHA range so reviewers can attribute findings to specific commits if useful (helps Phase 3 triage know which commit "owns" each finding)

**Triage** (same buckets as `commit-defense-loop`):

| Bucket | Meaning | Action in this phase |
|---|---|---|
| **(a) worth fixing** | Concrete bug / clear convention violation / real DRY problem | Fix, re-stage |
| **(b) wrong analysis** | Reviewer hallucinated or misread the diff context | Note in pipe log, do not fix, do not push back yet (that's Phase 3's job if Codex repeats it) |
| **(c) not worth fixing** | Style nit, scope creep, low-impact suggestion | Note and move on |

Internal reviewers are same-family (all Claude/Opus) so (b) and (c) will be more common here than at the Codex stage. Don't churn — be willing to discard low-value findings.

**Loop**: at most 2 rounds. Round 1 reviews the original diff. If round 1 produced any (a) fixes, run round 2 on the new staged diff. Stop when:
- Round 2 produced 0 (a) findings, OR
- 2 rounds done regardless of result (don't enter round 3 — same-family reviewers have diminishing returns past 2 cycles).

**Phase 1 budget**: ~3–5 minutes total (3 Opus agents in parallel, 2 rounds max). If a round runs longer the diff is unusually large — surface that and consider splitting the commit before going further.

**Anti-patterns in Phase 1**:
- Don't expand scope. Phase 1 fixes only target the (a) findings; drive-by edits muddy the audit trail and create new findings for round 2.
- Don't run Phase 1 if the diff has obvious uncommitted experimental code the user didn't mean to include. Surface it.
- Don't skip reading CLAUDE.md / AGENTS.md before launching agents — without project context Agent A produces noise.

## Phase 2: simplify pass

**Goal**: improve reuse, quality, and efficiency of the (now-bug-free) diff.

**Action**: invoke the `simplify` skill once on the diff. Treat its output as **suggestions, not mandates**.

**Where fixes land by mode**:

| Mode | Fix landing |
|---|---|
| Mode A | Edit staged files in working tree, `git add` them back to staging. Phase 3's `git commit` picks them up. |
| Mode B | Edit working-tree files. Don't commit yet; the consolidated fix-up commit happens at the end of Phase 3 (so Phase 1 + Phase 2 + Phase 3 fixes all land in ONE follow-up). |

**Constraints on what to apply** (both modes):
- **Stay within the diff's footprint.** If simplify wants to refactor a file outside the audited set, decline — that's scope creep and will produce new Codex findings on unrelated code.
- **Don't silently change behavior.** Simplify's "this could be one line" rewrites occasionally lose edge-case handling. Re-read each refactor against the original logic before accepting.
- **Don't undo Phase 1 fixes.** If simplify suggests a refactor that conflicts with a fix you just applied, the fix wins — Phase 1 was bug-driven, simplify is aesthetic-driven.
- **Mode B only — don't rewrite history.** If simplify proposes a change that's most naturally an amend / rebase of a specific historical commit, decline. Mode B's contract is "fixes go forward as a new commit, audited commits stay as-is". History rewrites need explicit user ACK.

**Order matters**: simplify runs AFTER Phase 1, not before or interleaved. Refactoring code with bugs in it just relocates the bugs, and Phase 1's reviewers anchor to line numbers — running simplify mid-Phase-1 will re-anchor every pending finding.

If simplify produces no actionable changes, that's a fine outcome — proceed to Phase 3.

## Phase 3: Codex gate

### Mode A — `git commit` triggers the hook

**Action**: run `git commit -m "<message>"`.

Two outcomes:

1. **Hook exit 0** — commit landed clean. Pipe terminates. Surface to user:
   - Phase 1 round count and number of (a) fixes applied
   - Whether Phase 2 made changes (yes/no, and a one-line summary if yes)
   - Confirmation that the second-opinion hook approved the commit
   - The new HEAD SHA

2. **Hook exit 2** — `=== second-opinion BLOCKING ===` with [P0] findings. **Hand off to `commit-defense-loop`'s per-attempt procedure verbatim**. Do NOT re-implement that loop here. Read `~/.claude/skills/commit-defense-loop/SKILL.md` if you haven't already; its triage rules, fix constraints, re-flag handling, and termination conditions all apply unchanged.

   Important calibration: if Codex finds (a)-bucket P0s after Phases 1+2 ran clean, that's signal worth preserving. Note in the round-1 commit-defense fix what the Phase 1 reviewers missed and why (e.g., "Phase 1 reviewers didn't see this race because they didn't trace the caller; Codex's diff-only view caught the contract mismatch").

**Don't loop Phase 3 back to Phase 1.** If the defense loop gets stuck (3 rounds with same P0 unresolved), follow commit-defense-loop's escalation path (skip-review with documented reasoning, or surface to user). Restarting Phase 1 won't unstick a finding that's already at the Codex stage — it just burns more time.

### Mode B — manual `codex review --commit` replay per commit

**Action**: for each commit in the audit range (filtered by the hook's substantive-change rule per Pre-condition #5), invoke the same review the hook would have done, but post-hoc:

```bash
# Mirror the hook's invocation verbatim (see <repo>/.claude/hooks/second-opinion-commit-gate.sh).
# Run in parallel for the audit range — Azure flex tier handles concurrent calls
# and total wall time is bounded by the slowest commit (~3-5 min each).
timeout 600 codex review --commit <SHA> \
    -c sandbox_mode='"read-only"' \
    -c model='"gpt-5.5"' \
    -c model_provider='"azure"' \
    -c model_reasoning_effort='"high"' \
    -c service_tier='"flex"' \
    -c model_providers.azure.base_url='"https://oaidr5.openai.azure.com/openai/v1"' \
    > /tmp/codex_review_<SHA>.txt 2>&1
```

Save each commit's output to a stable per-SHA path so you can reference it during triage. **Run the calls in parallel** (background tasks); serial would multiply wall time by N.

**Output parsing**: the same `[P0]/[P1]/[P2]` finding format the hook parses. Triage each finding into (a)/(b)/(c) buckets — same vocabulary as Mode A and `commit-defense-loop`.

**Mode B specifics**:

- **Post-hoc gate ≠ blocking**. The hook would have blocked a fresh commit on P0; here the commits already landed, so "the hook would have blocked" is a finding for the follow-up commit, not a re-trigger. Treat any P0/P1 (a) findings as worth fixing in the consolidated follow-up; treat (b) wrong-analysis and (c) not-worth-fixing the same way Mode A would.
- **Cross-commit findings**. A finding can target one specific commit ("§3 driver refactor introduced X") OR the cumulative state ("after all commits, X is true"). Both are valid; record which case in the follow-up commit message.
- **Don't `[skip-review]` post-hoc.** That's a commit-message construct that the hook reads pre-commit. In Mode B there's no commit-message channel back to the gate — `(b) wrong analysis` findings get documented in the follow-up commit body and that's the audit trail.
- **No defense loop.** Mode A's defense-loop handoff doesn't apply here; the gate isn't blocking anything. If a finding seems wrong, document why in the follow-up commit; don't loop.

**Apply fixes as ONE consolidated follow-up commit** at the end of Phase 3. Combine:
- (a) findings from Phase 1 (Mode B's reviewers)
- (a) actionable suggestions from Phase 2 simplify
- (a) findings from Phase 3 codex review per commit

Commit message structure for the follow-up:

```
fix(<scope>): codex-review findings on <SHA range or list>

Manually replayed the second-opinion gate via `codex review --commit`
on each commit in <range>. Triage:

  <SHA1> (<one-line description>):  N P0, N P1, N P2 — <action>
  <SHA2> ...
  ...

P1 — <finding>: <fix description>
P2 — <finding>: <fix description>
[regression tests added: ...]

<test pass count>
```

Surface to user at end:
- The full triage table (which commit had what findings)
- What was fixed vs deferred (with reasons)
- The follow-up commit SHA
- Whether all audited commits are now "as if they had passed the gate" or not

### Phase 3 anti-patterns (both modes)

- **Skipping Phase 3 because Phase 1 looked clean.** The gate is deliberately a different model family (gpt-5.5 vs Claude/Opus) precisely to catch Claude's blind spots. Phase 1 + Phase 2 are not a substitute. Always run the gate (commit in Mode A; per-commit codex review in Mode B).
- **Mode B: rewriting history to "pretend the hook ran".** Don't `git rebase -i` to amend each historical commit with its own gate-clean state. The audit trail is "these N commits + 1 follow-up fix commit"; preserving that history is the point of Mode B vs Mode A.
- **Mode B: only reviewing HEAD.** If the user asked for a multi-commit audit, review ALL commits in the range, not just the most recent. Findings concentrated in mid-range commits ("§3 introduced the bug, §5 incidentally exercised it") would be invisible if you only reviewed HEAD.

## Termination of the pipe

### Mode A end states

| End state | Meaning | Surface to user |
|---|---|---|
| **Clean commit** | Phase 3 hook exit 0 on first attempt | Round counts, fixes per phase, HEAD SHA |
| **Clean after defense** | Phase 3 entered defense loop, eventually landed clean | Phase 1/2 summary + commit-defense-loop's own termination summary |
| **Skip-reviewed false positive** | Phase 3 defense loop confirmed (b), pushed back via `[skip-review]` | Why it was a false positive + the audit-trail commit message |
| **User abort** | User stopped the pipe at any phase | What was/wasn't fixed; current staged state |
| **Stuck escalation** | Defense loop hit 3-round limit with unresolved P0 | Same as commit-defense-loop's escalation contract — ask the user |

### Mode B end states

| End state | Meaning | Surface to user |
|---|---|---|
| **Clean audit** | All commits in range produced 0 (a) findings; no follow-up commit needed | Per-commit triage table with all "0 P0/P1, N P2 (skipped)" rows; "as if these had passed the gate" attestation |
| **Audit + follow-up** | At least one (a) finding; consolidated fix-up commit landed | Per-commit triage table; follow-up commit SHA; what was fixed and what was deferred-with-reason |
| **Audit found unfixable issues** | (a) findings exist but the fix would require history rewrite OR exceeds the audit's working-tree footprint | List the deferred findings with rationale; surface to user for explicit "rewrite history" or "leave as-is" decision |
| **User abort** | User stopped the pipe at any phase | What was reviewed, what (if any) fixes are in the working tree, current branch state |
| **Hook would have skipped everything** | Every commit in range is `*.md`-only / hook-skipped per Pre-condition #5 | Note that no Phase 3 work was needed; Phase 1+2 may still produce findings worth a follow-up |

## Anti-patterns

- **Skipping Phase 3 because Phase 1 looked clean.** The hook is deliberately a different model family (gpt-5.5 vs Claude/Opus) precisely to catch Claude's blind spots. Phase 1 + Phase 2 are not a substitute. Always run the commit.
- **Looping Phase 1 forever to chase reviewer findings.** Same-family reviewers asymptote fast. 2 rounds, hard cap.
- **Letting Phase 2 expand scope.** If simplify wants to refactor 3 files outside the staged set, that's a separate commit; don't smuggle it in.
- **Re-implementing the defense loop in Phase 3.** Read `commit-defense-loop/SKILL.md` and follow it. The audit-trail conventions and the `[skip-review]` rules there are deliberately consistent across both skills.
- **Running the pipe on hook-skipped diffs.** `*.md`-only, lockfile-only, `data/`-only — the hook would have skipped these silently anyway, so Phase 3 is a no-op. Phases 1+2 are still real work but rarely worth the time on these. Use judgment.
- **Reflex `[skip-review]` to bypass Phase 3.** The whole point of running the pipe is to land the commit cleanly. If you find yourself wanting to skip-review at Phase 3, re-read the finding — that's the moment commit-defense-loop's contract kicks in.
- **Mixing Phase 1 (b) findings into Phase 3 commit messages.** If Phase 1 had a (b), it stays in your scratch log. Only push back via commit message when Codex repeats the same finding in Phase 3 — that's where the `Re: [P0] ...` paragraph belongs.

## Phase ordering rationale

The order Phase 1 → Phase 2 → Phase 3 is not interchangeable:

1. **Bugs before refactor.** Phase 2's simplify can rewrite or relocate code; doing it before Phase 1 means the reviewers look at code the user didn't write and will produce findings against the simplified version, which obscures whether the original was buggy.
2. **Internal review before external.** Phase 1 is cheap (one turn, sub-agents), Phase 3 is expensive (~60–180 s of Codex compute per attempt). Front-loading the cheap review reduces the number of expensive rounds.
3. **Hook is last because it's the contract gate.** The hook runs at `git commit`. There's no way to "preview" it without committing (well — there's `/second-opinion` for ad-hoc review, but it's not a replacement for the hook's gating semantics). So the hook always sits at the end of the pipe by construction.

## Cost & latency budget

### Mode A (pre-commit)

| Phase | Typical wall time | Compute |
|---|---|---|
| Phase 1, round 1 | ~60–120 s | 3 parallel Opus reviewers |
| Phase 1, round 2 (if needed) | ~60–120 s | same |
| Phase 1 fixes | variable, ~30 s/fix | inline edits |
| Phase 2 simplify | ~30–60 s | 1 simplify call |
| Phase 3 hook (per attempt) | ~60–180 s | 1 codex review (gpt-5.5) |
| Phase 3 defense rounds | up to 3 × 60–180 s | as commit-defense-loop |

Worst case: ~10–15 minutes. Best case (Phase 1 round 1 clean, Phase 2 no-op, Phase 3 first-try pass): ~2–3 minutes. Most realistic: 4–6 minutes.

### Mode B (post-commit audit)

| Phase | Typical wall time | Compute |
|---|---|---|
| Phase 1 (single round, cumulative diff) | ~60–180 s | 3 parallel Opus reviewers; cumulative diffs are larger so closer to the upper bound. Round 2 is rarely needed in Mode B because there's no live commit gate to satisfy on this turn — defer round-2 issues to the follow-up commit. |
| Phase 2 simplify | ~30–60 s | 1 simplify call |
| Phase 3 codex review per commit (parallel) | bounded by slowest commit ~60–300 s | N parallel `codex review --commit` calls; Azure flex tier handles concurrent. Total wall time ≈ max(per-commit time), NOT N × per-commit. |
| Phase 3 fix-up commit | one Mode A pass on the consolidated fixes | which itself takes ~2-6 min (the follow-up commit must land cleanly through Mode A's gate) |

Realistic budget for a typical 3-5 commit apply audit: ~10-15 minutes total (Phases 1+2 ~3-5 min, Phase 3 codex review ~5 min in parallel, follow-up commit ~3-5 min through Mode A).

Worst case (8-commit audit, multiple P1 fixes, follow-up needs defense-loop rounds): ~25-30 minutes.

### Common to both modes

If the user is watching, narrate phase transitions. Long silent stretches feel broken even when they're working. In Mode B specifically, narrate:
- The resolved commit list before Phase 1 starts
- Per-commit Phase 3 results as they come in (notifications via `run_in_background: true` work well for this)
- The triage table before applying any fixes — give the user a chance to ACK or ABORT before history grows

## Worked example: Mode B on an OpenSpec apply phase

Reference for the canonical Mode B trigger — an apply phase committed in 4 commits without ceremony, user wants a final "did these go through review?" check before opening a PR.

**Setup**:
```
$ git log --oneline master..HEAD
8450862 apply(multi-env §9.1): simplify-pass cleanup
fb8b17d apply(multi-env §5-§9): RL hooks + smoke/soak + docs + validate
7ced03f apply(multi-env §3+§4): driver refactor + failure-mode tests
a8096c7 apply(multi-env §1+§2): schema lift + EnvPool primitives
ca93046 propose(openspec): pipeline-b-multi-env-concurrency  ← markdown-only, hook-skipped
```

**Phase 1**: 3 Opus reviewers on `git diff master..HEAD` (cumulative ~4400 LoC). Found 1 P1 + 4 P2; 5 fixed worth-fixing.

**Phase 2**: simplify pass on the working tree (touching only files in the audited set). Extracted `link.atomic_write_json`, eliminated `_make_agent_for_slot` lookup via `EnvSlot.vllm_config` cache. Applied as working-tree edits.

**Phase 3**: 4 parallel `codex review --commit <SHA>` calls (skipping `ca93046` per Pre-condition #5):

| Commit | Findings | Action |
|---|---|---|
| `a8096c7` | 0 P0 / 0 P1 / 2 P2 | Skipped — both "incomplete-state-pending-next-commit", resolved by `7ced03f` |
| `7ced03f` | 0 P0 / **1 P1** / 0 P2 | **Fixed** — agent reuse bug (fresh agent per task → AttributeError on second-task `done()`) |
| `fb8b17d` | 0 P0 / 0 P1 / 3 P2 | **Fixed** — bash array `${arr[@]:-default}` UNSET-path bug × 2; smoke validation only iterating one task |
| `8450862` | 0 findings | Clean |

**Follow-up commit**: `e4f35b2 fix(multi-env): codex-review findings on 7ced03f + fb8b17d` consolidated all worth-fixing findings (1 P1 + 3 P2 + 1 regression test). 148/148 tests pass.

**End state**: "Audit + follow-up" — all 4 audited commits would have passed the gate (0 P0 each); P1/P2 findings landed forward as a clean fix-up commit; history not rewritten.

Took ~25 minutes wall-clock end-to-end (Phase 1: ~5 min; Phase 2: included in §9.1 already; Phase 3 codex review parallel: ~5 min for slowest; fixes + follow-up commit: ~15 min including regression test).

## Related

- `~/.claude/skills/commit-defense-loop/SKILL.md` — Mode A's Phase 3 reactive sibling. Read it before running the pipe; Mode A's Phase 3 delegates to it verbatim. NOT used in Mode B (no live commit gate to defend).
- `~/.claude/agents/code-reviewer-opus.md` — the Opus reviewer subagent invoked in Phase 1, **and the user's default review agent across all workflows**. If a future iteration of this skill (or any other) wants to spawn a code reviewer, this is the one to call. Do not substitute the Sonnet `feature-dev:code-reviewer` for review work — the user is on Claude Max and considers Sonnet review a strict downgrade with no budget upside.
- `~/.claude/skills/pr-defense-loop/SKILL.md` — the PR-level multi-bot defense loop, deprecated since the user cancelled the Codex GitHub App subscription (see `~/.claude/CLAUDE.md`). Mentioned only for orientation; do not invoke.
- The hook script: `<repo>/.claude/hooks/second-opinion-commit-gate.sh` — read once if you've never seen it. Mode A's Phase 3 parses its exit 0/1/2 + stderr format; Mode B's Phase 3 mirrors its `codex review --commit` invocation verbatim (same flags, same model, same profile) so post-hoc audit semantics match what the hook would have produced live.
