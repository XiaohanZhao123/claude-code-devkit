---
name: commit-defense-loop
description: Defend a `git commit` blocked by the `second-opinion-commit-gate.sh` Claude Code hook (a non-Claude `codex review` on the staged diff). Triage each `[P0]` finding into worth-fixing / wrong-analysis / not-worth-fixing, fix the real ones with regression tests, retry the commit, and loop until it lands clean or you push back via `[skip-review]` with documented reasoning. Use this whenever the user asks to "run a commit defense loop", "fix the second-opinion findings", "address the P0s and retry the commit", "babysit this commit through the gate", "make the hook happy", or whenever a `git commit` tool call fails with `=== second-opinion BLOCKING ===` in stderr — even if the user doesn't name the skill, this is the workflow that turns hook output into real fixes instead of reflexive `[skip-review]` dismissals. Sibling to `pr-defense-loop` but tighter (single turn, no ScheduleWakeup, no /tmp state) because each iteration costs ~60s of hook latency, not minutes of waiting on external bots.
---

# Commit defense loop

A tight in-turn loop that retries a `git commit` blocked by the
`second-opinion-commit-gate.sh` Claude Code hook. Each iteration:
commit, parse findings, triage, fix the real ones, retry — until the
commit lands clean or you skip-review a confirmed false positive
with documented reasoning.

This skill is the per-commit sibling of `pr-defense-loop`. The shape
is the same (triage into a/b/c, fix the a's, push back on b's, loop
until quiet), but the cadence is much tighter — one Bash tool call
per retry, ~50–70 s of hook compute each time, all within a single
turn. No `ScheduleWakeup`, no `/tmp` state directory.

## When to use

Trigger phrases:
- "run a commit defense loop"
- "fix all the second-opinion findings"
- "address the P0s and retry the commit"
- "babysit this commit through the hook"
- "make the second-opinion gate happy"
- "the commit got blocked, work through the findings"

Pre-conditions:
- The repo has `.claude/hooks/second-opinion-commit-gate.sh`
  registered as a `PreToolUse / Bash` hook in `.claude/settings.json`
  (project-local) or `~/.claude/settings.json` (global).
- `codex` CLI is on PATH and authenticated. The hook calls
  `codex review --uncommitted`; if your `~/.codex/config.toml` defines
  multiple profiles, the hook honors `CODEX_PROFILE` env (else it uses
  codex's default profile).

If `codex` is missing the hook silently exits 0 and there's
nothing to defend against — surface that to the user instead of
looping.

If you find yourself retrying a commit by reflexively adding
`[skip-review]` without reading the findings — STOP. That's exactly
the failure mode this skill exists to prevent. The hook spent ~60s
of model compute giving you an anti-bias second opinion; throwing
it away unread defeats the whole point.

## How the hook talks to you

Read `.claude/hooks/second-opinion-commit-gate.sh` once if you've
never seen it; the contract is small.

| Hook exit | Meaning | Where stderr goes |
|---|---|---|
| 0 | Skip rule matched OR all 3 specialists said `LGTM` | Suppressed |
| 1 | P1-only or malformed-output round (advisory) | Shown to user, NOT to you |
| 2 | At least one `[P0]` finding (default blocking) | Shown to YOU and blocks the tool call |

You only enter this loop on **exit 2**. On exit 1 the commit already
landed — there's nothing to defend.

**Stderr format** when blocking:

```
=== second-opinion BLOCKING (P0 found; address or add [skip-review] to retry) ===
[P0] path/to/file.py:123 — short sentence describing the issue
[P0] other/file.py:45 — another short sentence
[P1] path/to/file.py:200 — lower-severity finding
=== suppress: [skip-review] in msg, SKIP_SECOND_OPINION=1, or SECOND_OPINION_ADVISORY=1 ===
```

Findings are deduped by the `[P_] file:line` prefix across the 3
specialists (correctness → concurrency → contract). Severity
definitions, per the prompts the hook ships:

- **P0** — "if real, will cause incorrect runtime behavior (crash,
  data loss/corruption, race that affects correctness, security
  hole, broken contract)." Specialists are explicitly told to mark
  P0 confidently even with diff-only context.
