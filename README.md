# claude-code-devkit

A set of Claude Code [hooks][hooks], [skills][skills], and [agents][agents]
that the maintainer uses day-to-day, packaged for sharing. Backend-agnostic
— works with whatever Claude Code is configured to talk to (Anthropic
direct, AWS Bedrock, Vertex AI, a reverse proxy, etc.).

The two highest-value pieces:

1. **An autonomous PR review/fix pipeline.** Two long-running `claude` daemons per
   repo, tmux-managed, on a 2-minute cron tick. Agent A reviews any open
   PR with new content (three independent angles); Agent B picks up Agent A's
   findings, spawns a worker sub-agent inside a `git worktree`, fixes the
   real issues, commits with `[auto N/4]` tags, and either auto-merges (after a
   dry-run period) or pings the operator. Pushes 5-10+ auto-fix commits per
   PR until findings clear or the round-cap hits. See
   [docs/architecture.md](docs/architecture.md) for the full design.

2. **A pre-commit second-opinion gate.** A `PreToolUse` hook runs
   `codex review` on every staged commit (any non-Claude reviewer model
   you've configured for `codex` works — Azure OpenAI, OpenAI direct, GitHub
   Copilot Enterprise via a reverse proxy, etc). On any `[P0]` finding the
   hook blocks the commit and shows the review to Claude, which has to
   address it (or `[skip-review]` with documented reasoning) before retrying.
   Plus a `commit-defense-loop` skill for systematically working through the
   findings.

[hooks]: https://docs.claude.com/en/docs/claude-code/hooks
[skills]: https://docs.claude.com/en/docs/claude-code/skills
[agents]: https://docs.claude.com/en/docs/claude-code/sub-agents

## What's inside

```
claude-code-devkit/
├── hooks/                  PreToolUse + SessionStart hooks
│   ├── block-uv-pip.sh                Stop `uv pip install` → force `uv add`
│   ├── block-orchestrator-writes.sh   Read-only contract for orchestrator daemons
│   ├── protect-paths.sh               Guard sensitive paths from Edit/Write
│   ├── protect-state-from-rm.sh       Guard pipeline state from `rm -rf`
│   ├── session-start-git-context.sh   Inject git state into session start
│   └── second-opinion-commit-gate.sh  `codex review` on every commit
├── skills/                 Slash-commands / workflow recipes
│   ├── pr-review-tick/      Agent A — one PR review cycle
│   ├── pr-orch-tick/        Agent B — one PR orchestration cycle
│   ├── pr-defense-loop/     Defend a PR against review bots
│   ├── commit-defense-loop/ Defend a commit against the gate hook
│   └── commit-quality-pipe/ Three-stage commit quality pipeline
├── agents/
│   └── code-reviewer-opus.md   User-level Opus reviewer subagent
├── bin/
│   └── claude-pr-pipeline-up   Bring up the PR daemons for the current repo
├── statusline.py           Compact statusline (model | branch | ctx tokens)
├── settings.example.json         Interactive-session settings (allow/ask/hooks/statusline)
├── settings.daemon.example.json  Daemon-session settings (bypassPermissions)
├── SETUP.md                Installation guide (feed to Claude Code)
└── docs/
    └── architecture.md     PR pipeline design + Agent A/B contract
```

## Install

The fastest path: **open Claude Code in this repo and ask it to follow [SETUP.md](SETUP.md)**.
It will copy the hooks/skills/agents into `~/.claude/`, merge `settings.example.json` into
your existing `~/.claude/settings.json` (or seed one), and verify the prerequisites.

If you'd rather install by hand: read `SETUP.md`. The steps are short.

## Requirements

- [Claude Code][claude-code] CLI installed and on PATH (`claude --version` works).
- `gh` CLI authenticated (for the PR pipeline).
- `tmux` and `flock` (for the PR pipeline daemons).
- `codex` CLI with at least one working profile (for the second-opinion
  commit hook + `pr-review-tick` cross-vendor adversarial review). The
  profile can point at Azure OpenAI, OpenAI direct, GitHub Copilot
  Enterprise via reverse proxy, etc. — this kit doesn't care which.
- `jq` (optional but preferred; skills fall back to `python3 -m json.tool`).

[claude-code]: https://docs.claude.com/en/docs/claude-code

## Quickstart — the PR pipeline

After install, from inside any git worktree with a GitHub remote:

```bash
cd /path/to/your/repo
claude-pr-pipeline-up --only both
```

That starts one tmux session `<repo>-pr` with two windows (`review` +
`orchestrator`). Both run `claude` on a `/loop` schedule. State lives at
`~/.local/state/claude-pr-pipeline/<owner>__<repo>/`. A `dry_run` flag is
created on first bring-up — Agent B will post "would auto-merge" comments
instead of actually merging until you `rm` the flag (typically after a
week of clean verdicts).

To watch:

```bash
tmux attach -t <repo>-pr           # last-active window
tmux attach -t <repo>-pr:review    # Agent A
tmux attach -t <repo>-pr:orchestrator  # Agent B
# Ctrl-b d to detach
```

To stop:

```bash
tmux kill-session -t <repo>-pr
```

## Quickstart — the commit gate

Once `hooks/second-opinion-commit-gate.sh` is registered in
`~/.claude/settings.json` (`SETUP.md` does this), every `git commit` Claude
runs goes through `codex review --uncommitted` first. On any `[P0]` finding
the hook blocks the commit and shows the review to Claude.

When you want Claude to systematically work through the findings rather
than reflex-`[skip-review]` them, invoke the `commit-defense-loop` skill:

```
> the commit got blocked, work through the findings
```

(That trigger phrase auto-loads the skill — Claude reads its `SKILL.md`
and follows the triage protocol.)

## A note on philosophy

The hooks here are deliberately **deterministic** — they enforce contracts
the model genuinely can forget under load (the orchestrator daemon
shouldn't write code; sub-agents shouldn't `rm -rf` pipeline state;
`uv pip install` is always wrong in a `uv add` project). They're not
"reminders"; they exit 2 and block. The skills are deliberately
**model-driven** — they give Claude a structured triage protocol and trust
the model's judgment within it. Different tools for different problems.

## License

MIT — see [LICENSE](LICENSE).
