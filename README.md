# claude-code-devkit

A small set of [Claude Code][cc] hooks, skills, and an autonomous PR
review/fix daemon pipeline. Backend-agnostic — works with whatever
Claude Code is configured to talk to (Anthropic direct, AWS Bedrock,
Vertex AI, etc.).

Two pieces do most of the work:

- A **two-daemon PR pipeline** (one tmux session per repo). Agent A
  reviews open PRs from three independent angles and posts a single
  aggregated comment. Agent B reads that comment, spawns a worker
  in an isolated worktree, fixes the real findings, and either
  auto-merges or pings you.
- A **pre-commit second-opinion gate**. A `PreToolUse` hook runs
  `codex review` on every staged commit. On any `[P0]` finding it
  blocks the commit and shows the review to Claude, which has to
  address it (or `[skip-review]` with a reason) before retrying.

[cc]: https://docs.claude.com/en/docs/claude-code

## Demo: a blocked commit

When Claude tries to land a commit with a real `[P0]` finding, this is
what it sees (and what stops the commit):

```
=== second-opinion BLOCKING (P0 found; address or add [skip-review] to retry) ===

Review of staged diff (94 lines, 3 files):

- [P0] src/auth/session.py:47 — token comparison uses `==` instead of
  `hmac.compare_digest`; vulnerable to timing oracle. The new code path
  is reached on every login.

- [P1] src/auth/session.py:52 — missing test for the rotated-token
  branch added in this commit.

=== suppress: [skip-review] in msg, SKIP_SECOND_OPINION=1, or SECOND_OPINION_ADVISORY=1 ===
```

`commit-defense-loop` (one of the included skills) is the tool for working
through findings like that — triage, fix, retest, retry — rather than
reflex-`[skip-review]`-ing them.

## Install

The fast path: open Claude Code in a checkout of this repo and ask it
to follow [`SETUP.md`](SETUP.md). The guide is written for Claude to
execute — it'll copy hooks/skills/agents into `~/.claude/`, merge
`settings.example.json` into your existing `~/.claude/settings.json`,
and verify prerequisites.

By hand: same steps, written out in `SETUP.md`. ~10 minutes.

Requirements:

- [Claude Code][cc] CLI (`claude --version` works).
- `gh`, `tmux`, `flock` for the PR pipeline.
- `codex` CLI with any working profile (Azure OpenAI, OpenAI direct,
  GitHub Copilot Enterprise via reverse proxy — the kit doesn't care
  which) for the commit gate + cross-vendor PR review angle.

## Quickstart — PR pipeline

From any git worktree with a GitHub remote:

```bash
claude-pr-pipeline-up --only both
```

That brings up one tmux session `<repo>-pr` with two windows. State
lives at `~/.local/state/claude-pr-pipeline/<owner>__<repo>/`. A
`dry_run` flag is created on first bring-up; Agent B posts "would
auto-merge" comments instead of actually merging until you `rm` the
flag (typically after a week of clean verdicts).

```bash
tmux attach -t <repo>-pr           # last-active window
tmux attach -t <repo>-pr:review    # Agent A
tmux attach -t <repo>-pr:orchestrator  # Agent B
# Ctrl-b d to detach
tmux kill-session -t <repo>-pr     # stop the daemons
```

## What's in the kit