- **P1** — "likely problem but plausibly intentional, or a smell
  with a real-world workaround." P1 alone won't block.

The specialists see ONLY the diff, no codebase. That's the source
of most false positives: they can't see that a function exists
elsewhere in the repo, or that a value is validated upstream.

## Per-attempt procedure

### 1. Read each finding carefully

Each line is `[P_] file:line — one sentence`. The sentence is
intentionally terse — don't infer beyond what it literally says.
Open the cited file at the cited line and read ~20 lines of context
before deciding the bucket. Diff-only review hallucinates regularly;
your full-codebase view is the tiebreaker.

### 2. Triage into (a) / (b) / (c)

| Bucket | Meaning | Action |
|---|---|---|
| **(a) worth fixing** | Concrete bug at the cited location, clear repro path, affects correctness / security / stated contracts | Fix in this round |
| **(b) wrong analysis** | Specialist hallucinated or misread the diff | Push back via commit message, eventually `[skip-review]` |
| **(c) not worth fixing** | Bubbled-up nit that didn't deserve P0; style preference; scope creep; redundant with existing tests | Note and move on |

Common (b) patterns to recognize:

- Cites a line in the deleted block (`-` prefix in the diff), not
  actually present in the new code.
- Claims "function X is undefined" — but X is defined elsewhere in
  the repo; the specialist only saw the diff.
- Flags an "unvalidated input" that's actually validated by a
  caller above the diff window.
- Reads a method name out of context and assumes the wrong contract
  (e.g. flags `parse()` as untrusted-input handling when the input
  is a CLI arg gated upstream).
- Flags caching/race issues on values that are immutable in
  practice but the specialist can't see the construction site.

When in doubt between (a) and (b), open the file. When in doubt
between (a) and (c), lean (a) — the specialist confidently called
this P0; that earns one more careful read before dismissal.

### 3. Fix the (a) bucket

- **Honor the repo's conventions.** Read `CLAUDE.md`, `AGENTS.md`,
  OpenSpec specs in `openspec/specs/`, package manager rules
  (`uv add` vs `pip install`), config system (Hydra / argparse /
  YAML), storage discipline (where big artifacts live).
- **Add a regression test where applicable.** If the (a) is in code
  with an existing test file, write a test that fails before the
  fix and passes after. For one-line typo fixes in scripts without
  any test infrastructure, a test isn't worth manufacturing —
  judgment call.
- **Don't change unrelated lines.** A defense-loop iteration should
  fix exactly what the findings called out, plus tests. Drive-by
  refactors muddy the audit trail and risk introducing new P0s on
  the next attempt — which extends the loop and burns hook minutes.
- **English code/comments**, even if the dialogue with the user is
  in another language. No emojis in code unless explicitly asked.

### 3.5. Run tests for affected modules

Before re-staging, run the test suite for the modules you touched.
**The hook only re-reviews the staged diff — it doesn't run tests
and can't catch regressions in code paths it didn't see.** A fix
that closes the P0 finding but breaks an unrelated test will land
clean through the hook and surface as a CI failure / next-PR Codex
finding much later. Catch it now.

Minimum bar:

- For each module you edited under `src/` (or repo equivalent),
  run its corresponding test file with fail-fast:
  `uv run pytest tests/<corresponding-path> -x` (Python),
  `npm test -- <pattern>` (Node), `cargo test <module>` (Rust),
  `go test ./<pkg>/...` (Go). Read the repo's CLAUDE.md / AGENTS.md
  to find the canonical command — don't guess.
- If your diff touches >3 modules or you can't tell which tests
  cover the change, run the full unit suite:
  `uv run pytest -x --ignore=tests/<heavy-groups>`. Skip groups that
  require deps not installed locally (e.g. rollout, gpu, e2e).
- **For heavy / E2E suites** (>2 min runtime OR very heavy stdout):
  this skill runs at the top level, so `Agent` is available — spawn
  a `general-purpose` sub-agent so the test log stays out of your
  context:

  ```python
  Agent(
      description="run E2E for fix verification",
      subagent_type="general-purpose",
      prompt="""
      cd <repo>. The current commit-defense round just applied a fix
      to <file:line>. Verify the fix didn't break the E2E pipeline.

      1. Read CLAUDE.md / AGENTS.md to find the canonical E2E /
         smoke command (e.g. `uv run python -m <pkg>.pipe smoke`
         or `npm run e2e`).
      2. Run it. Capture stdout / stderr.
      3. Report ONLY:
         {"e2e_pass": bool, "command": "<cmd>",
          "first_failure": "<None if pass, else first ~30 lines of
                            failure trace>",
          "duration_sec": int}
      4. DO NOT modify code. DO NOT explore the repo beyond reading
         CLAUDE.md / AGENTS.md to locate the command.
      """
  )
  ```

  Read the sub-agent's verdict and act accordingly.

- If unit tests fail: fix until green BEFORE re-staging. Don't pretend
  the hook will catch it — it won't. The fix may be in the same commit
  if it's a direct consequence of the original change; otherwise stage
  the fix in a follow-up commit after this one lands.
- If a test failure is genuinely unrelated (pre-existing flake, env
  issue): add a one-line note to the commit message body:
  `Pre-existing flake: <test name>, unrelated to this fix.`
  Don't silently ignore failures.

### 4. Re-stage and retry

```bash
git add <files-you-changed>
git commit -m "<original message>"
```

Do NOT add `[skip-review]` here. You want the hook to validate that
your fix actually closed the finding. If it lands clean — loop
terminates, log the round count and the fixes for the user.

### 5. Handle re-flags

If the same `[P_] file:line` (or near-identical) reappears on the
retry, two possibilities:

1. **Your fix didn't actually address the diagnosis.** Re-read the
   finding text and your diff. The specialist anchors to the line
   number; if your fix shifted lines, the finding may have
   re-anchored to the new location of the same problem. Fix again.
2. **Confirmed (b), re-anchored.** Same diagnosis, you already
   verified it's wrong. Specialist is repeating itself.

For (2), push back in the commit message and skip-review:

```
<original commit subject>

<original commit body if any>

Re: [P0] path:line — <specialist's claim>: false positive.
<one-sentence explanation citing the actual code path that makes
this a non-issue>. Considered in defense-loop round <N>; rejecting
to bypass the gate.

[skip-review]
```

The `[skip-review]` marker bypasses the hook on this commit. The
explanation makes the rejection auditable in `git log` for future
readers (including future loop iterations and humans reviewing the
PR). This is the same pattern `pr-defense-loop` uses with
"Also: ... No code change." paragraphs — the audit trail is the
whole reason the override is OK.

### 6. Termination

Stop the loop on any of:

- **Commit lands clean.** Hook exit 0, no findings, the commit
  shows up in `git log`. Surface the round count and (a) fixes.
- **You skip-reviewed a confirmed (b).** Logged in the commit
  message; user can audit later.
- **3 attempts with no progress.** If you've fixed and retried 3
  times and the same P0s keep coming back with the same diagnosis,
  AND you've verified each is genuinely (a) (not (b)), stop.
  Surface to the user:
  > "I've tried 3 rounds of fixes for these P0s and they're not
  > resolving: [list]. The hook may be wrong, my fix may be wrong,
  > or the bug shape may be subtler than the specialist sentence
  > captures. Want me to push back via `[skip-review]`, take a
  > different approach, or get more eyes?"

Don't loop indefinitely. Specialists are not oracles; their 50–70 s
of compute is sometimes just wrong, and your time is more valuable
than the loop's stubbornness.

## Anti-patterns