| Category | Count | Summary |
|---|---:|---|
| [Hooks](#hooks) | 6 | PreToolUse / SessionStart guards |
| [Skills](#skills) | 5 | Slash-command workflows |
| [Agent](#agent) | 1 | User-level Opus reviewer sub-agent |
| [Launcher](#agent) | 1 | `bin/claude-pr-pipeline-up` |
| Settings templates | 2 | `settings.example.json` (interactive) + `settings.daemon.example.json` (bypass-permissions for daemons) |
| Statusline | 1 | `<model> \| <branch> \| ctx <tokens>` |
| Docs | 3 | README, SETUP, `docs/architecture.md` |

<a id="hooks"></a>
<details>
<summary><strong>Hooks (6)</strong> — click to expand</summary>

| File | Matcher | What it does |
|---|---|---|
| `block-uv-pip.sh` | PreToolUse / Bash | Blocks `uv pip install` / `uv pip uninstall`; forces `uv add` / `uv remove` for `pyproject.toml` + `uv.lock` reproducibility |
| `block-orchestrator-writes.sh` | PreToolUse / Bash + Edit/Write | Active only when `CLAUDE_ROLE=orchestrator` is set. Deterministically blocks code-mutating ops (Edit/Write, `git commit`/`push`/`rebase`, `sed -i`, `perl -i`). Bypasses when the call comes from a sub-agent (payload has `agent_id`) so workers can still write. |
| `protect-paths.sh` | PreToolUse / Edit/Write/NotebookEdit | Blocks writes to sensitive paths: `.env*`, `.git/`, `~/.ssh/`, `/etc/`, lockfiles, `.venv/`, etc. |
| `protect-state-from-rm.sh` | PreToolUse / Bash | Blocks `rm -rf` targeting PR pipeline state dirs, `~/.claude/`, bare `~`/`$HOME`/`/tmp`, bare `.` or `/`. Worker worktree paths under `/tmp/orch-*` go through an allowlist. |
| `session-start-git-context.sh` | SessionStart | Injects current branch, tracking state, uncommitted changes, recent commits, and worktree list into session start so Claude has working-tree context without asking |
| `second-opinion-commit-gate.sh` | PreToolUse / Bash (only `git commit`) | Runs `codex review --uncommitted` on every commit. Exit 2 on `[P0]` (blocks + shows to model). Skip rules: `[skip-review]` in msg, `SKIP_SECOND_OPINION=1`, WIP branch, `.md`/`.lock`-only diff, diff > 5000 lines, rebase in flight. Profile via `CODEX_PROFILE` env. |

</details>

<a id="skills"></a>
<details>
<summary><strong>Skills (5)</strong> — click to expand</summary>

| Skill | Trigger | What it does |
|---|---|---|
| `pr-review-tick` | `/loop /pr-review-tick`, "Agent A" | One review cycle. Three parallel angles: codex cross-vendor adversarial, code-reviewer-opus, bespoke Opus PR-coherence pass. Posts ONE aggregated comment per (PR, head-sha). For PRs > 5000 lines, first-fit-decreasing bin-packs the diff into synthetic commits and reviews each. |
| `pr-orch-tick` | `/loop /pr-orch-tick`, "Agent B" | One orchestration cycle. Reads Agent A's findings → spawns worker in `/tmp/orch-<slug>-pr<N>` → worker triages a/b/c, fixes the a's, commits with `[auto N/4]`, pushes. Verdict gate: dry-run comment / real `gh pr merge` / @-escalate. Caps at `max_rounds=4`. |
| `pr-defense-loop` | "run a defense loop", "fix all the bot comments" | Defends a PR against external review bots by polling for new comments, triaging, fixing, pushing, looping. Survives multi-bot setups. |
| `commit-defense-loop` | "the commit got blocked", `=== second-opinion BLOCKING ===` in stderr | Defends a `git commit` against the second-opinion gate hook. Triage → fix with regression test → retry. Single turn, no `/tmp` state, no `ScheduleWakeup` (tighter than `pr-defense-loop` because each iter is 60s of hook latency, not minutes). |
| `commit-quality-pipe` | "ship this commit", "audit those commits" | Three-stage pre-commit pipeline: Claude Opus multi-angle review → `simplify` reuse/quality pass → codex review as final gate. Mode A pre-commit, Mode B retroactive audit on already-landed commits. |

</details>

<a id="agent"></a>
<details>
<summary><strong>Agent + launcher + configs</strong> — click to expand</summary>

| File | Purpose |
|---|---|
| `agents/code-reviewer-opus.md` | User-level Opus reviewer sub-agent. Confidence ≥ 80 filter, repo-agnostic, reused by `commit-quality-pipe` phase 1 and `pr-review-tick` angle 2. |
| `bin/claude-pr-pipeline-up` | Brings up the PR pipeline tmux session for the current repo. Preflight (gh/tmux/codex/etc.), creates `dry_run` safety flag on first run, two windows (review + orchestrator), orchestrator gets `CLAUDE_ROLE=orchestrator` injected. |
| `settings.example.json` | Template `~/.claude/settings.json` for interactive sessions: `permissions.allow` / `permissions.ask` lists, hook registrations, statusline, `effortLevel: xhigh` |
| `settings.daemon.example.json` | Variant for background daemon sessions: `defaultMode: bypassPermissions`, no `ask` prompts (hooks still gate, just no interactive prompts) |
| `statusline.py` | `<model> \| <branch> \| ctx <tokens>` statusline. Reads transcript jsonl for the latest `usage` to compute context size. |

</details>

## How the pipeline works

One tmux session per repo, two long-running Claude sessions inside.
Agent A reviews; Agent B fixes. They coordinate via on-disk state and
GitHub PR comments — no direct IPC.

```
        GitHub repo (open PRs)
                  │
                  ▼
   ┌──────────────────────────────────────────────┐
   │  tmux: <repo>-pr                             │
   │  ┌────────────────┐  ┌──────────────────┐    │
   │  │ window "review"│  │ window "orch"    │    │
   │  │ /pr-review-tick│  │ /pr-orch-tick    │    │
   │  │ Agent A        │  │ Agent B          │    │
   │  │                │  │ CLAUDE_ROLE=orch │    │
   │  └────────┬───────┘  └─────────┬────────┘    │
   └───────────┼────────────────────┼─────────────┘
               │                    │
               ▼                    ▼
        PR comment          /tmp/orch-<slug>-pr<N>/
       (Agent A round       (worker worktree;
        @ <short-sha>)       sub-agent fixes,
                             commits [auto N/4],
                             pushes back to PR branch)
                                    │
                                    ▼
                            PR head moves → next
                            review round triggers
```

The orchestrator (Agent B) is **read-only with respect to code**. Only
its worker sub-agent writes / commits / pushes. This is enforced by
`block-orchestrator-writes.sh`, not by trust — see the design doc for
why that distinction matters.

**Full design**: [`docs/architecture.md`](docs/architecture.md).

## Design notes

The hooks here are deterministic — they enforce contracts the model
genuinely can forget under load (the orchestrator shouldn't write
code; sub-agents shouldn't `rm -rf` pipeline state; `uv pip install`
is always wrong in a `uv add` project). They're not reminders; they
exit 2 and block.

The skills are model-driven — they give Claude a structured triage
protocol and trust the model's judgment within it. `pr-defense-loop`
doesn't tell Claude which findings are wrong; it tells Claude *how* to
decide.

What this kit deliberately does NOT do: prescribe a backend, run
systemd services, set up reverse proxies, or merge PRs from external
contributors without a human in the loop. Those are deployment /
policy choices, kept out of the kit on purpose.

## License

MIT — see [LICENSE](LICENSE).