- **Reflex-adding `[skip-review]` to push the commit through.**
  Defeats the entire purpose of the anti-bias hook. Skip-review is
  for *confirmed* false positives with *documented* reasoning, not
  for "I'm tired of waiting on the model".
- **Trusting the specialist's prescription verbatim.** "Use X
  instead of Y" can be wrong even when "Y is buggy" is right.
  Diagnose before prescribing. The specialists are graded on
  finding bugs, not on writing patches.
- **Looping forever on the same finding.** If round 3 still has the
  same P0 with the same diagnosis, escalate. The hook isn't an
  oracle; sometimes specialists are stubbornly wrong about the
  same line because the diff truly is ambiguous in isolation.
- **Squashing rounds via `--amend`.** Each retry is a fresh commit,
  even if it's a one-line fix. The audit trail — which finding was
  fixed in which commit — pays off when a similar shape comes back
  weeks later. Squashing on merge is the user's prerogative.
- **Drive-by edits during a fix round.** Tempting when you notice
  a different bug while you're in the file. Resist it inside the
  loop. Note the unrelated bug, finish the round, then handle the
  unrelated thing in its own commit (which gets its own hook run).
- **Triaging without opening the file.** Specialists see only the
  diff. You can see the whole repo. Use that asymmetry — read the
  cited line in context before deciding (a) vs (b).

## Hook latency and cost

Each retry pays one full hook run: ~50–70 s of `codex review`
compute. Plan accordingly:

- Don't trigger this loop for changes you'd happily `[skip-review]`
  upfront (README typos, lockfile bumps, pure data-file edits the
  hook would have skipped anyway).
- If your initial commit blocks with ≥3 separable findings across
  unrelated files, consider splitting the commit into logical
  groups before fixing — smaller diffs review faster and give
  clearer per-fix feedback.
- If the user is watching, narrate progress between rounds. 3
  rounds × 60s is 3 minutes of silence otherwise.

## Skip rules to remember (the hook handles these silently)

These never reach you as P0 blocks, so don't try to "fix" them:

| Skip trigger | Why |
|---|---|
| `codex` CLI not on PATH | Graceful degradation for collaborators |
| `SKIP_SECOND_OPINION=1` env | Manual override |
| `[skip-review]` or `[no-verify]` in commit msg | Inline override |
| Rebase / cherry-pick / merge in flight | Don't second-guess history rewrites |
| Branch matches `wip/*`, `explore/*`, `propose/*` | WIP branches |
| Empty staged diff (or empty `--amend`) | Nothing to review |
| Diff > 5000 lines | Manual `/second-opinion` instead |
| All changed paths in `*.md` / `*.lock` / `data/` / `cache/` / `results/` | Non-code |

If the hook unexpectedly exits 0 on a substantive code change, the
likely cause is one of these (often the WIP branch prefix or the
all-doc filter). Surface that, don't try to force it.

## Related

- `~/.claude/skills/commit-quality-pipe/SKILL.md` — the **proactive**
  umbrella that runs Claude's own multi-perspective Opus review +
  `simplify` + this defense loop, in that order. If the user is
  asking to "ship this commit" or "run the full pre-commit
  pipeline" (i.e. they haven't tried `git commit` yet), enter from
  there instead — this skill is then invoked as its Phase 3.
  Conversely, if `git commit` has already been blocked by the
  hook, stay here; restarting the umbrella from a blocked state
  just wastes Phase 1+2 compute on a diff already gated by Codex.
- `~/.claude/skills/pr-defense-loop/` — the cross-bot, multi-round
  PR sibling. If this commit eventually opens a PR and Codex /
  Claude Code Review weigh in, switch to that skill. (Note: per
  `~/.claude/CLAUDE.md`, pr-defense-loop is deprecated since the
  user cancelled the Codex GitHub App subscription. Kept here for
  orientation only.)
- The hook script and its README live in
  `<repo>/.claude/hooks/second-opinion-commit-gate.sh` and
  `<repo>/.claude/hooks/README.md` for any project that has it
  installed.
